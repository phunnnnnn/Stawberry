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

`Baseplate`, `SpawnLocation`, `Farm`, `Fatory`, `Worker`, `Seller`, `Conveyor{Part, Part, conveyor}`

### Always commit the place file with code changes

The map and the code must move together, or a checkout pairs new scripts with an old map. `.githooks/pre-commit` force-stages `place/Stawberry.rbxl` and warns when it looks older than `src/`.

**Use `git add -A` before committing.** The `.gitignore` negation means that picks up the place file. The hook can only *augment* a commit that already has something staged — git decides "nothing added to commit" before honouring the hook's index changes, so when a Studio save is the only change `git commit` aborts anyway, leaving the file staged. Stage it yourself in that case.

The hook cannot flush unsaved Studio state to disk. **Before committing anything that touched geometry, tell the user to save in Studio (Ctrl+S)** — otherwise the staged place file is stale and the warning is the only signal.

### Other consequences

- `rojo build` output contains **no map** — scripts only. It is not a playable place.
- Geometry changed via MCP in Edit mode exists only in memory until the user saves. Always tell them to save.
- The place began as a cloud place (`PlaceId 113158059729469`) and was moved to a local file. Local saves do **not** reach Roblox — that needs **File > Publish to Roblox**.
- `Fatory` is a typo for "Factory" but is load-bearing — it is the factory placement zone (`Config.Factory.ZoneName`). Grep for the name before renaming.
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

