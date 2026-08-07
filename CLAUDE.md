# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Roblox tycoon-style game ("Stawberry" — the misspelling is the project name), synced into Roblox Studio with Rojo. One gameplay loop is implemented end to end: a conveyor produces seeds → plant them on the farm → harvest fruit → optionally refine it in a factory → sell at the seller.

## Commands

```sh
aftman install                       # required after clone — installs pinned rojo
git config core.hooksPath .githooks  # required after clone — enables the place-file hook
rojo serve                           # sync server on port 34872
rojo build -o build/Stawberry.rbxlx  # scripts only, see caveat below
rojo plugin install                  # install/refresh the Rojo Studio plugin
```

Studio opens `place/Stawberry.rbxl` directly; Ctrl+S writes back to that file.

`rojo` is an Aftman shim. Without `aftman install` it fails with *"no aftman.toml files list this tool"* — that is a missing toolchain, not a broken install.

After `rojo serve`, someone must click **Connect** in Studio's Rojo panel. That is a plugin widget and cannot be automated — ask the user to click it.

Studio's MCP server is likewise a toggle inside Studio: **Assistant → … → Manage MCP Servers → "Enable Studio as MCP server"**. It is Studio's *built-in* server (`StudioMCP.exe`, shipped in the Studio version folder), not a plugin — the standalone `Roblox/studio-rust-mcp-server` is archived, so there is no `MCPStudioPlugin.rbxm` to install and looking for one is a dead end. `list_roblox_studios` returning nothing almost always means that toggle is off.

There is **no test framework and no linter configured**. Verification is done by play-testing through the Roblox Studio MCP. Don't invent a test command.

## Two sources of truth — read this before editing anything

Rojo owns **only** the three script branches. All Workspace geometry lives in the place file at **`place/Stawberry.rbxl`**, which is committed to this repo:

`Baseplate`, `SpawnLocation`, `Farm`, `Fatory`, `Worker`, `Seller`, `FactoryRNG`, `Conveyor{Part, Part, conveyor}`

### Always commit the place file with code changes

The map and the code must move together, or a checkout pairs new scripts with an old map. `.githooks/pre-commit` force-stages `place/Stawberry.rbxl` and warns when it looks older than `src/`.

**Use `git add -A` before committing.** The `.gitignore` negation means that picks up the place file. The hook can only *augment* a commit that already has something staged — git decides "nothing added to commit" before honouring the hook's index changes, so when a Studio save is the only change `git commit` aborts anyway, leaving the file staged. Stage it yourself in that case.

The hook cannot flush unsaved Studio state to disk. **Before committing anything that touched geometry, tell the user to save in Studio (Ctrl+S)** — otherwise the staged place file is stale and the warning is the only signal.

### Other consequences

- `rojo build` output contains **no map** — scripts only. It is not a playable place.
- Geometry changed via MCP in Edit mode exists only in memory until the user saves. Always tell them to save.
- The place began as a cloud place (`PlaceId 113158059729469`) and was moved to a local file. Local saves do **not** reach Roblox — that needs **File > Publish to Roblox**.
- `Fatory` is a typo for "Factory" but is load-bearing — it is the factory placement zone (`Config.Factory.ZoneName`). Grep for the name before renaming.
- `Farm`, `Fatory`, `Worker`, `Seller` and `FactoryRNG` are all read by name out of `Config` (`PartName` / `ZoneName`). Renaming one in Studio disables that whole feature with a single warning in Output and nothing else. Losing `FactoryRNG` is the worst of them: it is the only source of factories, so the whole refining half of the game goes quiet.
- Part positions drift between sessions because the user edits the place directly. **Never trust a coordinate recorded in this file or in conversation history — re-read it from the live place.**

## Rojo mapping

