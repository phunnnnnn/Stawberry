# Plan — Hireable workers with stats

## Goal

Workers stop being a free grant and become something the player finds and buys.

A pool of candidate workers stands idle on `Workspace.Worker`, each rolled with its own **walk speed**. The player walks up to one, reads its speed and price off the ProximityPrompt, and presses `E` to hire it. Only then does it start farming. Hiring costs coins, priced from that worker's speed.

A player now starts with **zero** workers and must hand-farm their first hire.

## Decisions already made — do not re-litigate these

These were chosen deliberately. If you think one is wrong, say so rather than quietly changing it.

| Question | Decision |
| --- | --- |
| Hire price | **Coins, scaled by walk speed.** A fast worker costs more. One formula in Config, not a number per worker. |
| Pool behaviour | **Kept topped up, and unhired candidates rotate.** The zone always holds `PoolSize` candidates; hiring one spawns a replacement, and an unhired one is replaced with a fresh roll after `RotateInterval`, so a bad batch is not permanent. |
| Workers per player | **Config cap, default 3.** Mirrors `Config.Factory.MaxPlaced`. |
| Dismissal | **Yes, no refund, behind a Config flag.** Follows the `Config.Factory.CanRemove` precedent so it is one boolean to switch off. |

## Scope

Touches five files. **No client module and no remote** — hiring is a server-side ProximityPrompt trigger, so there is nothing for a client to lie about.

| File | Change |
| --- | --- |
| `src/shared/Config.luau` | New `Worker` keys; remove two |
| `src/shared/WorkerModel.luau` | Add `HirePrompt` and `DismissPrompt` |
| `src/server/WorkerService.luau` | The bulk: pool, stats, hire/dismiss, per-worker speed |
| `src/server/InventoryService.luau` | Add `spendCoins` |
| `CLAUDE.md` | Update the `Workers` section |

---

## 1. `Config.luau`

### Remove

- `StartingWorkers` — there is no grant any more.
- `WalkSpeed` — replaced by a per-worker roll. **Every** reader must be updated (see §3.3).

### Add

```lua
-- The candidates standing on the zone waiting to be hired.
PoolSize = 4,

-- Seconds before an unhired candidate is replaced by a fresh roll. Without this a
-- player who is offered four slow workers is stuck with that offer all round.
RotateInterval = 45,

-- Workers one player may have at once. Coins are the near-term limit; this is the
-- ceiling, and also the performance one — every worker is stepped on Heartbeat.
MaxHired = 3,

-- Walk speed is rolled per worker, in whole studs per second so the number on the
-- prompt is readable. The old fixed value was 22, so this brackets it.
MinWalkSpeed = 12,
MaxWalkSpeed = 30,

-- Hire price, derived from the roll:
--     HireBaseCost + (WalkSpeed - MinWalkSpeed) * HireCostPerStud
-- So the slowest worker costs HireBaseCost and the fastest 50 + 18*15 = 320.
-- For scale: a worker at 22 studs/s cleared roughly 100 coins a minute in testing,
-- so a mid-range hire pays for itself in about two minutes. A pie is 30 coins, so
-- the cheapest worker is two pies of hand-farming — reachable before any income.
HireBaseCost = 50,
HireCostPerStud = 15,

-- Dismissing a hired worker, freeing its slot. No refund. Off switch, exactly like
-- Config.Factory.CanRemove: the handler stays wired either way.
CanDismiss = true,
DismissKey = Enum.KeyCode.X,
DismissHoldDuration = 0.6,
```

`DismissKey`/`DismissHoldDuration` mirror the factory's remove prompt: a **separate key, held**, so dismissing can never be hit while mashing `E`.

### Leave alone

`ArriveDistance` stays at 2.5 even though `MaxWalkSpeed` is now 30. `advance` already does `math.min(speed * deltaTime, distance)`, so a worker lands exactly on its destination and cannot overshoot however fast it is or however bad the frame rate. **Do not "fix" this** — the clamp is what makes any speed safe.

---

## 2. `WorkerModel.luau`

Add two prompts, parented to the `Torso` (the factory parents its prompts to `Body`, same idea).

