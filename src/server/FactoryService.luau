--!strict

--[[
	Places factory machines on the factory zone and runs them.

	Placement mirrors PlantingService: the client reports *where* it clicked and
	nothing else, and every other decision — is that cell on the zone, is it
	free, is the player close enough, do they have a factory left to place — is
	made here.

	A machine has one ProximityPrompt and three states, and the prompt's own text
	is the whole interface:

	  empty      "Insert Strawberry"   -> consumes one fruit, starts the timer
	  processing  prompt disabled      -> the fruit sits in the slot for
	                                      ProductSpec.ProcessTime seconds
	  ready      "Collect ..."         -> the product goes into the inventory

	A second prompt on its own key takes an empty machine back into stock, so a
	misplaced factory is not permanent.

	The unplaced stock is a count on a single Tool rather than one Tool per
	factory, which is the same shape as a produce stack: it survives a respawn
	replacing the Backpack, because it is rebuilt from a server-side number.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local FactoryGrid = require(ReplicatedStorage.Shared.FactoryGrid)
local FactoryModel = require(ReplicatedStorage.Shared.FactoryModel)
local Produce = require(ReplicatedStorage.Shared.Produce)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local InventoryService = require(script.Parent.InventoryService)

type FactoryRecord = {
	model: Model,
	owner: Player,
	cell: Vector3,
	prompt: ProximityPrompt,
	-- Exactly one of these is set at a time, or neither when the machine is
	-- empty: `input` while the timer runs, `output` once it has finished.
	input: string?,
	output: string?,
}

local FactoryService = {}

local zone: BasePart? = nil
local factoryFolder: Folder? = nil

local records: { FactoryRecord } = {}
local lastPlaceAt: { [Player]: number } = {}

-- Unplaced factories. Authoritative; the Tool only mirrors it.
local stock: { [Player]: number } = {}

local STOCK_ATTRIBUTE = "FactoryCount"

-- Placement, inserting and collecting all refuse by simply returning, which
-- makes a failed click or prompt impossible to diagnose from inside the game.
-- Config.Factory.LogRequests silences this.
local function refuse(player: Player, reason: string, ...: any)
	if not Config.Factory.LogRequests then
		return
	end
	warn(("[FactoryService] %s: %s"):format(player.Name, reason:format(...)))
end

local function log(message: string, ...: any)
	if Config.Factory.LogRequests then
		print(("[FactoryService] " .. message):format(...))
	end
end

--[[ Unplaced stock ]]

local function containers(player: Player): { Instance }
	local found: { Instance } = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(found, backpack)
	end
	if player.Character then
		table.insert(found, player.Character)
	end
	return found
end

local function createFactoryTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = Config.Factory.ToolName
	tool.ToolTip = "Click the factory zone to place"
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	-- Must be named "Handle" for RequiresHandle to find it.
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1.6, 1.6, 1.6)
	handle.Color = Config.Factory.BodyColor
	handle.Material = Enum.Material.WoodPlanks
	handle.Massless = true
	handle.CanCollide = false
	handle.CanTouch = false
	handle.Parent = tool

	return tool
end

-- Keeps exactly one factory Tool, carrying the whole remaining stock as a
-- count. Same reconciliation as a produce stack, and safe to call repeatedly.
local function syncFactoryTool(player: Player)
	local count = stock[player] or 0
	local kept: Tool? = nil

	for _, container in ipairs(containers(player)) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child.Name == Config.Factory.ToolName then
				if count > 0 and not kept then
					kept = child
				else
					child:Destroy()
				end
			end
		end
	end

	if count <= 0 then
		return
	end

	if not kept then
		local backpack = player:FindFirstChildOfClass("Backpack")
		if not backpack then
			return
		end
		local created = createFactoryTool()
		created.Parent = backpack
		kept = created
	end

	kept.ToolTip = ("Click the factory zone to place (%d left)"):format(count)
	kept:SetAttribute(STOCK_ATTRIBUTE, count)
end

local function placedCount(player: Player): number
	local count = 0
	for _, record in ipairs(records) do
		if record.owner == player then
			count += 1
		end
	end
	return count
end

--[[ Running a machine ]]

-- What this machine should eat next. The fruit in the player's hand wins, so
-- "put the fruit in" means the one they are holding; falling back to stock
-- keeps the prompt usable with nothing equipped, and Produce.sources is sorted
-- so that fallback picks the same fruit every time.
local function chooseInput(player: Player): string?
	local held = InventoryService.heldItemName(player)
	if held and Produce.recipeFor(held) and InventoryService.itemCount(player, held) > 0 then
		return held
	end

	for _, source in ipairs(Produce.sources()) do
		if InventoryService.itemCount(player, source) > 0 then
			return source
		end
	end
	return nil
end

-- Names the fruit the player would insert next, so the prompt advertises what
-- pressing E will actually do rather than a generic "Insert Fruit". Only the
-- owner can trigger the prompt, so owner-specific text is safe here.
local function refreshIdlePrompt(record: FactoryRecord)
	-- Mid-cycle the prompt is showing "Collect ..." or is disabled; rewriting it
	-- from the idle text would erase that.
	if record.input or record.output then
		return
	end
	local candidate = chooseInput(record.owner)
	record.prompt.ActionText = if candidate then ("Insert %s"):format(candidate) else "Insert Fruit"
end

-- Every idle machine a player owns. Their stock changes whenever they harvest,
-- insert, collect or sell, and the prompt has to keep up or it advertises a
-- fruit they no longer have.
local function refreshIdlePromptsFor(player: Player)
	for _, record in ipairs(records) do
		if record.owner == player then
			refreshIdlePrompt(record)
		end
	end
end

local function insert(record: FactoryRecord, player: Player)
	local source = chooseInput(player)
	if not source then
		refuse(player, "has no fruit any factory accepts")
		return
	end

	local recipe = Produce.recipeFor(source)
	if not recipe then
		refuse(player, "nothing turns %s into anything", source)
		return
	end

	-- Consume only once the recipe is known to exist, so a bad config cannot
	-- eat a fruit and hand back nothing.
	if not InventoryService.takeItem(player, source, 1) then
		refuse(player, "does not have a %s to insert", source)
		return
	end

	record.input = source
	FactoryModel.showItem(record.model, source)
	record.prompt.Enabled = false

	log("%s inserted %s into a factory at %s (%.1fs)",
		player.Name, source, tostring(record.cell), recipe.ProcessTime)

	task.delay(recipe.ProcessTime, function()
		-- The machine can be removed, or its contents replaced, while the timer
		-- runs — the same guard scheduleFruit needs.
		if record.model.Parent == nil or record.input ~= source then
			return
		end

		record.input = nil
		record.output = recipe.Name
		FactoryModel.showItem(record.model, recipe.Name)
		record.prompt.ActionText = ("Collect %s"):format(recipe.Name)
		record.prompt.Enabled = true

		log("a factory at %s finished a %s", tostring(record.cell), recipe.Name)
	end)
end

local function collect(record: FactoryRecord, player: Player, product: string)
	-- Produce no longer stacks, so the pie needs a free Backpack slot. Leave it
	-- in the machine when there is none: the alternative is destroying something
	-- the player spent a fruit and three seconds on.
	if InventoryService.addItem(player, product, 1) < 1 then
		refuse(player, "backpack is full — the %s stays in the factory at %s",
			product, tostring(record.cell))
		return
	end

	record.output = nil
	FactoryModel.showItem(record.model, nil)
	refreshIdlePrompt(record)

	log("%s collected a %s worth %d coins", player.Name, product, Produce.price(product))
end

local function onPrompt(record: FactoryRecord, player: Player)
	-- The player placed this machine, so it is theirs. Plants have no such
	-- check, but there is no reason to inherit that gap here.
	if player ~= record.owner then
		refuse(player, "does not own the factory at %s", tostring(record.cell))
		return
	end

	local product = record.output
	if product then
		collect(record, player, product)
	elseif record.input then
		-- The prompt is disabled while processing, so this only happens if a
		-- trigger was already in flight when the timer started.
		refuse(player, "the factory at %s is still working", tostring(record.cell))
	else
		insert(record, player)
	end
end

-- Takes a machine back into the player's stock, freeing its cell.
--
-- Only when it is empty: refusing mid-cycle means there is never a question of
-- what happens to a fruit that was already eaten, and the player only has to
-- collect first.
local function onRemove(record: FactoryRecord, player: Player)
	if player ~= record.owner then
		refuse(player, "does not own the factory at %s", tostring(record.cell))
		return
	end

	if record.output then
		refuse(player, "the factory at %s still has a %s to collect", tostring(record.cell), record.output)
		return
	end

	if record.input then
		refuse(player, "the factory at %s is still working", tostring(record.cell))
		return
	end

	for index, candidate in ipairs(records) do
		if candidate == record then
			table.remove(records, index)
			break
		end
	end

	record.model:Destroy()
	stock[player] = (stock[player] or 0) + 1
	syncFactoryTool(player)

	log("%s picked up the factory at %s (%d left)", player.Name, tostring(record.cell), stock[player] or 0)
end

--[[ Placement ]]

local function occupiedCells(): { Vector3 }
	local cells: { Vector3 } = table.create(#records)
	for _, record in ipairs(records) do
		table.insert(cells, record.cell)
	end
	return cells
end

local function onPlaceRequest(player: Player, requested: unknown)
	local pad = zone
	if not pad then
		refuse(player, "the factory zone is missing")
		return
	end

	if typeof(requested) ~= "Vector3" then
		refuse(player, "payload was %s, not a Vector3", typeof(requested))
		return
	end
	local position = requested :: Vector3

	local now = os.clock()
	if now - (lastPlaceAt[player] or 0) < Config.Factory.PlaceCooldown then
		refuse(player, "still on cooldown (%.2fs)", Config.Factory.PlaceCooldown)
		return
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if not root then
		refuse(player, "no character or no PrimaryPart")
		return
	end

	local tool = character and character:FindFirstChild(Config.Factory.ToolName)
	if not (tool and tool:IsA("Tool")) then
		refuse(player, "no %q Tool equipped — it must be held, not just carried", Config.Factory.ToolName)
		return
	end

	if (stock[player] or 0) <= 0 then
		refuse(player, "has no factories left to place")
		return
	end

	if placedCount(player) >= Config.Factory.MaxPlaced then
		refuse(player, "at the %d factory limit", Config.Factory.MaxPlaced)
		return
	end

	local cell = FactoryGrid.project(pad, position)
	if not cell then
		refuse(player, "%s is not on a placeable cell of Workspace.%s (or is inside the %d stud edge margin)",
			tostring(position), Config.Factory.ZoneName, Config.Factory.EdgeMargin)
		return
	end

	if (root.Position - cell).Magnitude > Config.Factory.MaxPlaceDistance then
		refuse(player, "%.1f studs away, limit is %d",
			(root.Position - cell).Magnitude, Config.Factory.MaxPlaceDistance)
		return
	end

	if FactoryGrid.occupied(cell, occupiedCells()) then
		refuse(player, "the cell at %s is already taken", tostring(cell))
		return
	end

	-- Consume stock only once every check has passed.
	lastPlaceAt[player] = now
	stock[player] = (stock[player] or 0) - 1
	syncFactoryTool(player)

	local model = FactoryModel.create()
	FactoryModel.place(model, CFrame.new(cell) * FactoryGrid.orientation(pad))
	model:SetAttribute("OwnerUserId", player.UserId)
	model.Parent = factoryFolder

	-- By name, not by class: the machine carries two prompts and picking
	-- whichever one comes back first would wire the run cycle to Pick Up.
	local runPrompt = model:FindFirstChild("FactoryPrompt", true)
	local removePrompt = model:FindFirstChild("RemovePrompt", true)
	if not (runPrompt and runPrompt:IsA("ProximityPrompt")
		and removePrompt and removePrompt:IsA("ProximityPrompt")) then
		-- Without its prompts the machine is scenery, so fail loudly rather than
		-- leaving an inert box standing on a cell nobody can reclaim.
		warn("[FactoryService] built a factory without both prompts — discarding it.")
		model:Destroy()
		stock[player] = (stock[player] or 0) + 1
		syncFactoryTool(player)
		return
	end

	local record: FactoryRecord = {
		model = model,
		owner = player,
		cell = cell,
		prompt = runPrompt :: ProximityPrompt,
		input = nil,
		output = nil,
	}
	table.insert(records, record)

	record.prompt.Triggered:Connect(function(triggeredBy: Player)
		onPrompt(record, triggeredBy)
	end)
	;(removePrompt :: ProximityPrompt).Triggered:Connect(function(triggeredBy: Player)
		onRemove(record, triggeredBy)
	end)
	refreshIdlePrompt(record)

	log("%s placed a factory at %s under %s (%d placed, %d left)",
		player.Name,
		tostring(cell),
		if model.Parent then model.Parent:GetFullName() else "NOTHING — the model is not in the world",
		placedCount(player),
		stock[player] or 0)
end

local function removePlayer(player: Player)
	-- Nobody but the owner can ever use these, so leaving them standing would
	-- just block their cells for the rest of the round.
	for index = #records, 1, -1 do
		local record = records[index]
		if record.owner == player then
			record.model:Destroy()
			table.remove(records, index)
		end
	end

	lastPlaceAt[player] = nil
	stock[player] = nil
end

function FactoryService.start()
	local pad = workspace:FindFirstChild(Config.Factory.ZoneName)
	if not (pad and pad:IsA("BasePart")) then
		warn(("[FactoryService] Workspace.%s is not a BasePart — factories disabled.")
			:format(Config.Factory.ZoneName))
		return
	end
	zone = pad :: BasePart

	local existing = workspace:FindFirstChild(Config.Factory.FolderName)
	if existing then
		factoryFolder = existing :: Folder
	else
		local folder = Instance.new("Folder")
		folder.Name = Config.Factory.FolderName
		folder.Parent = workspace
		factoryFolder = folder
	end

	Remotes.event(Remotes.PLACE_FACTORY).OnServerEvent:Connect(onPlaceRequest)

	local function setupPlayer(player: Player)
		stock[player] = Config.Factory.StartingStock
		player.CharacterAdded:Connect(function()
			-- Respawning replaces the Backpack, taking the factory Tool with
			-- it. Rebuild it from the stock count once the new one arrives.
			task.defer(function()
				player:WaitForChild("Backpack", 10)
				syncFactoryTool(player)
			end)
		end)

		task.defer(function()
			player:WaitForChild("Backpack", 10)
			syncFactoryTool(player)
		end)

		-- InventoryService moves this on every harvest, insert, collect and
		-- sale, which makes it the one signal that covers all of them.
		task.spawn(function()
			local stats = player:WaitForChild("leaderstats", 30)
			local produce = stats and stats:WaitForChild("Fruit", 30)
			if produce and produce:IsA("IntValue") then
				produce.Changed:Connect(function()
					refreshIdlePromptsFor(player)
				end)
			end
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	local recipeCount = #Produce.sources()
	print(("[FactoryService] Ready on Workspace.%s — %d stud grid, %d recipe(s).")
		:format(Config.Factory.ZoneName, Config.Factory.GridSize, recipeCount))
end

return FactoryService