| Source | Studio | Class |
| --- | --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` | Folder |
| `src/server` | `ServerScriptService.Server` | **Script** |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | **LocalScript** |

Because `src/server` and `src/client` contain `init.server.luau` / `init.client.luau`, the *folder itself becomes the script* and sibling files become its **children**. So:

- from `init.server.luau`: `require(script.ConveyorService)`
- from one service to another: `require(script.Parent.InventoryService)`

Getting this wrong is the most likely cause of a "not a valid member" error after adding a module.

`default.project.json` also sets `Lighting.Technology = Future`.

## Architecture

Shared (`ReplicatedStorage.Shared`):

- **`Config`** — tuning data plus the `PlantSpec`/`FruitSpec`/`ProductSpec` types. Prefer adding a config value over hardcoding. It is data, not behaviour: the only functions in it are the table-builders `pale`/`sproutOf`/`species`, which run once at load to expand the compact species catalogue into ordinary `PlantSpec`s. Nothing downstream can tell an expanded entry from a hand-written one.
- **`Produce`** — one index of everything carryable and sellable, built from `Config.Plants` fruit *and* `Config.Products`. Fruit and factory products are deliberately the same shape here; that is what lets one tally and one stack-Tool mechanism hold both. Anything quoting or charging a price reads it from here — a second copy would eventually quote a number the seller does not honour. That includes the *seed* price, which `Seed.price` derives from the fruit's, so the belt cannot advertise a number the farm will not later repay. It also owns the tier arithmetic: **`acceptedBy(item)` is the one place "a tier-N machine eats the rung below" is expressed**, and everything matching a machine to an item asks it rather than doing the sum itself. Every `ItemSpec` also carries its species' `Rarity`, unchanged by refining — which is what lets a Watermelon Masterpiece report itself as Mythic without anything having to trace it back to the melon.

  It also owns **grades**, which is how factory levels reach a price. What everything passes around is an *item id*, not a bare name: `"Strawberry Pie"` or `"Strawberry Pie#3"`, where the suffix is the multiplier the item's price carries. **Grade 1 has no suffix**, which is the whole design — every id that predates levels is still exactly itself, so nothing that was passing item names around had to learn a second parameter. `spec`, `recipeFor` and `acceptedBy` resolve the base name and answer as they always did (deliberately ignoring grade: a tier-2 machine refines a Pie whatever the Pie is worth); only `price` and `displayName` read it. **`gradeAfter(inputGrade, level)` is the one place the ladder's compounding is expressed.** See *Levels* below.
- **`Rarity`** — what a rarity band means and what the belt deals next. Six bands, 0..5, authored in `Config.Rarities`; see *Rarity* below. **`roll()` is the one place the belt's odds are decided** — cumulative weights built once at load, not summed over eighteen species every spawn — and `of`/`name`/`color`/`ofSpecies` all **fall back to Common rather than returning nil**, because a band is nearly always on its way into a string or a `Color3`.
- **`Remotes`** — lazily creates (server) or waits for (client) `ReplicatedStorage.Remotes`, so neither side depends on load order. Access via `Remotes.event(Remotes.PLANT_SEED)` / `Remotes.func(Remotes.SELL_FRUIT)`.
- **`Seed`** — `createPickup(species)` for the belt ball, `createTool(species)` for the Backpack item, `price(species)` for what it costs, and `speciesOf(tool)` — **the one test for "is this Tool a seed"**. Seeds are typed, so the Tool's *name* is a label ("Apple Seed") and the `SeedSpecies` attribute is the contract; a name check finds one species out of eighteen and silently misses the rest. Seeds are also **banded**: the belt prompt reads "Mythic Watermelon Seed" and anything above Common wears its band colour as a `Highlight` outline (`Config.Seed.OutlineFromRarity`), while the Tool keeps the short name and says its band in the tooltip — the hotbar has only a slot's width. **There is no rarity attribute**, because `SeedSpecies` already implies one and a second copy could disagree with it.
- **`PlantModel`** — builds plant and fruit geometry from a species entry, in two stages: `create` makes a sprout, `setScale` grows it, `mature` swaps it for the true form. `groundOf` is the inverse of `place`, so the client can recover a plant's footprint from the replicated model — at any stage, since it reads the `Ground` attribute rather than the (scale-dependent) pivot.
- **`FarmSurface`** — pure placement rules: `project` (click → point on the pad's top face) and `tooClose` (spacing). Shared **so the client's indicator cannot promise a spot the server refuses**. Add new placement rules here, not in either caller.
- **`FactoryGrid`** — the same idea for the factory zone, but snapping to a lattice: `project` (click → centre of its grid cell) and `occupied`. Cells are measured from the zone's own centre, so moving or rotating the pad carries the grid with it — never hardcode cell coordinates.
- **`FactoryModel`** — builds machine geometry and its three prompts (`InputPrompt`, `OutputPrompt`, `RemovePrompt`). `groundOf` is the inverse of `place`. **A machine's tier is said three ways** — body colour at a distance, a countable row of roof pips up close, and "Tier N · Lv M Factory" on every prompt — because five machines stand in a row and putting a Cake in the wrong one costs a cell and a pick-up. `tierOf` reads it off the attribute; nothing infers it from the colour. **Level gets its own row of pips on the back edge** in its own colour, plus its own place in that prompt text, and `levelOf` reads it off its own attribute: two numbers that both matter must not be told the same way, and level has deliberately *no* colour of its own because the body already means tier. `createOffer` builds the same machine with a single Take prompt instead of the three working ones — that is what stands on the generator pad, and it is the real geometry rather than a token so the pad cannot advertise something other than what it hands over. `showItem` re-*positions* as well as resizes the slot, resting an item on the roof by its underside: a Masterpiece is four times a Pie's height, so a fixed centre offset would bury the tall ones. It measures from `groundOf` rather than the slot's current CFrame, so repeated calls cannot walk the item upward — the same anti-drift rule as `PlantModel.layout`.
- **`WorkerModel`** — builds the worker as a **stock R6 rig** and poses it. A genuine one: `Humanoid`, `HumanoidRootPart`, the six standard parts under their exact standard names (`"Left Arm"`, not `"LeftArm"` — the space is load-bearing to anything that reads a character), all five `Motor6D` joints, the built-in `MeshType.Head` and `rbxasset://textures/face.png`. Five studs sole to crown, like a player's own character. Built part by part rather than through `Players:CreateHumanoidModelFromDescription`, which yields on the avatar web API — hiring a worker must not block the join that hired it, and must work with no network. `setPose` recomputes every part from the spec each call (the same anti-drift rule as `PlantModel.layout`), driving a walk cycle from a phase accumulated out of *distance travelled*, so a stopped worker's legs stop too. `showItem` is `FactoryModel`'s slot idea reused: what the worker holds is visible in its hands, placed at wherever `CarryArmAngle` puts them rather than at a fixed offset.

Server, started in this order by `init.server.luau` (inventory first, the rest award into it):

- **`InventoryService`** — owns everything carried, plus coins. Prices and item geometry come from `Produce`.
- **`ConveyorService`** — spawns/moves/despawns belt seeds, and **sells** one on pickup. The belt is the shop: each seed carries its own price, so what is on offer is chance and what you take is a decision. A refused purchase leaves the seed riding. The roll is **`Rarity.roll()`, weighted by band** — this service knows none of the odds itself, and logs the resulting spread once at startup so a weight edit is verifiable from Output.
- **`PlantingService`** — validates plant requests, grows plants then fruit, handles harvest.
- **`FactoryService`** — validates factory placement, then runs each machine's insert → wait → collect cycle. **`refreshPrompts` is the only thing that writes either cycle prompt's `Enabled`** — a machine shows `InputPrompt` while empty, neither while working, `OutputPrompt` once a product is ready. Add a state and you change that one function; enable a prompt anywhere else and the two can contradict each other. Both handlers still re-check the machine's state, since a trigger can be in flight when the state changes under it. Machines are **tiered** (see *The refining ladder*) and **levelled** (see *Levels*): every transition, prompt and worker query is the same code as before with `record.tier` and `record.level` threaded through. It no longer decides what a player *gets* — `grantFactory` is the way in, and `Config.Factory.StartingFactories` is empty.
- **`FactoryRngService`** — the only source of factories. Deals one machine at a time onto `Workspace.FactoryRNG` out of a pool table, per player, free. See *Where factories come from*. Started **after `FactoryService`**, which owns the list a won machine lands in.
- **`SellService`** — creates the seller prompt, settles sales. `sellCarried` pays for an item a worker walked in, which was never in the tally.
- **`WorkerService`** — drives the NPC workers: a rotating hire pool plus every hired worker's job loop. **Started last**, because it queries the farm, the factory zone and the seller and all three must have found their fixtures first. Fully server-side: no remote and no client module — hiring and dismissing are plain ProximityPrompt triggers, and Roblox already delivers those with the triggering `Player` attached and `MaxActivationDistance` already enforced.

Client:

