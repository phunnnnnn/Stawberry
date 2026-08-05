# Stawberry

A Roblox farming/tycoon game synced with [Rojo](https://rojo.space).

## Setup

```sh
aftman install       # installs the pinned rojo version
rojo plugin install  # installs the Rojo plugin into Roblox Studio
```

## Workflow

Start the sync server, then hit **Connect** in the Rojo panel inside Studio:

```sh
rojo serve
```

Edits to files under `src/` now flow into Studio live.

## The loop

1. The conveyor at `Workspace.Conveyor` produces seeds. Press **E** to collect one — it goes into your Backpack.
2. Equip the seed and **click the farm** to plant a strawberry.
3. Fruit appears after 3 seconds. Press **E** to harvest it; the plant bears again.
4. Take fruit to `Workspace.Seller` and press **E** to open the sell dialogue.

Tuning for all of the above lives in `src/shared/Config.luau`.

## Layout

| Path          | Syncs to                                    |
| ------------- | ------------------------------------------- |
| `src/shared`  | `ReplicatedStorage.Shared`                  |
| `src/server`  | `ServerScriptService.Server`                |
| `src/client`  | `StarterPlayer.StarterPlayerScripts.Client` |

## The map is not in `src/`

Rojo syncs the scripts only. The Workspace geometry lives in the Studio place
itself, so `rojo build` produces a **scripts-only** place with no map:

```sh
rojo build -o build/Stawberry.rbxlx
```

To version the map, export it from Studio with **File > Save As** to
`place/Stawberry.rbxl` — `.gitignore` already makes that one path an exception.
