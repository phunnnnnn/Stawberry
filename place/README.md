# place/

`Stawberry.rbxl` lives here — the Studio place file holding all Workspace
geometry (Farm, Fatory, Worker, Seller, Conveyor, Baseplate).

Rojo syncs **only** the scripts under `src/`. The map is not reproducible from
the repo without this file, which is why it is committed despite being binary.

## Working on it

Open `place/Stawberry.rbxl` in Studio, run `rojo serve`, and hit **Connect**.
Save with Ctrl+S as normal — it writes straight back to this file.

**Save in Studio before committing.** The `pre-commit` hook stages this file
automatically and warns when it looks older than your `src/` changes, but it
cannot make Studio flush unsaved geometry to disk.

## Publishing

Local saves do not reach Roblox. Use **File > Publish to Roblox** when you want
the live place updated.
