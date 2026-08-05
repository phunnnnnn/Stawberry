--!strict

--[[
	Spawns placeholder seeds at one end of Workspace.Conveyor, slides them to
	the other end, and lets players collect them with a proximity prompt.

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
	offset: number, -- position along the belt's local Z axis
	lane: number, -- sideways offset from the belt centreline
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

	return activeBelt.CFrame
		* CFrame.new(record.lane, surfaceOffset, record.offset)
		* CFrame.Angles(record.offset * Config.Conveyor.SpinRate, 0, 0)
end

local function collect(player: Player, record: SeedRecord)
	-- Guard against the prompt firing twice before the record is reaped.
	if record.claimed then
		return
	end

	-- Backpack at capacity: leave the seed riding rather than destroying it,
	-- so nothing is silently lost.
	if not InventoryService.grantSeed(player) then
		return
	end

	record.claimed = true
	record.part:Destroy()
end

local function spawnSeed()
	local part = Seed.createPickup()

	local record: SeedRecord = {
		part = part,
		offset = entryOffset,
		lane = (math.random() * 2 - 1) * Config.Conveyor.LaneJitter,
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
		("[ConveyorService] Running on %s — %.1f studs/s, one seed every %.1fs.")
			:format(activeBelt:GetFullName(), Config.Conveyor.Speed, Config.Conveyor.SpawnInterval)
	)
end

return ConveyorService
