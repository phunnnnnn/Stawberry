--!strict

--[[
	Turns a held seed into a plant on the farm, grows the plant, then grows fruit
	on it.

	A seed lands as a sprout and scales up over `Growth.Time`. Reaching the scale
	limit swaps it for the species' true form, and only then does the fruit timer
	start — so nothing is harvestable the moment it is planted.

	The client only reports *where* it clicked. Every other decision — is that
	point on the farm, is the player close enough, do they actually hold a seed
	— is made here, so a tampered client cannot plant off-farm or for free.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
	-- A fruit timer is running.
	growing: boolean,
	-- The plant itself has reached its true form. Nothing fruits before this.
	mature: boolean,
	-- Seconds since planting. Only meaningful while immature.
	age: number,
}

local PlantingService = {}

local farm: BasePart? = nil
local plantFolder: Folder? = nil

local records: { PlantRecord } = {}
-- Plants still scaling up, stepped every frame. A subset of `records` rather
-- than a scan of it, so a farm full of grown plants costs nothing per frame.
local sprouting: { PlantRecord } = {}
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

-- Forward declaration. takeFruit restarts the fruit timer through scheduleFruit,
-- and scheduleFruit's harvest prompt hands its fruit over through takeFruit.
local takeFruit: (record: PlantRecord, fruit: BasePart) -> boolean

local function scheduleFruit(record: PlantRecord)
	local spec = Config.Plants[record.species]
	local fruitSpec = spec and spec.Fruit
	if not fruitSpec then
		-- Species bears no fruit; the plant is decorative.
		return
	end

	-- A sprout bears nothing. Both callers already know the plant is grown, so
	-- this is an invariant rather than a gate anyone is expected to hit.
	if not record.mature then
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

				takeFruit(record, fruit)

				if Config.Farm.LogPlantRequests then
					print(("[PlantingService] %s harvested %s"):format(player.Name, fruitSpec.Name))
				end
			end)
		end
	end)
end

-- The one place a ripe fruit leaves its plant. The harvest prompt and a worker
-- both come through here, so neither can take the same fruit twice and regrowth
-- can only ever be scheduled one way.
--
-- It deliberately pays nobody. The caller has already decided where the fruit is
-- going, which is what lets a worker carry one off in its hands without it ever
-- entering an inventory.
function takeFruit(record: PlantRecord, fruit: BasePart): boolean
	if record.fruit ~= fruit then
		return false
	end

	record.fruit = nil
	fruit:Destroy()

	local spec = Config.Plants[record.species]
	local fruitSpec = spec and spec.Fruit
	if fruitSpec and fruitSpec.Regrow then
		scheduleFruit(record)
	end
	return true
end

-- Advances every sprout by one frame's worth of growth and transforms the ones
-- that reach the limit.
--
-- One loop over all of them rather than a timer each: the scale has to move
-- continuously anyway, and a per-plant task would still have to notice a plant
-- that left the world mid-grow.
local function stepGrowth(deltaTime: number)
	for index = #sprouting, 1, -1 do
		local record = sprouting[index]
		local spec = Config.Plants[record.species]
		local growth = spec and spec.Growth

		-- Removed from the world while growing, or an unknown species: stop
		-- stepping it either way.
		if not growth or record.model.Parent == nil then
			table.remove(sprouting, index)
			continue
		end

		record.age += deltaTime

		local alpha = if growth.Time > 0 then math.clamp(record.age / growth.Time, 0, 1) else 1
		if alpha < 1 then
			local scale = growth.StartScale + (growth.MatureScale - growth.StartScale) * alpha
			PlantModel.setScale(record.model, scale)
			continue
		end

		-- At the limit: swap the sprout for the true form, and only now start
		-- the fruit timer.
		table.remove(sprouting, index)
		record.mature = true
		PlantModel.mature(record.model)

		if Config.Farm.LogPlantRequests then
			print(("[PlantingService] %s's %s reached its true form after %.1fs")
				:format(record.owner.Name, record.species, record.age))
		end

		scheduleFruit(record)
	end
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
		mature = false,
		age = 0,
	}
	table.insert(records, record)
	table.insert(sprouting, record)

	if Config.Farm.LogPlantRequests then
		-- Reports the parent too: assigning a nil parent is legal and would leave
		-- the plant out of the world, invisible, with nothing raised.
		print(("[PlantingService] %s planted %s at %s under %s (%d total, grows for %.1fs)"):format(
			player.Name,
			species,
			tostring(ground),
			if model.Parent then model.Parent:GetFullName() else "NOTHING — the model is not in the world",
			plantCounts[player] or 0,
			Config.Plants[species].Growth.Time
		))
	end
end

--[[ Worker-facing view of the farm

	A worker is a second actor on the same plants, so it gets a *query* — is there
	anything here for me — and a *commit* that goes through exactly the transition
	the player's prompt uses. It never reaches into `records` itself.
]]

export type RipeFruit = {
	part: BasePart,
	itemName: string,
	-- Where the fruit hangs, which is what to look at.
	position: Vector3,
	-- Where the plant is rooted, which is what to walk to. A fruit sits most of a
	-- stem's height in the air, so the two are not interchangeable.
	ground: Vector3,
}

-- Ripe fruit on one of `owner`'s own plants, nearest to `from`.
--
-- Anything in `skip` is passed over, which is how two workers avoid walking to
-- opposite ends of the farm for the same strawberry. Unlike the harvest prompt
-- this is restricted to the owner's plants: a worker helping its employer rob the
-- neighbours would be a surprise, whatever the prompt currently allows.
function PlantingService.nearestRipeFruit(owner: Player, from: Vector3, skip: { [Instance]: boolean }?): RipeFruit?
	local best: RipeFruit? = nil
	local bestDistance = math.huge

	for _, record in ipairs(records) do
		local fruit = record.fruit
		local spec = Config.Plants[record.species]
		local fruitSpec = spec and spec.Fruit

		if record.owner == owner and fruit and fruit.Parent ~= nil and fruitSpec
			and not (skip and skip[fruit])
		then
			local distance = (fruit.Position - from).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = {
					part = fruit,
					itemName = fruitSpec.Name,
					position = fruit.Position,
					ground = record.groundPosition,
				}
			end
		end
	end

	return best
end

-- Takes a ripe fruit off its plant for a caller that will carry it away itself.
--
-- False when it has already gone: a player can harvest the same fruit, or the
-- plant can be removed, during the seconds a worker spends walking over. That is
-- expected, not an error — the worker simply picks something else.
function PlantingService.pluck(target: RipeFruit): boolean
	for _, record in ipairs(records) do
		if record.fruit == target.part then
			return takeFruit(record, target.part)
		end
	end
	return false
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
	RunService.Heartbeat:Connect(stepGrowth)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastPlantAt[player] = nil
		plantCounts[player] = nil
	end)

	print(("[PlantingService] Ready on Workspace.%s — planting %s.")
		:format(Config.Farm.PartName, Config.DefaultSpecies))
end

return PlantingService
