--!strict

--[[
	Spawns seeds at one end of Workspace.Conveyor, slides them down the middle
	of it to the other end, and sells them to players through a proximity
	prompt.

	The belt is the shop. Each seed is rolled from Config.SpeciesOrder, so all
	eighteen species come past in one queue, and each carries its own price —
	so what arrives next is luck and what you take is a decision. A seed nobody
	can afford simply rides off the end.

	One lane, down the centreline: the stream is a single file rather than a
	scatter, so the seed under the prompt is unambiguous and the one behind it
	is readable while you decide.

	Seed positions are computed in the belt's *local* space, so the whole rig
	can be moved or rotated in Studio and the flow follows it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Seed = require(ReplicatedStorage.Shared.Seed)

local InventoryService = require(script.Parent.InventoryService)

type SeedRecord = {
	part: BasePart,
	species: string,
	offset: number, -- position along the belt's local Z axis
	claimed: boolean,
}

local ConveyorService = {}

local belt: BasePart? = nil
local seedFolder: Folder? = nil

-- Belt-local geometry, resolved once in `start`.
local entryOffset = 0
local exitOffset = 0
local surfaceOffset = 0

local seeds: { SeedRecord } = {}
local spawnClock = 0
local started = false

local function cframeFor(record: SeedRecord): CFrame
	local activeBelt = belt
	if not activeBelt then
		return CFrame.new()
	end

	-- Dead centre of the belt: the lateral term is zero rather than absent, so
	-- the one place a seed's position is computed still shows all three axes.
	return activeBelt.CFrame
		* CFrame.new(0, surfaceOffset, record.offset)
		* CFrame.Angles(record.offset * Config.Conveyor.SpinRate, 0, 0)
end

local function collect(player: Player, record: SeedRecord)
	-- Guard against the prompt firing twice before the record is reaped.
	if record.claimed then
		return
	end

	-- Refused — too poor, or no room. Leave the seed riding rather than
	-- destroying it: it is still for sale to whoever can afford it, and nothing
	-- the player paid for has gone anywhere.
	local bought, reason = InventoryService.buySeed(player, record.species)
	if not bought then
		if Config.Conveyor.LogPurchases then
			-- Named by the part, not by the species, so a log line greps against
			-- what is actually in Workspace — and no article has to agree with
			-- eighteen species.
			warn(("[ConveyorService] %s could not buy %s: %s")
				:format(player.Name, record.part.Name, reason or "unknown"))
		end
		return
	end

	local label = record.part.Name
	record.claimed = true
	record.part:Destroy()

	if Config.Conveyor.LogPurchases then
		print(("[ConveyorService] %s bought %s for %d coins")
			:format(player.Name, label, Seed.price(record.species)))
	end
end

-- What comes past next. Uniform across the catalogue: the belt is chance, and
-- price is the only thing gating a species.
local function rollSpecies(): string
	local order = Config.SpeciesOrder
	if #order == 0 then
		return Config.DefaultSpecies
	end
	return order[math.random(#order)]
end

local function spawnSeed()
	local species = rollSpecies()
	local part = Seed.createPickup(species)

	local record: SeedRecord = {
		part = part,
		species = species,
		offset = entryOffset,
		claimed = false,
	}

	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Triggered:Connect(function(player: Player)
			collect(player, record)
		end)
	end

	part.CFrame = cframeFor(record)
	part.Parent = seedFolder
	table.insert(seeds, record)
end

local function reachedEnd(offset: number): boolean
	if Config.Conveyor.Direction > 0 then
		return offset >= exitOffset
	end
	return offset <= exitOffset
end

local function step(deltaTime: number)
	local cfg = Config.Conveyor
	local travel = cfg.Direction * cfg.Speed * deltaTime

	for index = #seeds, 1, -1 do
		local record = seeds[index]

		if record.claimed or record.part.Parent == nil then
			record.part:Destroy()
			table.remove(seeds, index)
			continue
		end

		record.offset += travel

		if reachedEnd(record.offset) then
			record.part:Destroy()
			table.remove(seeds, index)
			continue
		end

		record.part.CFrame = cframeFor(record)
	end

	spawnClock += deltaTime
	if spawnClock >= cfg.SpawnInterval then
		-- Subtract rather than zero so the spawn rate stays honest under lag.
		spawnClock -= cfg.SpawnInterval
		if #seeds < cfg.MaxActiveSeeds then
			spawnSeed()
		end
	end
end

function ConveyorService.start()
	if started then
		return
	end

	local model = workspace:FindFirstChild("Conveyor")
	if not model then
		warn("[ConveyorService] Workspace.Conveyor not found — conveyor disabled.")
		return
	end

	local found = model:FindFirstChild(Config.Conveyor.BeltName)
	if not (found and found:IsA("BasePart")) then
		warn(
			("[ConveyorService] Workspace.Conveyor.%s is not a BasePart — conveyor disabled.")
				:format(Config.Conveyor.BeltName)
		)
		return
	end

	local activeBelt = found :: BasePart
	if not activeBelt.Anchored then
		warn("[ConveyorService] Belt is unanchored; it will drift and take the seed stream with it.")
	end

	belt = activeBelt

	local halfLength = activeBelt.Size.Z / 2
	local direction = Config.Conveyor.Direction

	-- Enter at the trailing edge, leave at the leading edge.
	entryOffset = -direction * (halfLength - Config.Conveyor.EntryMargin)
	exitOffset = direction * halfLength
	surfaceOffset = activeBelt.Size.Y / 2 + Config.Seed.Size.Y / 2 + Config.Conveyor.HoverOffset

	local folder = workspace:FindFirstChild(Config.Conveyor.SeedFolderName)
	if not folder then
		local created = Instance.new("Folder")
		created.Name = Config.Conveyor.SeedFolderName
		created.Parent = workspace
		folder = created
	end
	seedFolder = folder :: Folder

	RunService.Heartbeat:Connect(step)
	started = true

	print(
		("[ConveyorService] Running on %s — %.1f studs/s, one seed every %.1fs, %d species for sale.")
			:format(
				activeBelt:GetFullName(),
				Config.Conveyor.Speed,
				Config.Conveyor.SpawnInterval,
				#Config.SpeciesOrder
			)
	)
end

return ConveyorService
