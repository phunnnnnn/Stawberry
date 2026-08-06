--!strict

--[[
	Places factory machines on the factory zone and runs them.

	Placement mirrors PlantingService: the client reports *where* it clicked and
	nothing else, and every other decision — is that cell on the zone, is it
	free, is the player close enough, do they have a factory left to place — is
	made here.

	A machine has three states, and which of its two cycle prompts is showing is
	the whole interface:

	  empty       InputPrompt   "Insert Strawberry" -> eats a fruit, starts the timer
	  processing  neither       the fruit sits in the slot for ProcessTime seconds
	  ready       OutputPrompt  "Collect ..."       -> the product goes to the inventory

	`refreshPrompts` is the only thing that touches either prompt's `Enabled`, so
	the three states cannot drift apart. A machine is built with the output prompt
	already hidden — empty is the state it starts in.

	A third prompt on its own key takes an empty machine back into stock. It is
	currently switched off by `Config.Factory.CanRemove`, so a placed factory
	stays put; the handler is left wired so the flag is the only thing to change.

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
	inputPrompt: ProximityPrompt,
	outputPrompt: ProximityPrompt,
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

-- Shows the one prompt that matches the machine's state and hides the other.
-- The single place either `Enabled` is written, so no path can leave a machine
-- offering both or neither by accident.
--
-- The idle text names the fruit the player would insert next, so the prompt
-- advertises what pressing E will actually do rather than a generic "Insert
-- Fruit". Only the owner can trigger it, so owner-specific text is safe.
local function refreshPrompts(record: FactoryRecord)
	local product = record.output
	if product then
		-- Done: the only thing left to do is take the product out.
		record.inputPrompt.Enabled = false
		record.outputPrompt.ActionText = ("Collect %s"):format(product)
		record.outputPrompt.Enabled = true
		return
	end

	if record.input then
		-- Working. Nothing can be put in or taken out, so offer neither: an
		-- unpressable prompt reads as a bug, and its absence reads as "wait".
		record.inputPrompt.Enabled = false
		record.outputPrompt.Enabled = false
		return
	end

	local candidate = chooseInput(record.owner)
	record.inputPrompt.ActionText = if candidate then ("Insert %s"):format(candidate) else "Insert Fruit"
	record.inputPrompt.Enabled = true
	record.outputPrompt.Enabled = false
end

-- Every machine a player owns. Their stock changes whenever they harvest,
-- insert, collect or sell, and the idle text has to keep up or it advertises a
-- fruit they no longer have.
local function refreshPromptsFor(player: Player)
	for _, record in ipairs(records) do
		if record.owner == player then
			refreshPrompts(record)
		end
	end
end

-- The one state transition that starts a machine. A player's prompt and a worker
-- both come through here, so a cycle cannot be started two different ways and the
-- finish timer can only ever be armed once per load.
local function beginCycle(record: FactoryRecord, source: string, recipe: Config.ProductSpec)
	record.input = source
	FactoryModel.showItem(record.model, source)
	refreshPrompts(record)

	task.delay(recipe.ProcessTime, function()
		-- The machine can be removed, or its contents replaced, while the timer
		-- runs — the same guard scheduleFruit needs.
		if record.model.Parent == nil or record.input ~= source then
			return
		end

		record.input = nil
		record.output = recipe.Name
		FactoryModel.showItem(record.model, recipe.Name)
		refreshPrompts(record)

		log("a factory at %s finished a %s", tostring(record.cell), recipe.Name)
	end)
end

-- The one state transition that empties a finished machine, handing back what came
-- out. The caller decides where it goes: a player's prompt has already found
-- Backpack room for it, a worker takes it in its hands.
local function endCycle(record: FactoryRecord): string?
	local product = record.output
	if not product then
		return nil
	end

	record.output = nil
	FactoryModel.showItem(record.model, nil)
	refreshPrompts(record)
	return product
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

	beginCycle(record, source, recipe)

	log("%s inserted %s into a factory at %s (%.1fs)",
		player.Name, source, tostring(record.cell), recipe.ProcessTime)
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

	endCycle(record)

	log("%s collected a %s worth %d coins", player.Name, product, Produce.price(product))
end

-- The player placed this machine, so it is theirs. Plants have no such check,
-- but there is no reason to inherit that gap here.
local function owns(record: FactoryRecord, player: Player): boolean
	if player == record.owner then
		return true
	end
	refuse(player, "does not own the factory at %s", tostring(record.cell))
	return false
end

-- Both handlers re-check the machine's state rather than trusting that the
-- right prompt was showing: a trigger can already be in flight when the state
-- changes under it.
local function onInputPrompt(record: FactoryRecord, player: Player)
	if not owns(record, player) then
		return
	end

	if record.output then
		refuse(player, "the factory at %s has a %s waiting to be collected",
			tostring(record.cell), record.output)
		return
	end

	if record.input then
		refuse(player, "the factory at %s is still working", tostring(record.cell))
		return
	end

	insert(record, player)
end

local function onOutputPrompt(record: FactoryRecord, player: Player)
	if not owns(record, player) then
		return
	end

	local product = record.output
	if not product then
		refuse(player, "the factory at %s has nothing to collect", tostring(record.cell))
		return
	end

	collect(record, player, product)
end

-- Takes a machine back into the player's stock, freeing its cell.
--
-- Only when it is empty: refusing mid-cycle means there is never a question of
-- what happens to a fruit that was already eaten, and the player only has to
-- collect first.
local function onRemove(record: FactoryRecord, player: Player)
	-- Re-checked here and not just left to the hidden prompt, for the same
	-- reason every other gate is server-side: a disabled prompt is a client-side
	-- fact, and this hands a machine back into stock.
	if not Config.Factory.CanRemove then
		refuse(player, "factory pick-up is switched off")
		return
	end

	if not owns(record, player) then
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

	-- By name, not by class: the machine carries three prompts and picking
	-- whichever one comes back first would wire inserting to Pick Up.
	local inputPrompt = model:FindFirstChild("InputPrompt", true)
	local outputPrompt = model:FindFirstChild("OutputPrompt", true)
	local removePrompt = model:FindFirstChild("RemovePrompt", true)
	if not (inputPrompt and inputPrompt:IsA("ProximityPrompt")
		and outputPrompt and outputPrompt:IsA("ProximityPrompt")
		and removePrompt and removePrompt:IsA("ProximityPrompt")) then
		-- Without its prompts the machine is scenery, so fail loudly rather than
		-- leaving an inert box standing on a cell nobody can reclaim.
		warn("[FactoryService] built a factory without all three prompts — discarding it.")
		model:Destroy()
		stock[player] = (stock[player] or 0) + 1
		syncFactoryTool(player)
		return
	end

	local record: FactoryRecord = {
		model = model,
		owner = player,
		cell = cell,
		inputPrompt = inputPrompt :: ProximityPrompt,
		outputPrompt = outputPrompt :: ProximityPrompt,
		input = nil,
		output = nil,
	}
	table.insert(records, record)

	record.inputPrompt.Triggered:Connect(function(triggeredBy: Player)
		onInputPrompt(record, triggeredBy)
	end)
	record.outputPrompt.Triggered:Connect(function(triggeredBy: Player)
		onOutputPrompt(record, triggeredBy)
	end)
	;(removePrompt :: ProximityPrompt).Triggered:Connect(function(triggeredBy: Player)
		onRemove(record, triggeredBy)
	end)
	refreshPrompts(record)

	log("%s placed a factory at %s under %s (%d placed, %d left)",
		player.Name,
		tostring(cell),
		if model.Parent then model.Parent:GetFullName() else "NOTHING — the model is not in the world",
		placedCount(player),
		stock[player] or 0)
end

--[[ Worker-facing view of the factory zone

	A worker is a second actor on the same machines, so it gets *queries* — is
	there one I can load, is there one with something waiting — and *commits* that
	go through the same two transitions the prompts use. It never reaches into
	`records`, and it never touches a prompt's `Enabled`: beginCycle and endCycle
	both end in refreshPrompts, so a machine a worker loaded advertises itself
	exactly like one a player loaded.
]]

export type MachineHandle = {
	model: Model,
	position: Vector3,
}

local function handleFor(record: FactoryRecord): MachineHandle
	return { model = record.model, position = record.cell }
end

local function recordFor(handle: MachineHandle): FactoryRecord?
	for _, record in ipairs(records) do
		if record.model == handle.model then
			return record
		end
	end
	return nil
end

-- Nearest machine of `owner`'s that `accept` likes, skipping any model in `skip`
-- so two workers do not both walk to the same one.
local function nearestMatching(
	owner: Player,
	from: Vector3,
	skip: { [Instance]: boolean }?,
	accept: (FactoryRecord) -> boolean
): MachineHandle?
	local best: FactoryRecord? = nil
	local bestDistance = math.huge

	for _, record in ipairs(records) do
		if record.owner == owner and record.model.Parent ~= nil
			and not (skip and skip[record.model]) and accept(record)
		then
			local distance = (record.cell - from).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = record
			end
		end
	end

	return if best then handleFor(best) else nil
end

-- An empty machine of `owner`'s that would take `itemName`.
function FactoryService.idleFactoryFor(
	owner: Player,
	itemName: string,
	from: Vector3,
	skip: { [Instance]: boolean }?
): MachineHandle?
	-- Nothing refines a pie, so a worker carrying one is told there is no machine
	-- for it rather than being sent to load it into something.
	if not Produce.recipeFor(itemName) then
		return nil
	end
	return nearestMatching(owner, from, skip, function(record)
		return record.input == nil and record.output == nil
	end)
end

-- A machine of `owner`'s with a finished product waiting to be taken out.
function FactoryService.readyFactoryFor(
	owner: Player,
	from: Vector3,
	skip: { [Instance]: boolean }?
): MachineHandle?
	return nearestMatching(owner, from, skip, function(record)
		return record.output ~= nil
	end)
end

-- True when one of `owner`'s machines is mid-cycle. Lets a worker holding a fruit
-- wait for a machine to free up instead of giving up and selling it raw for a
-- third of what refining it would earn.
function FactoryService.hasWorkingFactory(owner: Player): boolean
	for _, record in ipairs(records) do
		if record.owner == owner and record.input ~= nil then
			return true
		end
	end
	return false
end

-- Whether `owner` has any machine standing at all. A worker with nowhere to
-- refine a fruit takes it straight to the stall instead of holding out for a
-- factory that does not exist.
function FactoryService.hasFactory(owner: Player): boolean
	return placedCount(owner) > 0
end

-- Loads an item the caller is already holding. Nothing is taken from an
-- inventory: unlike the prompt path, the fruit is in a worker's hands and was
-- never in the tally.
--
-- Re-checked rather than trusted, because a player can load the same machine
-- during the seconds a worker spends walking to it.
function FactoryService.insertItem(handle: MachineHandle, itemName: string): boolean
	local record = recordFor(handle)
	if not record or record.input or record.output then
		return false
	end

	local recipe = Produce.recipeFor(itemName)
	if not recipe then
		return false
	end

	beginCycle(record, itemName, recipe)
	return true
end

-- Takes the finished product out for a caller that will carry it away. Nil when
-- the owner already collected it by hand while the worker was walking over.
function FactoryService.collectProduct(handle: MachineHandle): string?
	local record = recordFor(handle)
	if not record then
		return nil
	end
	return endCycle(record)
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
					refreshPromptsFor(player)
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
