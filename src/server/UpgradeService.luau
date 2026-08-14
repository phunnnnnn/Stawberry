--!strict

--[[
	Sells generator levels. The one way a player's belt or factory generator ever
	moves off the level it started at.

	Both shops deal out of a levelled pool, and neither knows what a level costs —
	that is deliberate, and it is what this service is. A track is a name, a list
	of costs, and the three functions the shop behind it already had: `levelOf`,
	`maxLevel`, `setLevel`. Adding a third shop means adding a fourth entry to
	TRACKS and nothing else here.

	**Coins leave a player in three places now**: `spendCoins` for a hire, for a
	belt seed, and here. All three go through `InventoryService.spendCoins`, which
	is all-or-nothing, so nothing can half-charge for a level. The order is the
	same one `buySeed` uses and for the same reason — check everything, take the
	coins, then commit, and refund if the commit somehow fails, since being
	charged for a level that was never applied is the one unrecoverable outcome.

	The client sends **only a track name**. What level that track is at, what the
	next one costs and whether the player can afford it are all re-read here; the
	shop UI showing a price proves nothing. It reads the same `Config` this does,
	so the number on the button is the number that is charged — but it is charged
	off the server's copy.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local FactoryRngService = require(script.Parent.FactoryRngService)
local InventoryService = require(script.Parent.InventoryService)
local SeedRngService = require(script.Parent.SeedRngService)

local UpgradeService = {}

type Track = {
	-- What the log and the refusal call it.
	Label: string,
	-- Coins to go from level N to N+1, indexed by N. One shorter than the pool.
	Costs: { number },
	levelOf: (Player) -> number,
	maxLevel: () -> number,
	setLevel: (Player, number) -> boolean,
}

export type Result = {
	ok: boolean,
	level: number,
	spent: number,
	reason: string?,
}

-- Keyed by the string the client sends. These names are a wire contract with
-- UpgradeShop; they are not display text, which each track's Label is.
local TRACKS: { [string]: Track } = {
	Seed = {
		Label = "seed belt",
		Costs = Config.SeedRng.UpgradeCosts,
		levelOf = SeedRngService.levelOf,
		maxLevel = SeedRngService.maxLevel,
		setLevel = SeedRngService.setLevel,
	},
	Factory = {
		Label = "factory generator",
		Costs = Config.FactoryRng.UpgradeCosts,
		levelOf = FactoryRngService.levelOf,
		maxLevel = FactoryRngService.maxLevel,
		setLevel = FactoryRngService.setLevel,
	},
}

local started = false

-- What the next level costs, or nil at the top of the track. Also nil when the
-- costs table is shorter than the pool, which is a Config fault — refusing to
-- sell a level nobody priced is better than selling it for nothing.
local function costFor(track: Track, level: number): number?
	if level >= track.maxLevel() then
		return nil
	end
	return track.Costs[level]
end

local function refuse(player: Player, level: number, reason: string): Result
	if Config.Upgrades.LogPurchases then
		warn(("[UpgradeService] %s: %s"):format(player.Name, reason))
	end
	return { ok = false, level = level, spent = 0, reason = reason }
end

-- Buys exactly one level of one track. One at a time rather than "up to level
-- N": every level is a separate decision at a separate price, and a single-step
-- purchase is the only shape that cannot half-succeed.
function UpgradeService.buy(player: Player, trackName: string): Result
	local track = TRACKS[trackName]
	if not track then
		-- Only reachable from a tampered client; the shop sends one of two strings.
		return refuse(player, 0, ("there is no %s upgrade"):format(trackName))
	end

	local level = track.levelOf(player)

	local cost = costFor(track, level)
	if not cost then
		return refuse(player, level, ("the %s is already at level %d, the highest there is")
			:format(track.Label, level))
	end

	if not InventoryService.spendCoins(player, cost) then
		return refuse(player, level, ("upgrading the %s costs %d coins")
			:format(track.Label, cost))
	end

	if not track.setLevel(player, level + 1) then
		-- Only reachable if the player left between the two calls, or the pool
		-- moved under us. Refund rather than pocket the coins for nothing.
		InventoryService.addCoins(player, cost)
		return refuse(player, level, ("the %s could not be upgraded"):format(track.Label))
	end

	if Config.Upgrades.LogPurchases then
		print(("[UpgradeService] %s upgraded their %s to level %d for %d coins")
			:format(player.Name, track.Label, level + 1, cost))
	end

	return { ok = true, level = level + 1, spent = cost }
end

-- The client's argument is `unknown` rather than a string, the same as the
-- seller's: it arrives off the wire, and typing it as what it is supposed to be
-- would be the client asserting its own input.
local function onUpgradeRequest(player: Player, trackName: unknown): Result
	if typeof(trackName) ~= "string" then
		return refuse(player, 0, ("no upgrade named %s"):format(tostring(trackName)))
	end
	return UpgradeService.buy(player, trackName :: string)
end

function UpgradeService.start()
	if started then
		return
	end

	Remotes.func(Remotes.BUY_UPGRADE).OnServerInvoke = onUpgradeRequest

	started = true

	-- Both ladders, spelled out, so a price edit is verifiable from Output the
	-- same way a pool edit is.
	for name, track in pairs(TRACKS) do
		local steps: { string } = {}
		for level = 1, track.maxLevel() - 1 do
			table.insert(steps, ("%d->%d: %s"):format(
				level,
				level + 1,
				if track.Costs[level] then tostring(track.Costs[level]) else "unpriced"))
		end
		print(("[UpgradeService] %s (%s) — %s."):format(name, track.Label, table.concat(steps, "  ")))
	end
end

return UpgradeService
