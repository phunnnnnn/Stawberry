--!strict

--[[
	Deals factory machines out of a pool table, one player at a time.

	This is where factories come from. The belt is the seed shop and charges
	coins; this is the factory shop and charges patience — an offer stands on the
	pad for `SpawnInterval` seconds and is then thrown away and re-rolled whether
	or not anybody took it. Taking one is free.

	**Every player has their own generator.** Own slot along the pad, own timer,
	own RNG level, own offer that only they can take. The map is being designed
	one farm per player, and a single shared offer would make the whole feature a
	race rather than a roll. The slots are measured along the pad's own X axis
	from its own CFrame, so moving or rotating it in Studio carries them along —
	the same rule the conveyor and the worker posts follow.

	A roll is two draws, and the second depends on the first:

	  1. **Which row.** Mostly the generator's own level (70), sometimes the row
	     below it (29), very rarely the row above (1). At the bottom there is no
	     row below and at the top no row above; the missing weight folds back into
	     the current row rather than being re-rolled, so the odds stay honest at
	     the ends instead of quietly looping.

	  2. **Which box of that row.** Normally 50/30/15/5, so box 4 — the best entry
	     in every row — is the rare one. **Except on a row that stepped down**,
	     where all four are 25. Being dealt a worse row comes with a five-fold
	     better chance at that row's best box, which is what stops the 29% case
	     from reading as a plain loss.

	Both the pool and every weight live in `Config.FactoryRng`; nothing here knows
	a number of its own. `FactoryService.grantFactory` is the commit, so a machine
	won here is the same machine `Config.Factory.StartingFactories` would have
	handed out and nothing downstream can tell them apart.

	The generator's own level is stored per player and read on every roll. There
	is no way to buy an upgrade yet — `setLevel` is the whole of what one would
	need to call.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local FactoryModel = require(ReplicatedStorage.Shared.FactoryModel)
local Produce = require(ReplicatedStorage.Shared.Produce)

local FactoryService = require(script.Parent.FactoryService)

type Generator = {
	player: Player,
	-- Which post along the pad this player's offer stands on. Fixed for as long
	-- as they are in the server, and released when they leave — unlike a worker's
	-- post, a slot here is a real fixed resource and there is only pad enough for
	-- so many.
	slot: number,
	-- Which row of the pool table this player is dealt from.
	level: number,
	clock: number,
	model: Model?,
	offer: Config.FactoryOffer?,
	prompt: ProximityPrompt?,
}

local FactoryRngService = {}

local pad: BasePart? = nil
local offerFolder: Folder? = nil

local generators: { [Player]: Generator } = {}
local usedSlots: { [number]: boolean } = {}
local slotCapacity = 0
local started = false

local maxRngLevel = #Config.FactoryRng.Pool

local function log(message: string, ...: any)
	if Config.FactoryRng.LogRolls then
		print(("[FactoryRngService] " .. message):format(...))
	end
end

--[[ Slots ]]

-- Lowest free post, so players who join after someone left fill the gap rather
-- than marching off the end of the pad.
local function claimSlot(): number
	local index = 1
	while usedSlots[index] do
		index += 1
	end
	usedSlots[index] = true
	return index
end

-- Where a slot's offer stands, in the pad's own space. Carries the pad's
-- rotation, so a machine lines up with the pad the way a placed one lines up
-- with the factory zone.
local function slotGround(surface: BasePart, slot: number): CFrame
	local cfg = Config.FactoryRng
	local first = -surface.Size.X / 2 + cfg.SlotSpacing / 2
	return surface.CFrame
		* CFrame.new(first + (slot - 1) * cfg.SlotSpacing, surface.Size.Y / 2 + cfg.HoverOffset, 0)
end

--[[ The roll ]]

-- Which row a roll actually deals from, and whether it stepped down to get
-- there. Stepping down is the one thing the caller needs back, because it
-- changes the box weights.
local function rollRow(level: number): (number, boolean)
	local weights = Config.FactoryRng.RowWeights

	-- Whichever neighbour does not exist contributes nothing and its weight goes
	-- to the current row. Re-rolling instead would be the same outcome with a
	-- loop in it; clamping would silently make the end rows likelier than the
	-- table says without anything recording that it happened.
	local below = if level > 1 then weights.Below else 0
	local above = if level < maxRngLevel then weights.Above else 0
	local current = weights.Current + (weights.Below - below) + (weights.Above - above)

	local pick = math.random() * (current + below + above)

	if pick < below then
		return level - 1, true
	end
	pick -= below

	if pick < above then
		return level + 1, false
	end

	return level, false
end

-- Which box of a row, against a weight list. Falls back to the last box if the
-- weights and the row disagree about how many there are, rather than indexing
-- past the end of the table.
local function rollBox(rates: { number }, boxes: number): number
	local total = 0
	for index = 1, math.min(#rates, boxes) do
		total += rates[index]
	end

	local pick = math.random() * total
	for index = 1, math.min(#rates, boxes) do
		if pick < rates[index] then
			return index
		end
		pick -= rates[index]
	end

	return boxes
end

-- One complete draw for a generator at `level`: the machine, and the row and box
-- it came out of so the log can say where.
local function roll(level: number): (Config.FactoryOffer?, number, number, boolean)
	local cfg = Config.FactoryRng

	local row, steppedDown = rollRow(level)
	local boxes = cfg.Pool[row]
	if not boxes or #boxes == 0 then
		warn(("[FactoryRngService] pool row %d is missing or empty — nothing to deal."):format(row))
		return nil, row, 0, steppedDown
	end

	local rates = if steppedDown then cfg.BelowBoxRates else cfg.BoxRates
	local box = rollBox(rates, #boxes)

	return boxes[box], row, box, steppedDown
end

--[[ Offers ]]

local function clearOffer(generator: Generator)
	local model = generator.model
	if model then
		model:Destroy()
	end
	generator.model = nil
	generator.offer = nil
	generator.prompt = nil
end

-- Hands the standing offer to whoever pressed the prompt, if it is theirs.
--
-- A refusal leaves the machine standing, exactly as a seed nobody can afford
-- keeps riding the belt: it is still the player's to take once they have placed
-- something, and it will be re-rolled on schedule anyway.
local function take(generator: Generator, player: Player)
	if player ~= generator.player then
		-- Prompts are visible to everyone — the placed machines have the same gap —
		-- so this is the check that makes them one player's offer rather than a
		-- race.
		log("%s tried to take %s's offer", player.Name, generator.player.Name)
		return
	end

	local offer = generator.offer
	if not offer then
		return
	end

	if not FactoryService.grantFactory(player, offer.Tier, offer.Level) then
		log("%s could not take the tier %d level %d factory — carrying %d of %d",
			player.Name, offer.Tier, offer.Level,
			FactoryService.carriedCount(player), Config.Factory.MaxCarried)
		return
	end

	log("%s took a tier %d level %d factory (×%s output)",
		player.Name, offer.Tier, offer.Level,
		("%g"):format(Produce.levelMultiplier(offer.Level)))

	clearOffer(generator)

	-- Restart the timer rather than leaving it running. Otherwise taking an offer
	-- one second before it expired would hand over a second machine a second
	-- later, and the fastest way to farm the pad would be to stand on it and grab
	-- everything the moment it lands.
	generator.clock = 0
end

local function spawnOffer(generator: Generator)
	local surface = pad
	if not surface then
		return
	end

	clearOffer(generator)

	local offer, row, box, steppedDown = roll(generator.level)
	if not offer then
		return
	end

	local model, prompt = FactoryModel.createOffer(offer.Tier, offer.Level)
	FactoryModel.place(model, slotGround(surface, generator.slot))
	model:SetAttribute("OwnerUserId", generator.player.UserId)
	model.Parent = offerFolder

	prompt.Triggered:Connect(function(player: Player)
		take(generator, player)
	end)

	generator.model = model
	generator.offer = offer
	generator.prompt = prompt

	log("%s (RNG level %d) rolled row %d%s box %d -> tier %d level %d",
		generator.player.Name,
		generator.level,
		row,
		if steppedDown then " (stepped down, flat box odds)" else "",
		box,
		offer.Tier,
		offer.Level)
end

local function step(deltaTime: number)
	for _, generator in pairs(generators) do
		generator.clock += deltaTime
		if generator.clock >= Config.FactoryRng.SpawnInterval then
			-- Subtracted rather than zeroed so the cadence stays honest under lag,
			-- the same as the conveyor's spawn clock.
			generator.clock -= Config.FactoryRng.SpawnInterval
			spawnOffer(generator)
		end
	end
end

--[[ Public ]]

-- Which row of the pool table a player is dealt from.
function FactoryRngService.levelOf(player: Player): number
	local generator = generators[player]
	return if generator then generator.level else Config.FactoryRng.StartingLevel
end

-- Upgrades (or resets) a generator. Clamped to the pool rather than trusted, and
-- the standing offer is re-rolled immediately so the change is visible without
-- waiting out the timer.
--
-- Nothing calls this yet: buying an upgrade is the missing half of the feature,
-- and this is the whole of what it would need.
function FactoryRngService.setLevel(player: Player, level: number): boolean
	local generator = generators[player]
	if not generator then
		return false
	end

	local clamped = math.clamp(math.floor(level), 1, maxRngLevel)
	if clamped == generator.level then
		return false
	end

	generator.level = clamped
	generator.clock = 0
	spawnOffer(generator)
	return true
end

function FactoryRngService.maxLevel(): number
	return maxRngLevel
end

local function addPlayer(player: Player)
	if generators[player] then
		return
	end

	local slot = claimSlot()
	if slotCapacity > 0 and slot > slotCapacity then
		warn(("[FactoryRngService] Workspace.%s has room for %d slot(s) at %d studs apart, and %s is number %d — their offer will stand off the end of the pad.")
			:format(Config.FactoryRng.ZoneName, slotCapacity, Config.FactoryRng.SlotSpacing, player.Name, slot))
	end

	local generator: Generator = {
		player = player,
		slot = slot,
		level = Config.FactoryRng.StartingLevel,
		clock = 0,
		model = nil,
		offer = nil,
		prompt = nil,
	}
	generators[player] = generator

	-- Dealt one straight away rather than after a full interval: a player who
	-- joins with nothing to place should not spend their first ten seconds
	-- looking at an empty pad.
	spawnOffer(generator)
end

local function removePlayer(player: Player)
	local generator = generators[player]
	if not generator then
		return
	end

	clearOffer(generator)
	usedSlots[generator.slot] = nil
	generators[player] = nil
end

function FactoryRngService.start()
	if started then
		return
	end

	local found = workspace:FindFirstChild(Config.FactoryRng.ZoneName)
	if not (found and found:IsA("BasePart")) then
		warn(("[FactoryRngService] Workspace.%s is not a BasePart — the factory generator is disabled, so there is no way to get a factory.")
			:format(Config.FactoryRng.ZoneName))
		return
	end

	local surface = found :: BasePart
	pad = surface
	slotCapacity = math.floor(surface.Size.X / Config.FactoryRng.SlotSpacing)

	local existing = workspace:FindFirstChild(Config.FactoryRng.FolderName)
	if existing then
		offerFolder = existing :: Folder
	else
		local folder = Instance.new("Folder")
		folder.Name = Config.FactoryRng.FolderName
		folder.Parent = workspace
		offerFolder = folder
	end

	for _, player in ipairs(Players:GetPlayers()) do
		addPlayer(player)
	end
	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	RunService.Heartbeat:Connect(step)
	started = true

	print(("[FactoryRngService] Dealing on %s — one offer per player every %.1fs, %d pool row(s), room for %d slot(s).")
		:format(
			surface:GetFullName(),
			Config.FactoryRng.SpawnInterval,
			maxRngLevel,
			slotCapacity
		))

	-- The pool, spelled out. Six weights against a five-row table is not worth
	-- working out by hand, and it is the only way to see that a Config edit did
	-- what was intended — the same argument as the belt's rarity spread.
	for row, boxes in ipairs(Config.FactoryRng.Pool) do
		local entries: { string } = {}
		for index, offer in ipairs(boxes) do
			table.insert(entries, ("%d%%->T%dL%d")
				:format(Config.FactoryRng.BoxRates[index] or 0, offer.Tier, offer.Level))
		end
		print(("[FactoryRngService] Level %d deals %s."):format(row, table.concat(entries, "  ")))
	end
end

return FactoryRngService