- **`MouseTarget`** — the one raycast under the cursor. Every controller and indicator uses it; two separate raycasts could disagree and the preview would lie.
- **`ToolWatcher`** — the single answer to "the player activated a Tool called X", or — via `onActivatedAttribute` — "a Tool *tagged* with X". Owns the equip-cycle and respawn bookkeeping described under *Client gotchas*; `PlantingController` and `FactoryController` are thin handlers registered against it. **Add new tool-driven actions here rather than re-implementing the container watching**, which is exactly the bug that cost hours below. Register a family that shares a job but not a name — every seed, of any species — by attribute; a name is only right when exactly one Tool has it.
- **`PlantingController`** — reports where the player clicked while holding a seed. Registered by attribute, so all eighteen species bind once. It sends *only* the position: which species goes in the ground is read server-side off the Tool it can see being held.
- **`FactoryController`** — the same for a held factory. It sends the raw click; snapping happens server-side, so a client that snapped differently could only disagree.
- **`FactoryIndicator`** — preview square for the grid cell a factory will land on. Display-only. Snap-to-grid is invisible without it: the machine goes to the middle of the cell, not to the click.
- **`PlantIndicator`** — `RenderStepped` preview disc, green where the click will land, red plus a reason where it won't. Cosmetic: it re-checks `FarmSurface` rules for *feedback* and changes no outcome. It cannot preview `MaxPlantsPerPlayer`, which the client has no way to read.
- **`FruitInspector`** — price card shown while produce is equipped: name, rarity band in the band's own colour, unit price, how many of that item you carry, total value.
- **`Leaderboard`** — always-visible board ranking players by `Coins`, read straight off each player's `leaderstats`.
- **`SellDialogue`** — code-built ScreenGui, opened by the seller prompt.

`PlantIndicator`, `FactoryIndicator`, `FruitInspector` and `Leaderboard` are display-only and each starts behind its own `pcall` in `init.client.luau`. That is deliberate: a require error in a cosmetic module previously killed the whole LocalScript and silently disabled planting.

### Inventory model

Seeds are **Tools in the Backpack** — that Tool list *is* the seed inventory, so there is no parallel seed counter to drift. `InventoryService.seedCount` therefore counts both the Backpack *and* the character, because an equipped tool moves to the character, and it counts by the **`SeedSpecies` attribute rather than by Tool name** — eighteen species mean eighteen names, and a name check would find one and silently miss seventeen. Use `Seed.speciesOf` anywhere you need to ask "is this a seed"; three modules do.

Produce — harvested fruit **and factory products alike** — is a server-side per-item tally (`itemsByPlayer`), mirrored to `leaderstats.Fruit` as a display-only total. Keeping the tally per-item is what lets sales price each thing correctly; don't collapse it to a single number.

**Produce does not stack.** The tally materialises as one Tool per item, each marked with a `FruitName` attribute — three strawberries are three Tools. `syncItemTools` reconciles the Tools to the tally in both directions and is safe to call after any change.

The tally is kept rather than letting the Tool list simply *be* the truth (as it is for seeds) for one reason: the Backpack is replaced on respawn, and rebuilding from a server-side number is what stops death from wiping an inventory. **The Tools mirror the tally; the tally never mirrors the Tools.** Anything that pays out reads the tally.

Because one Tool is exactly one item, **counting Tools is now a correct way to get a quantity** — the reverse of the older stacked design, which had a single Tool carrying a `FruitCount` attribute. That attribute is gone; anything still reading it is stale. Count across the Backpack *and* the character, since equipping moves a Tool between them.

`Sell All` clears everything, while `Sell Thing That I Hold` sells the one equipped item. Selling trims from the front of the Tool list, which keeps the equipped one — sell one of three and your hand stays full.

A Masterpiece is held, priced and sold by exactly the same code as a strawberry — `Produce` is the only thing that tells them apart, and only `FactoryService` cares (about the `Tier`, to decide which machine takes it). The replicated names predate products and are kept deliberately: `leaderstats.Fruit` and the `FruitName` attribute are a wire contract with the client modules, so they say "fruit" while meaning "produce". The *functions* were renamed to match reality (`addItem`, `takeItem`, `sellAllItems`, `sellHeldItem`).

**`addItem` can partially fail.** Since every item costs a Backpack slot, it is capped by `Config.Inventory.MaxProduce` and returns how many actually fit. Callers must check the return: harvesting leaves the fruit on the plant and the factory leaves the pie in its slot rather than destroying something the player never received. Award first, destroy second — never the reverse.

Unplaced factories now work exactly the same way: **one Tool is exactly one placeable machine.** Two level-2 tier-3s are two Tools. The authoritative list lives in `FactoryService` and the Tools mirror it, which is what makes them survive a respawn replacing the Backpack. `syncFactoryTools` matches them by the `FactoryTier` **and** `FactoryLevel` attributes rather than by name, so a Tool left over from the older stacked scheme — which had no level on it — fails to match anything and is cleaned up instead of lingering beside the new ones claiming to be a machine the player does not own. The old `FactoryCount` attribute is gone; anything still reading it is stale.

There is no longer an asymmetry here: **neither factories nor produce stack.** They did diverge once, when factory stock was a count per tier, and that stopped making sense the moment a machine became a (tier, level) pair — two entries with the same tier and different levels are two different things and must not collapse into one number. `Config.Factory.MaxCarried` is what caps the pile now, because the generator is an endless source.

Because every award and sale now adds or removes a Tool, `ChildAdded`/`ChildRemoved` fire on every quantity change and are a sufficient trigger for client refreshes. (`leaderstats.Fruit` still moves on all of them and is kept as a backstop.)

`leaderstats` holds `Fruit` and `Coins` only. **No DataStore persistence** — everything resets on shutdown.

### The economy

Players join with `Config.Inventory.StartingCoins` (1000), applied by `STAT_DEFAULTS` at the moment the `Coins` value is *created* rather than by `setup` — so whichever path happens to create it first starts it at the same number.

That stake exists because **seeds are bought, not found.** `Seed.price` is the fruit's own sell price times `Config.Seed.CostMultiplier`, so a plant pays for its seed in that many harvests and the two numbers can never drift apart. At 4× the spread runs from a 24-coin apple to a 460-coin watermelon: the opening decision is a row of fast cheap plants against one or two slow rich ones.

**Coins move in exactly two places, and this is the invariant to protect:** `InventoryService.addCoins` and `InventoryService.spendCoins`. Buying a seed is the second caller of `spendCoins` after hiring. `buySeed` layers on top of `grantSeed` rather than replacing it — `grantSeed` is still the free hand-over, which is what keeps the MCP recipe below working — and it checks Backpack room *before* charging, since being charged for a seed with nowhere to put it is the one unrecoverable outcome.