```lua
local hire = Instance.new("ProximityPrompt")
hire.Name = "HirePrompt"
hire.ActionText = "Hire"          -- rewritten per worker; the price varies
hire.ObjectText = "Worker"        -- rewritten to carry the walk speed
hire.HoldDuration = 0
hire.MaxActivationDistance = cfg.PromptRange   -- see note below
hire.RequiresLineOfSight = false
hire.Enabled = false              -- WorkerService decides; unhired is not this
                                  -- module's business
hire.Parent = torso
```

and a `DismissPrompt` with `KeyboardKeyCode = cfg.DismissKey`, `HoldDuration = cfg.DismissHoldDuration`, `Enabled = false`.

Notes:

- **`Config.Worker` has no `PromptRange`** — add one (12 matches the factory and the seller).
- Both are built `Enabled = false`. `WorkerService` turns exactly one on. Same contract as `FactoryModel`, where the output prompt ships disabled because empty is the state a machine starts in.
- **The prompt carries the stat; do not add a BillboardGui.** `Config.Worker.ShowStatus` was deliberately switched off in the previous commit so a worker reads as a character rather than a labelled game object. A prompt's `ObjectText` shows only when the player is in range — which is exactly when they need to compare candidates. If they later want at-a-glance comparison across the pad, `ShowStatus = true` already labels every worker with no new code.

---

## 3. `WorkerService.luau`

The real work. Read the module header before starting — the "second actor, not a second set of rules" rule and the anchored-movement rationale both still hold.

### 3.1 Stats and optional ownership

```lua
-- Rolled per worker at spawn. Only walk speed for now; the table exists so a
-- second stat does not change every signature that passes one around.
export type WorkerStats = {
    WalkSpeed: number,
}
```

`WorkerRecord` changes:

- `owner: Player` → **`owner: Player?`**. Nil means unhired and standing in the pool.
- add `stats: WorkerStats`
- add `hireCost: number` — derived once at spawn, so the prompt and the charge can never disagree
- add `rotateAt: number` — when an unhired candidate is replaced. Meaningless once hired.

Mirror the roll onto the model so it replicates and is visible in the Explorer while debugging:

```lua
model:SetAttribute("WalkSpeed", stats.WalkSpeed)
model:SetAttribute("HireCost", cost)
```

The record stays authoritative; the attributes mirror it. Same relationship as the tally and its Tools — never read the attribute back to make a decision.

### 3.2 `owner` being nil ripples further than you expect

Every one of these currently assumes a `Player` and will silently misbehave or throw:

| Site | What to do |
| --- | --- |
| `describe(worker)` | Return something like `"For hire"` when unhired |
| `refreshStatus(worker)` | Reads `worker.owner.Name` — guard it |
| `stepWorker` | An unhired worker must **not** call `chooseJob`. Stand at the post, run the rotation check, return |
| `claimsFor(owner, except)` | Matches on `other.owner == owner`. Safe today because it is only called for hired workers — but the moment it is called with nil it claims every unhired worker. Assert or narrow the parameter to non-nil |
| `finish` → `SellService.sellCarried(worker.owner, …)` | Needs non-nil; only reachable for hired workers, but the type change makes it a latent trap |
| `removePlayer(owner)` | Currently destroys workers whose owner matches. Still correct — but confirm a nil owner can never match a leaving player |

### 3.3 Per-worker walk speed

There are exactly **four** readers of the two removed keys. Verified by grep at the time of writing, so line numbers are close but check them:

| Site | Change |
| --- | --- |
| `WorkerService.luau:220`, inside `advance` | `Config.Worker.WalkSpeed` → `worker.stats.WalkSpeed`. **The one that matters.** |
| `WorkerService.luau:586`, in `start`'s `setupPlayer` | The `for _ = 1, StartingWorkers` grant loop — delete it. `setupPlayer` may end up doing nothing, in which case drop it and the `PlayerAdded` hook with it |
| `WorkerService.luau:598`, `start`'s summary `print` | Reports `StartingWorkers` and `WalkSpeed`. Report `PoolSize` and the speed range instead |
| `Config.luau:309` | The `StartingWorkers` definition itself |

