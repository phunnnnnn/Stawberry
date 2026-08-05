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
2. Equip the seed and **click the farm** to plant a strawberry. A disc follows your cursor: green means the click will land, red names what's wrong (too close to another plant, off the edge, too far away).
3. Fruit appears after 3 seconds. Press **E** to harvest it; the plant bears again and the fruit appears as an equippable stack Tool.
4. Equip that stack to inspect it — a card shows the unit price, how many you hold and what the lot is worth.
5. Take fruit to `Workspace.Seller` and press **E** to choose **Sell All**, **Sell Thing That I Hold**, or **Nevermind**. Coins are ranked on the leaderboard, top left.

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