- **`Config`** — data only, no behaviour. All tuning plus the `PlantSpec`/`FruitSpec`/`ProductSpec` types. Prefer adding a config value over hardcoding.
- **`Produce`** — one index of everything carryable and sellable, built from `Config.Plants` fruit *and* `Config.Products`. Fruit and factory products are deliberately the same shape here; that is what lets one tally and one stack-Tool mechanism hold both. Anything quoting or charging a price reads it from here — a second copy would eventually quote a number the seller does not honour.
- **`Remotes`** — lazily creates (server) or waits for (client) `ReplicatedStorage.Remotes`, so neither side depends on load order. Access via `Remotes.event(Remotes.PLANT_SEED)` / `Remotes.func(Remotes.SELL_FRUIT)`.
- **`Seed`** — `createPickup()` for the belt ball, `createTool()` for the Backpack item.
- **`PlantModel`** — builds plant and fruit geometry from a species entry. `groundOf` is the inverse of `place`, so the client can recover a plant's footprint from the replicated model.
- **`FarmSurface`** — pure placement rules: `project` (click → point on the pad's top face) and `tooClose` (spacing). Shared **so the client's indicator cannot promise a spot the server refuses**. Add new placement rules here, not in either caller.
- **`FactoryGrid`** — the same idea for the factory zone, but snapping to a lattice: `project` (click → centre of its grid cell) and `occupied`. Cells are measured from the zone's own centre, so moving or rotating the pad carries the grid with it — never hardcode cell coordinates.
- **`FactoryModel`** — builds machine geometry. `groundOf` is the inverse of `place`, and `showItem` puts an item on display in the machine's slot.

Server, started in this order by `init.server.luau` (inventory first, the rest award into it):

- **`InventoryService`** — owns everything carried. Prices and item geometry come from `Produce`.
- **`ConveyorService`** — spawns/moves/despawns belt seeds, grants on pickup.
- **`PlantingService`** — validates plant requests, grows fruit, handles harvest.
- **`FactoryService`** — validates factory placement, then runs each machine's insert → wait → collect cycle.
- **`SellService`** — creates the seller prompt, settles sales.

Client:

- **`MouseTarget`** — the one raycast under the cursor. Every controller and indicator uses it; two separate raycasts could disagree and the preview would lie.
- **`ToolWatcher`** — the single answer to "the player activated a Tool called X". Owns the equip-cycle and respawn bookkeeping described under *Client gotchas*; `PlantingController` and `FactoryController` are thin handlers registered against it. **Add new tool-driven actions here rather than re-implementing the container watching**, which is exactly the bug that cost hours below.
- **`PlantingController`** — reports where the player clicked while holding a seed.
- **`FactoryController`** — the same for a held factory. It sends the raw click; snapping happens server-side, so a client that snapped differently could only disagree.
- **`FactoryIndicator`** — preview square for the grid cell a factory will land on. Display-only. Snap-to-grid is invisible without it: the machine goes to the middle of the cell, not to the click.
- **`PlantIndicator`** — `RenderStepped` preview disc, green where the click will land, red plus a reason where it won't. Cosmetic: it re-checks `FarmSurface` rules for *feedback* and changes no outcome. It cannot preview `MaxPlantsPerPlayer`, which the client has no way to read.
- **`FruitInspector`** — price card shown while produce is equipped: unit price, how many of that item you carry, total value.
- **`Leaderboard`** — always-visible board ranking players by `Coins`, read straight off each player's `leaderstats`.
- **`SellDialogue`** — code-built ScreenGui, opened by the seller prompt.

`PlantIndicator`, `FactoryIndicator`, `FruitInspector` and `Leaderboard` are display-only and each starts behind its own `pcall` in `init.client.luau`. That is deliberate: a require error in a cosmetic module previously killed the whole LocalScript and silently disabled planting.

### Inventory model

Seeds are **Tools in the Backpack** — that Tool list *is* the seed inventory, so there is no parallel seed counter to drift. `InventoryService.seedCount` therefore counts both the Backpack *and* the character, because an equipped tool moves to the character.

Produce — harvested fruit **and factory products alike** — is a server-side per-item tally (`itemsByPlayer`), mirrored to `leaderstats.Fruit` as a display-only total. Keeping the tally per-item is what lets sales price each thing correctly; don't collapse it to a single number.

**Produce does not stack.** The tally materialises as one Tool per item, each marked with a `FruitName` attribute — three strawberries are three Tools. `syncItemTools` reconciles the Tools to the tally in both directions and is safe to call after any change.

The tally is kept rather than letting the Tool list simply *be* the truth (as it is for seeds) for one reason: the Backpack is replaced on respawn, and rebuilding from a server-side number is what stops death from wiping an inventory. **The Tools mirror the tally; the tally never mirrors the Tools.** Anything that pays out reads the tally.

Because one Tool is exactly one item, **counting Tools is now a correct way to get a quantity** — the reverse of the older stacked design, which had a single Tool carrying a `FruitCount` attribute. That attribute is gone; anything still reading it is stale. Count across the Backpack *and* the character, since equipping moves a Tool between them.

`Sell All` clears everything, while `Sell Thing That I Hold` sells the one equipped item. Selling trims from the front of the Tool list, which keeps the equipped one — sell one of three and your hand stays full.

A pie is held, priced and sold by exactly the same code as a strawberry — `Produce` is the only thing that tells them apart, and only `FactoryService` cares. The replicated names predate products and are kept deliberately: `leaderstats.Fruit` and the `FruitName` attribute are a wire contract with the client modules, so they say "fruit" while meaning "produce". The *functions* were renamed to match reality (`addItem`, `takeItem`, `sellAllItems`, `sellHeldItem`).

**`addItem` can partially fail.** Since every item costs a Backpack slot, it is capped by `Config.Inventory.MaxProduce` and returns how many actually fit. Callers must check the return: harvesting leaves the fruit on the plant and the factory leaves the pie in its slot rather than destroying something the player never received. Award first, destroy second — never the reverse.

Unplaced factories work the same way: one `Factory` Tool carrying the whole stock as a `FactoryCount` attribute, rebuilt from a server-side number. That is what makes it survive a respawn replacing the Backpack.

Note the asymmetry: **factory stock stacks, produce does not.** One `Factory` Tool with a count, but one Tool per strawberry. That is deliberate — you place factories one at a time from a pile, whereas produce is meant to be individually visible and equippable in the hotbar.

Because every award and sale now adds or removes a Tool, `ChildAdded`/`ChildRemoved` fire on every quantity change and are a sufficient trigger for client refreshes. (`leaderstats.Fruit` still moves on all of them and is kept as a backstop.)

`leaderstats` holds `Fruit` and `Coins` only. **No DataStore persistence** — everything resets on shutdown.

### Server-authoritative boundaries

The client sends **only a click position**. Everything else is decided server-side, and this is deliberate — don't move these checks to the client:

- position must project onto the farm pad's top face (`farmSurfacePoint`, with an edge margin; rejects the underside and sides)
- the player must actually hold a seed Tool, be within `MaxPlantDistance`, respect `PlantCooldown`, `MinPlantSpacing` and `MaxPlantsPerPlayer`
- the seed is consumed **only after every check passes**
- selling re-checks distance to the seller; the dialogue proves nothing
- a produce Tool's `FruitName` attribute is **only a selector** — `sellHeldItem` re-reads quantity and price from server state before paying out

The factory repeats the same shape. The client sends a click position; the server snaps it, and checks the cell is on the zone and free, that the player holds the `Factory` Tool, is within `MaxPlaceDistance`, has stock left and is under `MaxPlaced`. Stock is consumed only after every check passes. Inserting re-reads the fruit count from the tally rather than trusting the equipped Tool, and only the owner may use or pick up a machine.

A rejected plant request is otherwise **completely silent**, which makes a failed click undiagnosable. Every gate in `onPlantRequest` now names itself in Output via `refuse`, gated on `Config.Farm.LogPlantRequests`. When you add a rule to `FarmSurface` both sides pick it up; add one only to `PlantingService` and the indicator will show green on a spot that fails.

### Growth invariants

- Plants appear fully formed (instant growth is intentional for now). Only **fruit** is timed — `FruitSpec.GrowTime`, currently 3s, verified at 3.001s.
- `Regrow = true` reschedules after harvest, so one plant is a repeatable source.
- A species with `Fruit = nil` grows but bears nothing. Only the fruit-bearing `Strawberry` exists; the field is optional so barren species need no growth-code changes.
- `scheduleFruit` guards on `record.growing` / `record.fruit` and re-checks `model.Parent` after the delay, since the plant can be removed while the timer runs.
- Belt seeds and fruit are **`Anchored`, `CanCollide = false`**, moved by script — deliberately not physics. Players can't knock them around and there's no jitter.
- Belt seed positions are computed in **belt-local space**, so moving or rotating `Workspace.Conveyor` carries the flow with it. Never hardcode world coordinates.

### Client gotchas

Both of the following now live in **`ToolWatcher`** and nowhere else. Register a handler with `ToolWatcher.onActivated(name, fn)` rather than watching containers yourself — a second copy is a second chance to get these wrong.

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

- Anyone can harvest anyone's plant — fruit prompts have no ownership check. Factories *do* check, so don't assume the codebase is uniform here.
- No persistence: seeds, fruit, coins, plants and factories all reset on shutdown.
- `Worker` has no behaviour attached yet.
- Factory stock is fixed at `StartingStock` — there is no way to earn more, so `MaxPlaced` is currently unreachable. It is a guard for when there is.
- A factory holds one item at a time and only the owner can use it; a non-owner still sees the prompt and gets a logged refusal.
- Seeds are untyped — every seed plants `Config.DefaultSpecies`.
- `aftman.toml` pins rojo `7.7.0-rc.1`, a release candidate, because that version was already installed locally.