Line 220 is the single easiest thing in this whole change to miss: leave it and every worker walks at the old constant, the stat does nothing, and the feature looks finished while being completely inert. **The play test in §5 has a check specifically for this — do not skip it.**

Grep `WalkSpeed` and `StartingWorkers` across `src/` when done. No reader of a single global speed should remain.

### 3.4 The pool

```lua
-- Candidates get the first PoolSize post slots, so the hiring line is always in
-- the same place and a replacement stands where its predecessor stood. Hired
-- workers take slots from PoolSize upward.
```

Functions to add:

- `rollStats(): WorkerStats` — `math.random(MinWalkSpeed, MaxWalkSpeed)`, whole studs.
- `hireCostFor(stats): number` — the Config formula. One place, used by both the prompt text and the charge.
- `spawnCandidate()` — an unhired worker at the next free pool slot, with `rotateAt = now + RotateInterval`.
- `topUpPool()` — spawn candidates until `PoolSize` unhired workers exist. Call after any hire, rotation or removal.
- `refreshHirePrompt(worker)` — **the only writer of either prompt's `Enabled`.**

`refreshHirePrompt` is the invariant that matters most here, and it is the same one `FactoryService.refreshPrompts` protects:

```
unhired   HirePrompt      "Hire — 200 coins" / ObjectText "Worker — 22 studs/s"
hired     DismissPrompt   only when Config.Worker.CanDismiss
```

Enable a prompt anywhere else and the two states can contradict each other — a hired worker still advertising itself for hire is the exact bug this prevents.

### 3.5 Hiring

Wire `HirePrompt.Triggered`. Gates, in this order, refusing through the existing `log`/`refuse` style:

1. **Still unhired.** `if worker.owner then refuse` — a prompt can fire twice before teardown, and two players can trigger the same worker in the same frame. `FactoryService`'s handlers re-check state for exactly this reason; do the same.
2. **Under `MaxHired`.** Count that player's hired workers.
3. **Can pay.** `InventoryService.spendCoins(player, worker.hireCost)` — see §4. All-or-nothing.

Charge **last**, only once every other gate has passed. This mirrors "the seed is consumed only after every check passes" and "stock is consumed only after every check passes" — the codebase is consistent about it.

Then: set `owner`, move it off the pool slot onto a hired post, `refreshHirePrompt`, `refreshStatus`, `topUpPool()`, and log the hire with the name, speed and price.

No distance re-check. The prompt's `MaxActivationDistance` is enforced server-side by Roblox, and no client-supplied position is involved — unlike planting and factory placement, where the client sends a coordinate and the server must therefore re-derive everything.

### 3.6 Dismissal

Wire `DismissPrompt.Triggered`, following `FactoryService.onRemove` closely:

1. `Config.Worker.CanDismiss` re-checked **server-side**, not left to the hidden prompt. A disabled prompt is a client-side fact.
2. Owner only.
3. **Refuse while it is carrying something.** The item was never in the tally, so dismissing mid-trip destroys 12–30 coins of work with no record. Same shape as the factory refusing to be picked up mid-cycle: the player collects first, and there is never a question of where the goods went.

Then destroy the model, drop the record, and `topUpPool()` if you decide dismissal returns nothing to the pool (it does not — see §6).

### 3.7 Rotation, and a real trap

An unhired worker past its `rotateAt` is destroyed and replaced.

**`step()` iterates `ipairs(workers)`. Removing an entry inside that loop skips the next worker and will misbehave in a way that looks random.** Either iterate backwards by index, or collect rotations into a list and process them after the loop. This is the most likely source of a subtle bug in this change.

Rotation must also never touch a hired worker, and must not fire while a player is standing at the prompt about to hire — accept that race (they get a refusal and a fresh candidate) rather than adding a hold-off timer.

---

## 4. `InventoryService.luau`

Add the mirror of `addCoins`:

```lua
-- Spends coins, or changes nothing and returns false when the player cannot
-- afford it. All-or-nothing, the same contract as takeItem, so a caller that goes
-- on to hand something over cannot half-charge.
function InventoryService.spendCoins(player: Player, amount: number): boolean
```