### Rarity

Every species sits in one of **six rarity bands, 0 (Common) to 5 (Mythic)**, authored in `Config.Rarities` and tagged onto each catalogue entry as `Rarity`. `Config.Rarities` *is* the set of bands — keyed by the band number itself, `[0]`..`[5]`, so nothing anywhere adds or subtracts one, and a seventh entry needs no other edit.

**A band is scarcity and nothing else.** It decides how often the belt offers that seed and it says so twice over — the prompt names it, and anything above `Config.Seed.OutlineFromRarity` wears the band's colour as an outline. It does not touch price, grow time, yield or anything a plant does once it is in the ground; all of that is already authored per species.

The bands bucket the catalogue's **own price order, three species at a time**, so a rarer fruit is always the dearer and slower one and the two orderings can never contradict each other:

| Band | Species |
| --- | --- |
| 0 Common | Apple, Pear, Grape |
| 1 Uncommon | Strawberry, Blueberry, Raspberry |
| 2 Rare | Blackberry, Cherry, Peach |
| 3 Epic | Plum, Kiwi, Lemon |
| 4 Legendary | Melon, Orange, Dragon Fruit |
| 5 Mythic | Banana, Coconut, Watermelon |

**Weights are per species, not per band** (24, 16, 11, 7, 5, 3). With three species in each that is 36 / 24 / 17 / 11 / 8 / 5 percent of the belt — verified by simulation at 36.5 / 24.1 / 16.7 / 10.6 / 7.5 / 4.6 over 400k rolls, with every one of the eighteen appearing. At one seed every `SpawnInterval` some Common comes past every 12s while a *particular* Mythic is 99s apart. Rare lands at exactly 27s per species, which is the cadence every species had under the old uniform roll — so the middle band is the anchor and the curve was spread around it.

**Rarity is carried up the refining ladder unchanged**, so a Watermelon Masterpiece is Mythic: baking a thing makes it dearer, never scarcer. `ProductSpec.Rarity` is copied from the source species at generation time rather than looked up later, and `Produce`'s `ItemSpec` exposes it for fruit and product alike — which is the whole of what the price card needs.

Adding a species means giving it a `Rarity` in the catalogue; adding a band means one entry in `Config.Rarities`. Both are picked up by the roll, the prompts, the outlines and the price card with no other edit.

### The refining ladder

Factories come in **five tiers**, and a tier only eats the rung below it: raw fruit → `Pie` → `Cake` → `Tower` → `Banquet` → `Masterpiece`. `Config.Tiers` *is* the ladder — its length is how many tiers exist, and a sixth entry would need no other edit anywhere.

