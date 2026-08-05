# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Roblox tycoon-style game ("Stawberry" — the misspelling is the project name), synced into Roblox Studio with Rojo. Early stage: a conveyor produces collectable placeholder seeds; nothing else is wired up yet.

## Commands

```sh
aftman install                       # required after clone — installs pinned rojo
rojo serve                           # sync server on port 34872
rojo build -o build/Stawberry.rbxlx  # scripts only, see caveat below
rojo plugin install                  # install/refresh the Rojo Studio plugin
```

`rojo` is an Aftman shim. Without `aftman install` it fails with *"no aftman.toml files list this tool"* — that is a missing toolchain, not a broken install.

After `rojo serve`, someone must click **Connect** in Studio's Rojo panel. That is a plugin widget and cannot be automated — ask the user to click it.

There is **no test framework and no linter configured**. Verification is done by play-testing through the Roblox Studio MCP (see below). Don't invent a test command.

## Two sources of truth — read this before editing anything

Rojo owns **only** the three script branches. All Workspace geometry exists solely in the Studio place file and is **not** version controlled:

`Baseplate`, `SpawnLocation`, `Farm`, `Fatory`, `Worker`, `Seller`, `Conveyor{Part, Part, conveyor}`

Consequences:

- `rojo build` output contains **no map** — scripts only. It is not a playable place.
- Geometry changed via MCP in Edit mode is lost unless the user saves in Studio (Ctrl+S). Always tell them to save.
- `Fatory` is a typo for "Factory" but is load-bearing — grep for the name before renaming.

## Rojo mapping

| Source | Studio | Class |
| --- | --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` | Folder |
| `src/server` | `ServerScriptService.Server` | **Script** |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | **LocalScript** |

Because `src/server` and `src/client` contain `init.server.luau` / `init.client.luau`, the *folder itself becomes the script* and sibling files become its **children**. So inside `init.server.luau` you require siblings as `require(script.ConveyorService)` — **not** `script.Parent.ConveyorService`. Getting this wrong is the most likely cause of a "not a valid member" error after adding a server module.

`default.project.json` also sets `Lighting.Technology = Future`.

## Architecture

- **`src/shared/Config.luau`** — data only, no behaviour. All conveyor and seed tuning lives here; prefer adding a config value over hardcoding.
- **`src/shared/Seed.luau`** — code-generates the placeholder seed part and its `ProximityPrompt`. Deliberately generated rather than a saved `.rbxmx` so it stays in version control. Swap `Seed.create` for a mesh clone later without touching conveyor logic.
- **`src/server/ConveyorService.luau`** — spawn, movement, despawn, pickup award.
- **`src/client/init.client.luau`** — watches `leaderstats.Seeds` and prints changes. No UI yet.

### Conveyor invariants

These are load-bearing and easy to break:

- Seeds are **`Anchored = true`, `CanCollide = false`**, moved by CFrame on `RunService.Heartbeat`. This is deliberately **not** physics — players can't knock seeds off the belt and there's no jitter. Don't "fix" it into a velocity-based conveyor without reason.
- Seed positions are computed in **belt-local space** (`belt.CFrame * CFrame.new(lane, surfaceOffset, offset)`), so moving or rotating `Workspace.Conveyor` in Studio carries the seed flow with it. **Never hardcode world coordinates.**
- `Config.Conveyor.Direction` (`1` or `-1`) drives travel along the belt's **local Z**. `entryOffset`/`exitOffset` and `reachedEnd` all branch on its sign — change direction handling in all three or seeds will never despawn.
- `MaxActiveSeeds` is a safety cap so an uncollected stream can't grow Workspace without bound.
- Pickup is **server-authoritative** (`ProximityPrompt.Triggered` handled server-side) with a per-record `claimed` flag guarding double-award.
- The belt must be `Anchored`; the service warns rather than failing if it isn't.

### Player state

`leaderstats/Seeds` (IntValue), created lazily by `seedCounterFor` — called on `PlayerAdded` and again on pickup, so it is safe to call repeatedly. **No DataStore persistence** — counts reset every session.

## Luau conventions

`.luaurc` sets `languageMode: strict` with all lints on. Every file starts with `--!strict`. Indentation is **tabs**.

Instance lookups return `Instance?` under strict mode, so existing code uses explicit `:: Type` casts after the nil check (see `seedCounterFor`). Match that pattern rather than disabling strict mode.

## Roblox Studio MCP workflow

This is the primary way to verify changes:

- Call `list_roblox_studios` then `set_active_studio` first — **no instance is active by default**.
- `execute_luau` requires `datamodel_type`: `Edit` in edit mode, `Server`/`Client` during play. Reading runtime state needs a play session.
- `start_stop_play` enters/exits the play test; `get_console_output` reads the log.
- `screen_capture` renders the **3D viewport only** — never Studio's toolbars, Explorer, or the Rojo panel. Don't try to read UI state from it.
- To test a pickup: teleport the character next to the belt with `Character:PivotTo(...)`, then send `E` via `user_keyboard_input` with `datamodel_type: Client`.

## Known gaps

- `Farm`, `Fatory`, `Worker`, `Seller` are **unanchored** — large pads players can shove around. Only `Conveyor`, `Baseplate`, and `SpawnLocation` are anchored.
- Not a git repo yet, despite the `.gitignore`.
- Seeds despawn at the belt's end with no destination — the conveyor isn't connected to `Farm`, `Fatory`, or `Seller`.
- `aftman.toml` pins rojo `7.7.0-rc.1`, a release candidate, because that version was already installed locally.
