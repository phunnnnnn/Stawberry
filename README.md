# Stawberry

A Roblox project synced with [Rojo](https://rojo.space).

## Setup

```sh
aftman install     # installs the pinned rojo version
rojo plugin install  # installs the Rojo plugin into Roblox Studio
```

## Workflow

Start the sync server, then hit **Connect** in the Rojo panel inside Studio:

```sh
rojo serve
```

Edits to files under `src/` now flow into Studio live.

## Layout

| Path          | Syncs to                                          |
| ------------- | ------------------------------------------------- |
| `src/shared`  | `ReplicatedStorage.Shared`                        |
| `src/server`  | `ServerScriptService.Server`                      |
| `src/client`  | `StarterPlayer.StarterPlayerScripts.Client`       |

## Building a place file

```sh
rojo build -o build/Stawberry.rbxlx
```
