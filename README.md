# Stawberry

A Roblox farming/tycoon game synced with [Rojo](https://rojo.space).

## Setup

```sh
aftman install                       # installs the pinned rojo version
git config core.hooksPath .githooks  # keeps the place file in every commit
rojo plugin install                  # installs the Rojo plugin into Roblox Studio
```

## Workflow

Open `place/Stawberry.rbxl` in Studio, start the sync server, then hit
**Connect** in the Rojo panel:

```sh
rojo serve
```

Edits to files under `src/` now flow into Studio live. Geometry you build in
Studio is saved with Ctrl+S straight into the place file.

**Save in Studio before you commit.** The `pre-commit` hook stages the place
file for you and warns if it looks stale, but it cannot save Studio for you.
Local saves stay local — use **File > Publish to Roblox** to update the live
place.

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

Rojo syncs the scripts only. The Workspace geometry lives in
`place/Stawberry.rbxl`, so `rojo build` produces a **scripts-only** place with
no map:

```sh
rojo build -o build/Stawberry.rbxlx
```

That output is useful for checking the script tree, not for playing the game.
Open the committed place file for that.
