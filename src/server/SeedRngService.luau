--!strict

--[[
	Decides what the belt sends past next, and for whom.

	This is the seed half of the pair the factory generator started. The two run
	on exactly the same mechanic — a pool table with a row per level, four boxes
	per row, and weights for straying one row off your own — through the same
	`PoolRoll`; all that differs is what a box holds. A generator box holds a
	machine, a belt box holds a **rarity band**, and `Rarity.rollIn` turns that
	into one of the band's species. So the pool decides how scarce, the catalogue
	decides which, and neither answers the other's question.

	**Every player has their own belt roll**, for the same reason every player has
	their own generator offer: an upgrade whose reward a neighbour standing at the
	belt could take first would make the belt a footrace rather than a roll.
	Spawns go round the players in turn, and each seed is tagged with the id of
	the player it was rolled for — `ConveyorService` is what enforces that at the
	prompt, since it owns the seed.

	The rotation is what keeps that fair. One seed every `Conveyor.SpawnInterval`
	shared five ways is five times the wait for any one player, so the belt is
	slower in a full server than a solo one — but every seed on it that is yours
	was rolled at *your* level, which is the thing being bought.

	The level itself is stored here and published to the player as an attribute,
	so the shop UI can read it without a round trip. `UpgradeService` is what
	charges for a change; nothing here knows a price.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PoolRoll = require(ReplicatedStorage.Shared.PoolRoll)
local Rarity = require(ReplicatedStorage.Shared.Rarity)

local SeedRngService = {}

-- One seed's worth of decision: who it is for, and what it is.
export type Deal = {
	player: Player,
	species: string,
	band: number,
}

local levels: { [Player]: number } = {}

-- Players in join order, plus how far round the rotation we are. Kept beside
-- `levels` rather than read from `Players:GetPlayers()` each time, because that
-- list reorders on a leave and the cursor would jump with it.
local rotation: { Player } = {}
local cursor = 0

local started = false

local maxLevel = #Config.SeedRng.Pool

local function log(message: string, ...: any)
	if Config.SeedRng.LogRolls then
		print(("[SeedRngService] " .. message):format(...))
	end
end

-- The level is the player's, so it is published on the player. An attribute
-- rather than a leaderstat: it is not a score, and the shop is the only thing
-- that reads it.
local function publish(player: Player)
	player:SetAttribute(Config.SeedRng.LevelAttribute, levels[player] or Config.SeedRng.StartingLevel)
end

--[[ The roll ]]

-- What the belt deals a player at their level: a band from the pool, then one of
-- that band's species.
local function rollFor(player: Player): (string?, number)
	local cfg = Config.SeedRng
	local level = SeedRngService.levelOf(player)

	local band, row, box, steppedDown =
		PoolRoll.roll(cfg.Pool, level, cfg.RowWeights, cfg.BoxRates, cfg.BelowBoxRates)

	if not band then
		warn(("[SeedRngService] pool row %d is missing or empty — nothing to deal."):format(row))
		return nil, 0
	end

	local speciesName = Rarity.rollIn(band)
	if not speciesName then
		-- A row pointing at a band no species was authored into. Worth saying out
		-- loud rather than quietly dealing a Strawberry, which would look like the
		-- pool working.
		warn(("[SeedRngService] pool row %d box %d names band %d, which has no species in it.")
			:format(row, box, band))
		return nil, band
	end

	log("%s (belt level %d) rolled row %d%s box %d -> %s %s",
		player.Name,
		level,
		row,
		if steppedDown then " (stepped down, flat box odds)" else "",
		box,
		Rarity.name(band),
		speciesName)

	return speciesName, band
end

--[[ Public ]]

-- Which row of the pool a player is dealt from.
function SeedRngService.levelOf(player: Player): number
	return levels[player] or Config.SeedRng.StartingLevel
end

function SeedRngService.maxLevel(): number
	return maxLevel
end

-- Upgrades (or resets) a belt. Clamped to the pool rather than trusted, the same
-- as the generator's. Seeds already riding keep the band they were rolled at:
-- re-rolling them would pop a seed a player may be walking toward, and the next
-- one is only a spawn interval away.
function SeedRngService.setLevel(player: Player, level: number): boolean
	if not levels[player] then
		return false
	end

	local clamped = math.clamp(math.floor(level), 1, maxLevel)
	if clamped == levels[player] then
		return false
	end

	levels[player] = clamped
	publish(player)
	return true
end

-- Whose seed is next, and what it is. Nil when there is nobody to deal to — an
-- empty server has no level to roll against, and a seed nobody owns could not be
-- bought anyway.
function SeedRngService.deal(): Deal?
	if #rotation == 0 then
		return nil
	end

	-- Round the players in turn, so the belt is shared evenly rather than by
	-- whoever the random draw favours.
	cursor = (cursor % #rotation) + 1
	local player = rotation[cursor]

	local speciesName, band = rollFor(player)
	if not speciesName then
		return nil
	end

	return { player = player, species = speciesName, band = band }
end

--[[ Reading the odds without rolling ]]

-- What fraction of a level's rolls land in each band, 0..1, including the rows
-- it strays onto. Worth computing rather than reading off the pool, because a
-- level deals from three rows at two different box weightings and the answer is
-- not written down anywhere.
function SeedRngService.spread(level: number): { [number]: number }
	local cfg = Config.SeedRng
	local bands: { [number]: number } = {}

	for row, rowChance in pairs(PoolRoll.rowOdds(level, maxLevel, cfg.RowWeights)) do
		local boxes = cfg.Pool[row]
		if boxes then
			-- A row below the roller's own level is one it stepped down to, which is
			-- the case that gets the flat box odds. Recovered from the row number
			-- rather than tracked, since there is only one way to be below.
			local rates = if row < level then cfg.BelowBoxRates else cfg.BoxRates
			for box, boxChance in ipairs(PoolRoll.boxOdds(rates, #boxes)) do
				local band = boxes[box]
				bands[band] = (bands[band] or 0) + rowChance * boxChance
			end
		end
	end

	return bands
end

local function addPlayer(player: Player)
	if levels[player] then
		return
	end

	levels[player] = Config.SeedRng.StartingLevel
	table.insert(rotation, player)
	publish(player)
end

local function removePlayer(player: Player)
	levels[player] = nil

	local index = table.find(rotation, player)
	if index then
		table.remove(rotation, index)
		-- Step the cursor back with the list, so removing a player ahead of it does
		-- not skip the one that took their place.
		if index <= cursor then
			cursor -= 1
		end
	end
end

function SeedRngService.start()
	if started then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		addPlayer(player)
	end
	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	started = true

	print(("[SeedRngService] Dealing the belt — %d level(s), starting at %d.")
		:format(maxLevel, Config.SeedRng.StartingLevel))

	-- What each level actually deals, spelled out. Six bands against three rows at
	-- two box weightings is not worth working out by hand, and it is the only way
	-- to see that a pool edit did what was intended — the same argument the
	-- generator prints its rows for.
	for level = 1, maxLevel do
		local bands = SeedRngService.spread(level)
		local parts: { string } = {}
		for band = 0, Rarity.MAX do
			local share = bands[band]
			if share and share > 0 then
				table.insert(parts, ("%s %d%%"):format(Rarity.name(band), math.round(share * 100)))
			end
		end
		print(("[SeedRngService] Level %d deals %s."):format(level, table.concat(parts, ", ")))
	end
end

return SeedRngService