The chain is **per species**, not shared. An apple line and a watermelon line are different businesses all the way up, which is the point of having eighteen species; that means 18 × 5 = 90 products, so they are generated from the catalogue rather than written out. Two things are uniform on purpose: **size means tier** (a Masterpiece is the same size whatever it is made of, so a glance at a slot says how far up it is) and **colour means fruit** (each step bakes the fruit's own colour further toward pastry and then gilt, but the hue survives to the top — eighteen identical gold bricks would read as one item). Strawberry Pie keeps its original 30 coins and 3s exactly; every other number hangs off it.

Prices multiply the *input's* price by a **falling** factor per rung (2.5, 2.2, 2.0, 1.9, 1.8), so depth pays without the top of an eighteen-species chain running away: Apple 6 → 227, Strawberry 12 → 452, Watermelon 115 → 4338. Process times rise (3, 5, 8, 12, 18s), so a full ladder is 46s of machine time.

**One Tool per machine**, named "Tier 3 · Lv 2 Factory" and tagged with `FactoryTier` and `FactoryLevel` attributes. The name is a label; the attributes are the contract — the same selector/proof split as `SeedSpecies` and `FruitName`, and the reason `FactoryController` and `FactoryIndicator` both match on them. **Which tier and level get placed are read server-side off the held Tool**, never sent by the client: sending the level would be a way to place a level-4 machine having picked up a level-1. `StartingFactories` is empty — every machine is won off the generator now — against a `MaxPlaced` of 6.

Adding a tier means adding an entry to `Config.Tiers` plus a colour to `TierColors`. Everything else — the products, the prompts, the Tools, the worker's routing — falls out.

### Levels

Orthogonal to tier: **tier decides *what* a machine eats, level decides how much what it makes is worth.** A level-4 tier-1 and a level-1 tier-4 are both real machines and neither is the other's upgrade. Levels run 1..`Config.Factory.MaxLevel` (4), and `Config.Factory.LevelMultipliers` (`{1, 1.5, 2, 3}`) is the whole of what a level does. Level 1 is 1.0 by definition, so every number the ladder was tuned with still holds at the bottom.

The multiplier lands on the **product**, as a grade on its item id, and products are priced off what went into them — so **a levelled chain compounds**, and `Produce.gradeAfter` is the one place that is expressed. Verified in-game: a level-2 tier-1 machine turns a 12-coin Strawberry into a `Strawberry Pie ×1.5` worth 45 rather than 30, sold for exactly that.

Compounding is steep, and this is the number to watch: a full five-rung ladder of all-level-4 machines multiplies by 3⁵ = 243, taking a Strawberry Masterpiece from 452 coins to **109,836**. That is the design working as chosen rather than a fault, but `LevelMultipliers` is the single knob — flattening it to `{1, 1.15, 1.3, 1.5}` caps the same chain at about 7.6×.

Nothing infers a level from anything: `FactoryModel.levelOf` reads the attribute, the back row of roof pips is presentation, and `Produce.gradeOf` reads the id. Adding a level means one entry in `LevelMultipliers` and bumping `MaxLevel`.

### Where factories come from

`FactoryRngService` deals machines onto `Workspace.FactoryRNG` out of `Config.FactoryRng.Pool`. The belt is the seed shop and charges coins; **this is the factory shop and charges patience** — an offer stands for `SpawnInterval` (10s) and is then thrown away and re-rolled whether or not anybody took it. Taking one is free, and a player starts with none.

**Every player has their own generator**: own slot along the pad, own timer, own RNG level, own offer only they can take. Slots are measured along the pad's own X axis from its own CFrame, so moving or rotating it carries them along — never hardcode a slot position. The pad is currently 50 studs across, so five slots fit at `SlotSpacing` 9; a sixth player gets a warning in Output and an offer hanging off the end.

A roll is two draws, and the second depends on the first:

1. **Which row** of the pool: the generator's own level 70%, the row below 29%, the row above 1%. At the bottom there is no row below and at the top no row above — **the missing weight folds back into the current row** rather than being re-rolled or clamped, so level 1 is 99% / 1% and level 5 is 71% / 29%.
2. **Which box** of that row: normally 50/30/15/5, so box 4 — the best entry in every row — is the rare one. **Except on a row that stepped down**, where all four are 25. That is what stops the 29% case reading as a plain loss.

| RNG Lv | Box 1 (50%) | Box 2 (30%) | Box 3 (15%) | Box 4 (5%) |
| --- | --- | --- | --- | --- |
| 1 | T1 L1 | T1 L2 | T2 L1 | T2 L2 |
| 2 | T1 L3 | T2 L2 | T3 L1 | T3 L2 |
| 3 | T1 L4 | T2 L3 | T3 L3 | T4 L1 |
| 4 | T3 L4 | T4 L2 | T5 L1 | T5 L2 |
| 5 | T4 L3 | T4 L4 | T5 L3 | T5 L4 |

Rows are printed at startup, and every roll is logged under `LogRolls`, so a Config edit is verifiable from Output. Verified by simulation at 400k rolls per level: level 1 gives 49.4/29.9/14.8/5.2 across row 1 and 1.0% into row 2. Note **entries repeat across rows** (T2 L2 is row 1 box 4 *and* row 2 box 2), so a machine's real odds can exceed its box weight — at RNG level 2 T2 L2 lands 28.3% of the time, not 30% × 70%.

The generator's level is stored per player and starts at `StartingLevel` (1). **There is no way to buy an upgrade yet** — `FactoryRngService.setLevel` is the whole of what one would need to call, and it re-rolls the standing offer so the change is visible without waiting out the timer.

### Workers

**Workers are hired, not granted.** A rotating pool of `Config.Worker.PoolSize` unhired candidates stands on `Workspace.Worker` at all times, each rolled its own walk speed (`MinWalkSpeed`..`MaxWalkSpeed`) and priced from it (`HireBaseCost` plus `HireCostPerStud` for every stud above the floor) at the moment it spawns — so a candidate's `HirePrompt` advertises exactly what hiring it will do and cost, because both were fixed before the prompt ever showed. A player starts with **none**. Walking up and tapping E flips that same rig's `owner` from nil to the hiring player; hiring never creates a new rig or re-rolls a stat. An unhired candidate left too long (`RotateInterval`) is destroyed and replaced with a fresh roll, so a run of bad offers is never permanent. `Config.Worker.MaxHired` caps how many one player can hold at once; `CanDismiss` (on by default) lets an owner give one back through its `DismissPrompt` — held, on its own key (`DismissKey`), so it can never be hit while tapping E to hire — with no refund, and the freed slot does **not** return to the pool.

Once hired, a worker runs the whole loop for its owner: harvest a ripe fruit → carry it to one of the owner's factories → come back for the product → walk it to the seller. The coins land on the owner. Its walk speed for the rest of its life is `worker.stats.WalkSpeed`, the value it rolled as a candidate — `advance` reads it per-worker, not from a single `Config.Worker.WalkSpeed`, so a fast hire is a real, permanent difference between rigs and not a cosmetic one.

`Workspace.Worker` is a **zone**, like `Farm` and `Fatory` — not a marker. Both unhired candidates and hired workers stand on it, lined up along its own X axis, measured from the pad's CFrame so moving or rotating it carries the posts along. Candidates occupy the first `PoolSize` post slots; hired workers take slots counting up from there and never give one back, since posts are cosmetic and there is nothing to reclaim.

**A worker is a second actor on the same farm, not a second set of rules.** It never touches `records` in `PlantingService` or `FactoryService`, and only ever writes its *own* hire/dismiss prompt pair. Each service gives it a *query* and a *commit*, and every commit goes through the same transition a player's prompt uses. Those transitions were extracted for exactly this reason and are the invariant to protect:

| Transition | Used by |
| --- | --- |
| `PlantingService.takeFruit` | the harvest prompt, and `pluck` |
| `FactoryService.beginCycle` | the input prompt, and `insertItem` |
| `FactoryService.endCycle` | the output prompt, and `collectProduct` |
| `InventoryService.addCoins` | `sellAllItems`, `sellHeldItem`, and `sellCarried` |
| `InventoryService.spendCoins` | hiring, and `buySeed` — the only two places `Coins` leaves a player |

Add a third actor and it goes through these too. Bypass one and the two paths can diverge — a machine loaded without `beginCycle` never calls `refreshPrompts`, and then the prompt state contradicts the machine. `WorkerService.refreshHirePrompt` guards the same kind of invariant for hiring: it is the only thing that writes either `HirePrompt`'s or `DismissPrompt`'s `Enabled`, so a hired worker can never be left still advertising itself for hire.

**A worker carries exactly one item, in its hands, and it is not a second Backpack.** What it picks never enters the owner's tally, so it does not count against `Config.Inventory.MaxProduce` — a worker keeps earning while its owner's Backpack is full. The item is also visible in the world for the whole trip: what the worker holds *is* its state, the same way a factory's slot is. It is also why dismissal refuses a worker that is carrying something: the item was never in the tally, so dismissing mid-trip would destroy it with no record anywhere — the same shape as a factory refusing pick-up mid-cycle.

That one pair of hands is what shapes the job priority in `chooseJob`, and rule 5 is the subtle one: **a worker will not pick a fruit up unless there is already somewhere to put it.** Fetching one while every machine is busy strands it — it cannot collect the product that machine is about to finish without free hands, so its only outs are standing still or selling the fruit raw for a third of its refined value. Refusing the pickup is what keeps the loop out of that state. `Config.Worker.RefineTimeout` covers the leftover race where the owner loads that machine by hand while the worker is walking to it. An owner with **no** factory still gets fruit fetched and sold raw, which is verified: 12 coins a strawberry, versus 30 for a pie.

**Tiers change nothing about that order and everything about the word "machine".** Every factory question a worker asks is now asked *about the item in its hands*, and `FactoryService` answers by matching tiers:

| Ask | Answers |
| --- | --- |
| `idleFactoryFor(owner, item, …)` | a free machine **of the tier that accepts `item`** |
| `hasWorkingFactoryFor(owner, item)` | is a machine that accepts `item` mid-cycle — rule 2's "worth waiting" |
| `hasFactoryFor(owner, item)` | does the owner own such a machine at all — rule 5's last clause |
| `hasWorkingFactory(owner)` | *any* machine busy; only for "don't walk home yet" |

**Asking the untiered question is the bug to watch for.** A worker holding a Pie that waits because some tier-1 is busy is waiting on a machine that can never help it, and it would do that for the full `RefineTimeout` on every trip. Likewise rule 5's last clause has to be per-tier: an owner with four machines and no tier-1 can refine a strawberry exactly as well as an owner with none, and a worker that could not tell the difference would refuse to pick fruit at all.

What falls out for free is that **a worker walks the whole ladder** — rule 4 hands it a Pie, rule 1 finds the tier-2 that eats Pies, rule 4 hands it the Cake, and so on until rule 3 finds nothing that refines a Masterpiece and sends it to the stall. Verified end to end: one worker, five machines, `Apple → Pie → Cake → Tower → Banquet → Masterpiece`, sold for 227. No step is special-cased.

Rule 4 stays **ungated** and is the one asymmetry left: a worker collects a finished product even with nowhere to take it next. Emptying a machine is progress regardless — it unblocks the rung below — and the worst case is bounded by rule 2's timeout and a raw sale. In practice a single worker feeding a five-deep chain *is* the bottleneck, so intermediate products do get sold raw when the next rung is busy; that is the loop working, not failing.

**The rig is a real R6 character, but it stays `Anchored` and is posed by script.** This is the one place a worker deliberately departs from how a player's character works, and it is the same choice the belt seeds make for the same reasons: players cannot shove a worker off course, there is no jitter, and a worker cannot wedge itself against a factory base and quietly stop earning. Handing locomotion to the `Humanoid` would mean unanchored server physics plus `MoveTo`, which on this map has to push past 7×7 *colliding* machine bases — a stuck worker is a worse bug than a simpler walk cycle. Four consequences, all intentional:

- **The `Motor6D` joints are structural, not what moves the limbs.** Anchored parts ignore their joints, so `setPose` writes each part's CFrame directly. Don't add an `Animation` expecting it to play — unanchor the rig first, and re-read the paragraph above before you do.
- The `Humanoid` is set to `EvaluateStateMachine = false` and `ChangeState(Physics)`, which is the honest description of a script-posed rig. **Order matters:** while the state machine is still evaluating it overrules the change immediately and settles back on `FallingDown`, since the anchored root never touches anything. Its own name and health display are switched off, so a worker carries no floating text at all.
- **No pathfinding.** Workers walk straight lines. Fine for a flat baseplate with pads on it; a worker will walk through anything you build in the way.
- **A worker's height comes from where it is walking *to*, not from a raycast under it.** The pads differ by at most a stud, so easing between the surface it left and the one it is heading for is indistinguishable from following the ground at no per-frame cost. A raycast would also need to exclude the plants, the machines and the workers themselves, or a worker ends up standing on a factory roof.

Parts are `CanCollide = false` **and `CanQuery = false`**. The second matters: `MouseTarget` is the client's only raycast, and a worker crossing the farm would otherwise swallow clicks meant for the ground underneath it.

`setPose` is only called on frames where a worker actually moved, plus one final frame to bring its legs together. Posing a standing worker every frame would replicate ten CFrames to every client to say nothing.

A worker shows **no floating text**: `Config.Worker.ShowStatus` is off, so no `BillboardGui` is built, and the Humanoid's own name plate is disabled too. That makes an autonomous NPC a black box — a worker walking to the far side of the map looks identical to one that is stuck — so turn `ShowStatus` back on while debugging one. `setStatus` and its `refreshStatus` caller stay wired either way and no-op when there is no GUI to write to; `LogActions` covers the same ground from Output.

### Server-authoritative boundaries

The client sends **only a click position**. Everything else is decided server-side, and this is deliberate — don't move these checks to the client:

- position must project onto the farm pad's top face (`farmSurfacePoint`, with an edge margin; rejects the underside and sides)
- the player must actually hold a seed Tool, be within `MaxPlantDistance`, respect `PlantCooldown`, `MinPlantSpacing` and `MaxPlantsPerPlayer`
- **which species is planted comes from the held Tool, never from the client.** The `SeedSpecies` attribute is a selector like `FruitName`, re-checked against `Config.Plants` before anything is built — otherwise a tampered client would plant watermelons from apple seeds
- the seed is consumed **only after every check passes**
- selling re-checks distance to the seller; the dialogue proves nothing
- a produce Tool's `FruitName` attribute is **only a selector** — `sellHeldItem` re-reads quantity and price from server state before paying out

The factory repeats the same shape. The client sends a click position; the server snaps it, and checks the cell is on the zone and free, that the player holds a factory Tool, is within `MaxPlaceDistance`, actually has an unplaced machine of **that exact tier and level**, and is under `MaxPlaced`. **Which tier and level are placed come from the held Tool's `FactoryTier` and `FactoryLevel` attributes, never from the client** — the same rule that decides which species a seed plants — and both are range-checked against the ladder and `MaxLevel`. Stock is consumed only after every check passes, by a `takeUnplaced` that checks and consumes in one step so the Tools and the list cannot drift apart there. Taking an offer off the generator is server-side end to end: the client never names a tier or level, it only presses a prompt. Inserting re-reads the item count from the tally rather than trusting the equipped Tool, re-checks that the recipe's tier matches the machine's, and only the owner may use or pick up a machine. `insertItem` (the worker path) re-checks the tier too, because it is a commit.

A rejected plant request is otherwise **completely silent**, which makes a failed click undiagnosable. Every gate in `onPlantRequest` now names itself in Output via `refuse`, gated on `Config.Farm.LogPlantRequests`. When you add a rule to `FarmSurface` both sides pick it up; add one only to `PlantingService` and the indicator will show green on a spot that fails.

### Growth invariants

**Two timers, in sequence.** A seed lands as the species' `Sprout` form at `Growth.StartScale` and is scaled up by `PlantingService.stepGrowth` over `Growth.Time`; reaching `Growth.MatureScale` rebuilds the geometry as the `Mature` form — the true form — and *only then* starts the fruit timer. First fruit is therefore `Growth.Time + FruitSpec.GrowTime` away (8s + 3s for Strawberry, verified at 7.994s and 11.000s; the eighteen species run from Apple's 7s to Watermelon's 68s).

- Only the true form fruits. `scheduleFruit` returns early unless `record.mature`, so a sprout can never bear.
- The two forms differ in geometry, not just scale: the sprout is a pale two-part seedling, the true form adds a `Crown`. A transformation that was only a size step would be invisible against the scaling that preceded it.
- **Only the true form is authored.** `Config.sproutOf` derives the seedling from it — half the height, 60% the thickness, 35% toward white, no crown — so a species is described once and every sprout on the farm reads as the same stage. All eighteen share one `StartScale`/`MatureScale`, and `HeightOffset` is derived from the fruit's own radius so a watermelon clears its canopy the way a blueberry does. Add a species by adding an entry to `Catalogue`, not by writing a second `FormSpec`.
- **`stepGrowth` iterates `sprouting`, not `records`** — plants leave that list once grown, so a farm of mature plants costs nothing per frame. It also drops any plant whose `model.Parent` went nil mid-grow.
- Scale is applied by recomputing every part's `Size` and `CFrame` from the spec (`PlantModel.setScale` → `layout`), never by stepping last frame's values, so repeated calls cannot accumulate drift. Growth is anchored at the base: the plant rises out of the ground rather than expanding about its centre.
- **A plant's footprint is its `Ground` attribute, not its pivot.** The pivot is the stem's centre and therefore moves as the plant scales; `place` writes the attribute and `groundOf` reads it back, which is what keeps the client's spacing preview honest about a half-grown sprout. `PlantModel.fruitPosition` measures against `Mature.StemHeight` for the same reason.
- `buildForm` destroys only `Stem`/`Leaves`/`Crown`. A ripe `Fruit` belongs to the plant, not to the form it hangs on.
- `Regrow = true` reschedules after harvest, so one plant is a repeatable source. Regrowth restarts the *fruit* timer only — the plant stays mature at full scale and never re-sprouts.
- A species with `Fruit = nil` grows to its true form but bears nothing. All eighteen currently bear; the field is optional so barren species need no growth-code changes. Note that `Seed.price` would make such a species *free*, since it prices seeds off the fruit.
- `scheduleFruit` guards on `record.growing` / `record.fruit` and re-checks `model.Parent` after the delay, since the plant can be removed while the timer runs.
- Belt seeds and fruit are **`Anchored`, `CanCollide = false`**, moved by script — deliberately not physics. Players can't knock them around and there's no jitter.
- Belt seed positions are computed in **belt-local space**, so moving or rotating `Workspace.Conveyor` carries the flow with it. Never hardcode world coordinates.
- Seeds ride **single file down the belt's centreline** — the lateral term in `cframeFor` is a literal zero, not a jitter value. One lane is what makes the seed under the prompt unambiguous and the one behind it readable while you decide whether to pay.

### Client gotchas

Both of the following now live in **`ToolWatcher`** and nowhere else. Register a handler with `ToolWatcher.onActivated(name, fn)` — or `onActivatedAttribute(attribute, fn)` for a family of Tools sharing a job rather than a name — instead of watching containers yourself; a second copy is a second chance to get these wrong.

Equipping moves a Tool to the character and unequipping moves it back, so `Backpack.ChildAdded` fires repeatedly for the same tool. `ToolWatcher` keeps a `watched` set — without it, each equip cycle adds another `Activated` connection and one click plants twice.

**Respawning replaces the Backpack.** Binding to whichever Backpack exists at startup breaks permanently after the first death: seeds land in a container nobody is watching and clicks do nothing, with no error. Re-attach on `Player.ChildAdded` for a new `Backpack` and on `CharacterAdded`. This cost hours to find — it presents exactly as "planting worked, then stopped".

Aim with `Mouse.UnitRay`, not `ViewportPointToRay(mouse.X, mouse.Y)`: `UnitRay` is already the ray through the cursor, so there is no viewport/GUI-inset conversion to get wrong.

## Luau conventions

`.luaurc` sets `languageMode: strict` with all lints on. Every file starts with `--!strict`. Indentation is **tabs**.

Instance lookups return `Instance?` under strict mode, so existing code does the nil check then an explicit `:: Type` cast. Match that rather than disabling strict mode.

## Roblox Studio MCP workflow

This is the primary way to verify changes:

- Call `list_roblox_studios` then `set_active_studio` first — **no instance is active by default**, and the id changes whenever Studio restarts.
- `execute_luau` requires `datamodel_type`: `Edit` in edit mode, `Server`/`Client` during play.
- `start_stop_play` enters/exits the play test; `get_console_output` reads the log.
- `screen_capture` renders the viewport, and does include ScreenGui and proximity prompts — but never Studio's own toolbars, Explorer, or the Rojo panel.

### `execute_luau` requires get their own module cache

**A module required from `execute_luau` is a *separate instance* from the one the running `ServerScriptService.Server` scripts hold.** Mutating server state through it diverges the two copies: calling `InventoryService.addFruit` from MCP bumped *its* tally, wrote `leaderstats` and the Tool attribute, while `SellService`'s copy still saw zero and refused the sale. That looks exactly like a product bug and is not one.

So state injected this way is a lie. Side effects on real Instances (creating a Tool, moving a character) *are* shared and safe — it is only module-local tables that split. To exercise anything stateful, drive the real path: fire the remote, or trigger the prompt with `user_keyboard_input`.

A working recipe for the full loop, since driving it by hand is fiddly:

1. Server: `require(game.ServerScriptService.Server.InventoryService)` then `grantSeed(player)`; `Character:PivotTo(...)` onto the farm; `Humanoid:EquipTool(tool)`.
2. Client: `Remotes.event(Remotes.PLANT_SEED):FireServer(position)` — the same call the real click makes, without needing a raycast.
3. Harvest/sell prompts need real input: `user_keyboard_input` with `E` and `datamodel_type: Client`.
4. GUI buttons need `user_mouse_input`; get coordinates from the button's `AbsolutePosition` + `AbsoluteSize`.

**MCP round trips can exceed 3 seconds**, so a wait-then-check across two calls cannot prove a 3s timer. To time something, arm a persistent `ChildAdded`/`ChildRemoved` listener that `print`s in one call, act in a second, then read the console.

### A minimized Studio window silently eats all input

**Nothing that needs rendering or input works while Studio is minimized**, and none of it errors:

- `user_keyboard_input` and `user_mouse_input` return `Success` and reach nothing.
- ProximityPrompts never appear, so they cannot be triggered — `ProximityPromptService.PromptShown` never fires, and `prompt:InputHoldBegin()` from the client does nothing either.
- `screen_capture` hangs until the tool times out and backgrounds itself.

`execute_luau` keeps working throughout, so the game looks alive while every prompt in it is unreachable. This presents exactly as "the feature I just wrote does nothing".

Check it before doubting the code — `IsIconic` on `RobloxStudioBeta`'s `MainWindowHandle` via `Add-Type`, or grep the Studio log for `[FLog::AutoSaveDelayOnUserInputLog] No user input within the last 5000 ms`. `ShowWindow(handle, 9)` plus `SetForegroundWindow` restores it, and prompts start working again immediately.

### When the MCP bridge is down, read the log instead

**Studio writes its whole Output to disk** at `%LOCALAPPDATA%\Roblox\logs\*_Studio_*.log` (newest by `LastWriteTime` is the live session). `print` appears as `[FLog::CreatorOutput]`, `warn` as `[FLog::CreatorWarning]`, each line timestamped in UTC.

This needs no plugin and no bridge, and works when `list_roblox_studios` returns nothing. Grep it for your own `[Service]` tags. A background poll on that file also catches a play test that happens later, which beats asking the user to copy Output back.

To check whether Rojo is connected, look for Studio holding an established socket to port 34872 (`Get-NetTCPConnection`) — an active session keeps a long poll open. To inspect the *place* without Studio, the binary `.rbxl` is parseable: 32-byte header, then 16-byte chunk headers; `INST` chunks give class names and counts, and the `PROP` chunk named `Name` lists instance names in the same order. Chunks are LZ4, or zstd when they start with `28 B5 2F FD`.

### Rojo drops out during play tests

Watch for this in Output:

```
[Rojo-Warn] Disconnected from an error: Unknown HTTP error:
            Http requests can only be executed by game server
```

Studio blocks plugin HTTP in a play-test context, so the plugin gives up and **new code silently stops arriving**. If a change seems to have no effect, check this before doubting the change.

## Known gaps

- Anyone can harvest anyone's plant — fruit prompts have no ownership check. Factories *do* check, and so do workers, so don't assume the codebase is uniform here.
- No persistence: seeds, fruit, coins, plants, factories and hired workers all reset on shutdown — including whatever a player spent hiring them.
- A worker will walk straight through anything built between two pads, and drops fruit into no queue: several workers sharing one factory contend for it exactly the way two players would, so a farm can ripen faster than a small factory count can clear it.
- Dismissing a moving worker means catching it — it pauses at each stop and walks predictable routes, so it is possible, but there is no way to recall one home first.
- A dismissed worker's slot is not returned to the pool, and neither is a departing player's — both are simply gone rather than reissued. There is no persistence anyway, so this only matters within a single round.
- Unhired candidates look identical to hired ones apart from which prompt they show. A distinct look while unhired (a different shirt colour, say) would read better at a glance across the whole pad.
- Stats are rolled uniformly across `MinWalkSpeed`..`MaxWalkSpeed`, with no rarity curve, and walk speed is the only one that exists. `WorkerStats` is already a table rather than a bare number so a second stat would not change every signature that passes one around — but none has been added.
- A factory holds one item at a time and only the owner can use it; a non-owner still sees the prompt and gets a logged refusal. **The generator's Take prompt has the same gap** — everyone can see everyone's offer, and pressing E on someone else's just logs a refusal.
- **`Config.Factory.CanRemove` was turned on for the level system and has to stay on.** With machines coming off a generator whose own level rises, a player's first six pick-ups are all low level; with pick-up off those six cells would be the whole game and a better machine could never replace a worse one, which would make levels decorative. `onRemove` still refuses a machine that is working or has a product waiting.
- **A full ladder needs five machines and `MaxPlaced` is six**, so a player can hold one complete chain plus a spare and no second line. That is now a real cap rather than a theoretical one, because the generator is endless — the binding constraints are cells and luck rather than allocation.
- **The generator deals one machine at a time and cannot be asked for a tier.** At RNG level 1 it only ever offers tier 1 and 2, so the top of the ladder is unreachable until the generator is upgraded — and there is **no way to upgrade it yet**, which means tiers 3–5 are currently unreachable in a real game. `setLevel` works and is wired; nothing calls it. This is the biggest missing piece.
- **The level curve compounds hard.** Five all-level-4 machines multiply a chain by 243 (a Strawberry Masterpiece at 109,836 against a base 452). Intended, but `Config.Factory.LevelMultipliers` is the only knob and it has not been balanced against anything.
- **Nothing scales with level except price.** A level-4 machine is no faster than a level-1 and holds no more; `ProcessTime` still comes from the tier alone.
- **One worker cannot keep a five-deep chain fed.** It has one pair of hands and the ladder has five rungs, so intermediate products get sold raw when the next rung is busy (observed: Cakes at 33 and Towers at 66 while the top was working). That is rule 2 and 4 behaving as designed rather than a fault, but it does mean the marginal value of a second worker is now much higher than the marginal value of a deeper chain — and `MaxHired` is 3.
- **Tier and level are chosen at placement and never change.** There is no upgrade path for a placed machine: a tier-2 cannot become a tier-3 and a level-1 cannot become a level-2. The only way up is picking it up and placing a better one, which is why `CanRemove` matters.
- **The belt is the only way to buy a seed, and it deals one species at a time.** Six are on a 122-stud belt at once, so there is always *something* to buy, but not always the thing you wanted — and now that the roll is weighted, waiting for a specific Mythic averages 99s. `SpawnInterval`, `Speed` and the band weights are the knobs; there is still no way to ask for a species, and no reroll.
- **Rarity gates the belt and nothing else.** It has no bearing on grow time, yield, worker behaviour or what a factory does with the fruit — a Mythic is just a fruit you had to wait at the belt for. There is also no pity timer, so a genuinely unlucky run of rolls is simply unlucky.
- Worker stats are still rolled uniformly across `MinWalkSpeed`..`MaxWalkSpeed`. Species now have a rarity curve; hires do not, so the two systems are inconsistent in a way that is only defensible while `WorkerStats` has one field in it.
- `Config.Inventory.StartingCoins` is still enough for one 460-coin watermelon plus change, so a new player who happens to see a Mythic go past can skip straight to the top tier. Scarcity now makes that a matter of waiting rather than of choosing, which is the intended shape — but it does mean the opening minute is decided partly by the roll.
- `aftman.toml` pins rojo `7.7.0-rc.1`, a release candidate, because that version was already installed locally.