**This matters.** `InventoryService` is the only writer of `Coins` in the codebase — `sellAllItems`, `sellHeldItem` and `sellCarried` all route through `addCoins`. Do **not** read or write `leaderstats.Coins` from `WorkerService`; add this function and call it. A second writer is how the displayed balance and the real one start disagreeing.

---

## 5. Verification

There is no test framework. Verify by play test through the Studio MCP.

Three things that will otherwise waste your time — all documented in `CLAUDE.md`, repeated here because they apply directly to this feature:

1. **Prompts need real input.** Unlike the worker loop, which is entirely server-driven and needed no input at all, hiring is a ProximityPrompt. Trigger it with `user_keyboard_input` (`E`, `datamodel_type: Client`), positioning the character near the worker first with `Character:PivotTo(...)`.
2. **A minimized Studio window silently eats all input and hangs `screen_capture`.** `start_stop_play(is_start=true)` is itself a trigger for this. Restore the window *after* starting play: `ShowWindow(handle, 9)` + `SetForegroundWindow`, checking `IsIconic` on `RobloxStudioBeta`'s `MainWindowHandle`.
3. **Starting a play test seconds after an edit can run stale code.** The play DataModel can fork before Rojo pushes the change. If a config value you just set is not live, read the module's `.Source` in `datamodel_type: Edit` and grep it: present there but not in the running server means a sync race — stop and restart play. An established socket on port 34872 is *not* proof the plugin is applying changes.

What to check:

- [ ] `PoolSize` candidates on the zone at server start, each with a different rolled speed, each showing `HirePrompt` and no `DismissPrompt`
- [ ] A player joins with **no** worker and zero income
- [ ] Prompt text names both the speed and the price, and the price matches the formula for that roll
- [ ] Hiring deducts exactly `hireCost`, and is **refused** with coins unchanged when the player cannot afford it
- [ ] The hired worker starts the normal loop and **walks at its own rolled speed** — time a known leg, or compare two workers with different rolls side by side. This is the check that catches §3.3
- [ ] A replacement candidate appears after a hire, keeping the pool at `PoolSize`
- [ ] An unhired candidate is replaced after `RotateInterval` with a different roll
- [ ] `MaxHired` refuses the fourth hire
- [ ] Dismissal frees a slot, is owner-only, and is refused while the worker is carrying
- [ ] `CanDismiss = false` hides the prompt **and** is still refused if triggered
- [ ] Two players cannot hire the same candidate

---

## 6. Deliberately deferred

Call these out rather than solving them:

- **Dismissing a moving worker is awkward.** A hired worker spends most of its time walking across the map, so catching it to hold `X` means chasing it. It pauses `ActionDelay` at each stop and walks predictable routes, so it is possible, but not pleasant. Two clean follow-ups if it grates: offer dismissal from the Worker zone instead, or add a "recall" that walks it home first. Not in this change.
- **A leaving player's hired workers are destroyed, not returned to the pool.** Returning them would push the pool over `PoolSize` and reintroduce a stat that was rolled for a different moment. There is no persistence anyway. Keep the current `removePlayer` behaviour.
- **Unhired candidates look identical to hired ones** apart from the prompt. A different shirt colour while unhired would read better from a distance. Cheap, optional, not required.
- **Stats are rolled uniformly.** No rarity curve, no scaling with player progress. `rollStats` is the one place to change that later.
- **Only walk speed.** The `WorkerStats` table exists so adding carry capacity or a harvest speed later does not change signatures — but do not add them now.

## 7. Docs

Update the `### Workers` section of `CLAUDE.md`:

- Workers are hired from a rotating pool, not granted. A player starts with none.
- `refreshHirePrompt` joins the list of single-writer functions, alongside `refreshPrompts`, `takeFruit`, `beginCycle`, `endCycle` and the coin writers.
- `InventoryService.spendCoins` joins `addCoins` as the only writers of `Coins`.
- Walk speed is per-worker; there is no global speed any more.
- Update `### Known gaps`: the "one worker per player, fixed at `Config.Worker.StartingWorkers`" entry is gone, replaced by the deferred items in §6.
