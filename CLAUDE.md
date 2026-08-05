# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Roblox tycoon-style game ("Stawberry" — the misspelling is the project name), synced into Roblox Studio with Rojo. One gameplay loop is implemented end to end: a conveyor produces seeds → plant them on the farm → harvest fruit → sell at the seller.

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
- `Fatory` is a typo for "Factory" but is load-bearing — grep for the name before renaming.
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

- **`Config`** — data only, no behaviour. All tuning plus the `PlantSpec`/`FruitSpec` types. Prefer adding a config value over hardcoding.
- **`Remotes`** — lazily creates (server) or waits for (client) `ReplicatedStorage.Remotes`, so neither side depends on load order. Access via `Remotes.event(Remotes.PLANT_SEED)` / `Remotes.func(Remotes.SELL_FRUIT)`.
- **`Seed`** — `createPickup()` for the belt ball, `createTool()` for the Backpack item.
- **`PlantModel`** — builds plant and fruit geometry from a species entry.

Server, started in this order by `init.server.luau` (inventory first, the rest award into it):

- **`InventoryService`** — owns everything carried. Also indexes fruit → price from `Config.Plants` at startup.
- **`ConveyorService`** — spawns/moves/despawns belt seeds, grants on pickup.
- **`PlantingService`** — validates plant requests, grows fruit, handles harvest.
- **`SellService`** — creates the seller prompt, settles sales.

Client:

- **`PlantingController`** — reports where the player clicked while holding a seed.
- **`SellDialogue`** — code-built ScreenGui, opened by the seller prompt.

### Inventory model

Seeds are **Tools in the Backpack** — that Tool list *is* the seed inventory, so there is no parallel seed counter to drift. `InventoryService.seedCount` therefore counts both the Backpack *and* the character, because an equipped tool moves to the character.

Fruit is a server-side per-species tally (`fruitByPlayer`), mirrored to `leaderstats.Fruit` as a display-only total. Keeping the tally per-species is what lets sales price each fruit correctly; don't collapse it to a single number. Each species also has one generated stack Tool marked with a `FruitName` attribute so the player can equip that produce. The Tool only selects the held species; the server tally remains authoritative. `Sell All` clears every stack, while `Sell Thing That I Hold` sells one unit from the equipped stack.

`leaderstats` holds `Fruit` and `Coins` only. **No DataStore persistence** — everything resets on shutdown.

### Server-authoritative boundaries

The client sends **only a click position**. Everything else is decided server-side, and this is deliberate — don't move these checks to the client:

- position must project onto the farm pad's top face (`farmSurfacePoint`, with an edge margin; rejects the underside and sides)
- the player must actually hold a seed Tool, be within `MaxPlantDistance`, respect `PlantCooldown`, `MinPlantSpacing` and `MaxPlantsPerPlayer`
- the seed is consumed **only after every check passes**
- selling re-checks distance to the seller; the dialogue proves nothing

### Growth invariants

- Plants appear fully formed (instant growth is intentional for now). Only **fruit** is timed — `FruitSpec.GrowTime`, currently 3s, verified at 3.001s.
- `Regrow = true` reschedules after harvest, so one plant is a repeatable source.
- A species with `Fruit = nil` grows but bears nothing. Only the fruit-bearing `Strawberry` exists; the field is optional so barren species need no growth-code changes.
- `scheduleFruit` guards on `record.growing` / `record.fruit` and re-checks `model.Parent` after the delay, since the plant can be removed while the timer runs.
- Belt seeds and fruit are **`Anchored`, `CanCollide = false`**, moved by script — deliberately not physics. Players can't knock them around and there's no jitter.
- Belt seed positions are computed in **belt-local space**, so moving or rotating `Workspace.Conveyor` carries the flow with it. Never hardcode world coordinates.

### Client gotchas

Equipping moves a Tool to the character and unequipping moves it back, so `Backpack.ChildAdded` fires repeatedly for the same tool. `PlantingController` keeps a `watched` set — without it, each equip cycle adds another `Activated` connection and one click plants twice.

## Luau conventions

`.luaurc` sets `languageMode: strict` with all lints on. Every file starts with `--!strict`. Indentation is **tabs**.

Instance lookups return `Instance?` under strict mode, so existing code does the nil check then an explicit `:: Type` cast. Match that rather than disabling strict mode.

## Roblox Studio MCP workflow

This is the primary way to verify changes:

- Call `list_roblox_studios` then `set_active_studio` first — **no instance is active by default**, and the id changes whenever Studio restarts.
- `execute_luau` requires `datamodel_type`: `Edit` in edit mode, `Server`/`Client` during play.
- `start_stop_play` enters/exits the play test; `get_console_output` reads the log.
- `screen_capture` renders the viewport, and does include ScreenGui and proximity prompts — but never Studio's own toolbars, Explorer, or the Rojo panel.

A working recipe for the full loop, since driving it by hand is fiddly:

1. Server: `require(game.ServerScriptService.Server.InventoryService)` then `grantSeed(player)`; `Character:PivotTo(...)` onto the farm; `Humanoid:EquipTool(tool)`.
2. Client: `Remotes.event(Remotes.PLANT_SEED):FireServer(position)` — the same call the real click makes, without needing a raycast.
3. Harvest/sell prompts need real input: `user_keyboard_input` with `E` and `datamodel_type: Client`.
4. GUI buttons need `user_mouse_input`; get coordinates from the button's `AbsolutePosition` + `AbsoluteSize`.

**MCP round trips can exceed 3 seconds**, so a wait-then-check across two calls cannot prove a 3s timer. To time something, arm a persistent `ChildAdded`/`ChildRemoved` listener that `print`s in one call, act in a second, then read the console.

## Known gaps

- Anyone can harvest anyone's plant — fruit prompts have no ownership check.
- No persistence: seeds, fruit, coins and plants all reset on shutdown.
- `Worker` and `Fatory` have no behaviour attached yet.
- Seeds are untyped — every seed plants `Config.DefaultSpecies`.
- `aftman.toml` pins rojo `7.7.0-rc.1`, a release candidate, because that version was already installed locally.
