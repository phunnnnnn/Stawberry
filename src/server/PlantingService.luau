--!strict

--[[
	Turns a held seed into a plant on the farm, then grows fruit on it.

	The client only reports *where* it clicked. Every other decision — is that
	point on the farm, is the player close enough, do they actually hold a seed
	— is made here, so a tampered client cannot plant off-farm or for free.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local FarmSurface = require(ReplicatedStorage.Shared.FarmSurface)
local PlantModel = require(ReplicatedStorage.Shared.PlantModel)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local InventoryService = require(script.Parent.InventoryService)

type PlantRecord = {
	model: Model,
	owner: Player,
	species: string,
	groundPosition: Vector3,
	fruit: BasePart?,
	growing: boolean,
}

local PlantingService = {}

local farm: BasePart? = nil
local plantFolder: Folder? = nil

local records: { PlantRecord } = {}
local lastPlantAt: { [Player]: number } = {}
local plantCounts: { [Player]: number } = {}

local function equippedSeed(player: Player): Tool?
	local character = player.Character
	if not character then
		return nil
	end

	-- A Tool parented to the character is the one being held.
	local tool = character:FindFirstChildOfClass("Tool")
	if tool and tool.Name == Config.Seed.ToolName then
		return tool
	end
	return nil
end

-- Projects a clicked point onto the farm's top face, or nil if it missed. The
-- rule itself lives in FarmSurface so the client's indicator previews exactly
-- what this accepts.
local function farmSurfacePoint(position: Vector3): Vector3?
	local pad = farm
	if not pad then
		return nil
	end
	return FarmSurface.project(pad, position)
end

local function occupiedPositions(): { Vector3 }
	local positions: { Vector3 } = table.create(#records)
	for _, record in ipairs(records) do
		table.insert(positions, record.groundPosition)
	end
	return positions
end

-- Planting and harvesting both refuse by simply returning, which makes a failed
-- click or prompt impossible to diagnose from inside the game. Naming the reason
-- costs nothing and puts it in Studio's Output. Declared here rather than beside
-- onPlantRequest because scheduleFruit's harvest handler needs it too.
-- Config.Farm.LogPlantRequests silences it.
local function refuse(player: Player, reason: string, ...: any)
	if not Config.Farm.LogPlantRequests then
		return
	end
	warn(("[PlantingService] %s: %s"):format(player.Name, reason:format(...)))
end

local function scheduleFruit(record: PlantRecord)
	local spec = Config.Plants[record.species]
	local fruitSpec = spec and spec.Fruit
	if not fruitSpec then
		-- Species bears no fruit; the plant is decorative.
		return
	end

	if record.growing or record.fruit then
		return
	end
	record.growing = true

	task.delay(fruitSpec.GrowTime, function()
		record.growing = false

		-- The plant may have been removed while the timer ran.
		if record.model.Parent == nil or record.fruit then
			return
		end

		local fruit = PlantModel.createFruit(fruitSpec)
		fruit.Position = PlantModel.fruitPosition(record.species, record.groundPosition)
		fruit.Parent = record.model
		record.fruit = fruit

		local prompt = fruit:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Triggered:Connect(function(player: Player)
				-- Guard against the prompt firing twice before teardown.
				if record.fruit ~= fruit then
					return
				end

				-- Award *before* destroying anything. Produce no longer stacks, so
				-- every fruit needs its own Backpack slot and this can legitimately
				-- fail; picking the fruit first would destroy it for nothing.
				if InventoryService.addItem(player, fruitSpec.Name, 1) < 1 then
					refuse(player, "backpack is full — the %s stays on the plant", fruitSpec.Name)
					return
				end

				record.fruit = nil
				fruit:Destroy()

				if Config.Farm.LogPlantRequests then
					print(("[PlantingService] %s harvested %s"):format(player.Name, fruitSpec.Name))
				end

				if fruitSpec.Regrow then
					scheduleFruit(record)
				end
			end)
		end
	end)
end

local function onPlantRequest(player: Player, requested: unknown)
	if typeof(requested) ~= "Vector3" then
		refuse(player, "payload was %s, not a Vector3", typeof(requested))
		return
	end
	local position = requested :: Vector3

	local now = os.clock()
	if now - (lastPlantAt[player] or 0) < Config.Farm.PlantCooldown then
		refuse(player, "still on cooldown (%.2fs)", Config.Farm.PlantCooldown)
		return
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if not root then
		refuse(player, "no character or no PrimaryPart")
		return
	end

	local tool = equippedSeed(player)
	if not tool then
		refuse(player, "no %q Tool equipped — it must be held, not just carried", Config.Seed.ToolName)
		return
	end

	if (plantCounts[player] or 0) >= Config.Farm.MaxPlantsPerPlayer then
		refuse(player, "at the %d plant limit", Config.Farm.MaxPlantsPerPlayer)
		return
	end

	local ground = farmSurfacePoint(position)
	if not ground then
		refuse(player, "%s is not on the farm's top face (or is inside the %d stud edge margin)",
			tostring(position), Config.Farm.EdgeMargin)
		return
	end

	if (root.Position - ground).Magnitude > Config.Farm.MaxPlantDistance then
		refuse(player, "%.1f studs away, limit is %d",
			(root.Position - ground).Magnitude, Config.Farm.MaxPlantDistance)
		return
	end

	if FarmSurface.tooClose(ground, occupiedPositions()) then
		refuse(player, "within %d studs of an existing plant", Config.Farm.MinPlantSpacing)
		return
	end

	local species = Config.DefaultSpecies
	local model = PlantModel.create(species)
	if not model then
		warn(("[PlantingService] Unknown species %q"):format(species))
		return
	end

	lastPlantAt[player] = now
	plantCounts[player] = (plantCounts[player] or 0) + 1

	-- Consume the seed only once every check has passed.
	tool:Destroy()

	PlantModel.place(model, ground)
	model.Parent = plantFolder

	local record: PlantRecord = {
		model = model,
		owner = player,
		species = species,
		groundPosition = ground,
		fruit = nil,
		growing = false,
	}
	table.insert(records, record)

	if Config.Farm.LogPlantRequests then
		-- Reports the parent too: assigning a nil parent is legal and would leave
		-- the plant out of the world, invisible, with nothing raised.
		print(("[PlantingService] %s planted %s at %s under %s (%d total)"):format(
			player.Name,
			species,
			tostring(ground),
			if model.Parent then model.Parent:GetFullName() else "NOTHING — the model is not in the world",
			plantCounts[player] or 0
		))
	end

	scheduleFruit(record)
end

function PlantingService.start()
	local pad = workspace:FindFirstChild(Config.Farm.PartName)
	if not (pad and pad:IsA("BasePart")) then
		warn(("[PlantingService] Workspace.%s is not a BasePart — planting disabled.")
			:format(Config.Farm.PartName))
		return
	end
	farm = pad :: BasePart

	local existing = workspace:FindFirstChild(Config.Farm.PlantFolderName)
	if existing then
		plantFolder = existing :: Folder
	else
		local folder = Instance.new("Folder")
		folder.Name = Config.Farm.PlantFolderName
		folder.Parent = workspace
		plantFolder = folder
	end

	Remotes.event(Remotes.PLANT_SEED).OnServerEvent:Connect(onPlantRequest)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastPlantAt[player] = nil
		plantCounts[player] = nil
	end)

	print(("[PlantingService] Ready on Workspace.%s — planting %s.")
		:format(Config.Farm.PartName, Config.DefaultSpecies))
end

return PlantingService
