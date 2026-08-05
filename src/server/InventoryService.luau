--!strict

--[[
	Owns everything the player carries.

	Seeds live in the Backpack as Tools — that Tool list *is* the seed
	inventory, so there is no parallel seed counter to drift out of sync.
	Fruit is a server-side per-species tally, mirrored to leaderstats as a
	single total for display. Each species also gets one stack Tool so the
	player can equip that produce and sell one held item at the Seller. The
	server tally remains authoritative. Coins are the sale payout.

	No persistence: everything resets when the server shuts down.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Seed = require(ReplicatedStorage.Shared.Seed)

local InventoryService = {}

-- player -> fruit name -> count
local fruitByPlayer: { [Player]: { [string]: number } } = {}

-- Fruit name -> sale price, indexed from Config.Plants once at startup.
local priceIndex: { [string]: number } = {}

local FRUIT_ATTRIBUTE = "FruitName"

-- Held quantity, mirrored onto the stack Tool so the client can display it.
-- There is exactly one Tool per species, so a client counting Tools would always
-- see 1; the tally here stays authoritative for anything that pays out.
local COUNT_ATTRIBUTE = "FruitCount"

local function statsFolder(player: Player): Instance
	local existing = player:FindFirstChild("leaderstats")
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	folder.Parent = player
	return folder
end

local function statValue(player: Player, name: string): IntValue
	local stats = statsFolder(player)
	local existing = stats:FindFirstChild(name)
	if existing then
		return existing :: IntValue
	end

	local value = Instance.new("IntValue")
	value.Name = name
	value.Value = 0
	value.Parent = stats
	return value
end

local function fruitTable(player: Player): { [string]: number }
	local existing = fruitByPlayer[player]
	if existing then
		return existing
	end

	local created: { [string]: number } = {}
	fruitByPlayer[player] = created
	return created
end

local function totalFruit(player: Player): number
	local total = 0
	for _, count in pairs(fruitTable(player)) do
		total += count
	end
	return total
end

local function syncFruitStat(player: Player)
	statValue(player, "Fruit").Value = totalFruit(player)
end

local function fruitContainers(player: Player): { Instance }
	local containers: { Instance } = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(containers, backpack)
	end
	if player.Character then
		table.insert(containers, player.Character)
	end
	return containers
end

local function createFruitTool(fruitName: string): Tool?
	local spec: Config.FruitSpec? = nil
	for _, plantSpec in pairs(Config.Plants) do
		if plantSpec.Fruit and plantSpec.Fruit.Name == fruitName then
			spec = plantSpec.Fruit
			break
		end
	end
	if not spec then
		return nil
	end

	local tool = Instance.new("Tool")
	tool.Name = fruitName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute(FRUIT_ATTRIBUTE, fruitName)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Shape = Enum.PartType.Ball
	handle.Size = spec.Size
	handle.Color = spec.Color
	handle.Material = Enum.Material.SmoothPlastic
	handle.Massless = true
	handle.CanCollide = false
	handle.CanTouch = false
	handle.Parent = tool

	return tool
end

-- Keep exactly one Tool per fruit species. It represents the server-owned
-- stack, not a second inventory counter.
local function syncFruitTool(player: Player, fruitName: string)
	local count = fruitTable(player)[fruitName] or 0
	local kept: Tool? = nil

	for _, container in ipairs(fruitContainers(player)) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute(FRUIT_ATTRIBUTE) == fruitName then
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
		local created = createFruitTool(fruitName)
		local backpack = player:FindFirstChildOfClass("Backpack")
		if not (created and backpack) then
			return
		end
		created.Parent = backpack
		kept = created
	end

	kept.ToolTip = ("Harvested %s x%d"):format(fruitName, count)
	kept:SetAttribute(COUNT_ATTRIBUTE, count)
end

local function removeAllFruitTools(player: Player)
	for _, container in ipairs(fruitContainers(player)) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and typeof(child:GetAttribute(FRUIT_ATTRIBUTE)) == "string" then
				child:Destroy()
			end
		end
	end
end

local function syncAllFruitTools(player: Player)
	for fruitName, count in pairs(fruitTable(player)) do
		if count > 0 then
			syncFruitTool(player, fruitName)
		end
	end
end

local function equippedFruitTool(player: Player): Tool?
	local character = player.Character
	if not character then
		return nil
	end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and typeof(child:GetAttribute(FRUIT_ATTRIBUTE)) == "string" then
			return child
		end
	end
	return nil
end

-- Safe to call repeatedly; used on join and again on every award.
function InventoryService.setup(player: Player)
	statValue(player, "Fruit")
	statValue(player, "Coins")
	fruitTable(player)
end

function InventoryService.seedCount(player: Player): number
	local count = 0

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, item in ipairs(backpack:GetChildren()) do
			if item:IsA("Tool") and item.Name == Config.Seed.ToolName then
				count += 1
			end
		end
	end

	-- An equipped seed lives on the character, not the Backpack.
	local character = player.Character
	if character then
		for _, item in ipairs(character:GetChildren()) do
			if item:IsA("Tool") and item.Name == Config.Seed.ToolName then
				count += 1
			end
		end
	end

	return count
end

-- Returns false when the Backpack is already at Config.Seed.MaxHeld, so the
-- caller can leave the belt seed in place rather than destroying it.
function InventoryService.grantSeed(player: Player): boolean
	if InventoryService.seedCount(player) >= Config.Seed.MaxHeld then
		return false
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false
	end

	Seed.createTool().Parent = backpack
	return true
end

function InventoryService.addFruit(player: Player, fruitName: string, count: number)
	local fruit = fruitTable(player)
	fruit[fruitName] = (fruit[fruitName] or 0) + count
	syncFruitStat(player)
	syncFruitTool(player, fruitName)
end

export type SaleResult = {
	sold: number,
	earned: number,
	itemName: string?,
	reason: string?,
}

-- Clears the player's fruit and pays out at per-species prices.
function InventoryService.sellAllFruit(player: Player): SaleResult
	local fruit = fruitTable(player)
	local sold = 0
	local earned = 0

	for fruitName, count in pairs(fruit) do
		if count > 0 then
			sold += count
			earned += count * (priceIndex[fruitName] or 0)
		end
	end

	if sold == 0 then
		return { sold = 0, earned = 0, reason = "You have no fruit to sell." }
	end

	fruitByPlayer[player] = {}
	syncFruitStat(player)
	removeAllFruitTools(player)
	statValue(player, "Coins").Value += earned

	return { sold = sold, earned = earned }
end

-- Sells one unit from the fruit stack Tool currently equipped by the player.
-- The Tool attribute is only a selector; quantity and price are validated from
-- server-owned state before anything is paid out.
function InventoryService.sellHeldFruit(player: Player): SaleResult
	local tool = equippedFruitTool(player)
	if not tool then
		return { sold = 0, earned = 0, reason = "Hold harvested fruit in your hand first." }
	end

	local fruitNameValue = tool:GetAttribute(FRUIT_ATTRIBUTE)
	if typeof(fruitNameValue) ~= "string" then
		return { sold = 0, earned = 0, reason = "That item cannot be sold." }
	end
	local fruitName = fruitNameValue :: string
	local fruit = fruitTable(player)
	local count = fruit[fruitName] or 0
	local price = priceIndex[fruitName]
	if count <= 0 or not price then
		syncFruitTool(player, fruitName)
		return { sold = 0, earned = 0, reason = "That fruit is not in your inventory." }
	end

	fruit[fruitName] = count - 1
	syncFruitStat(player)
	syncFruitTool(player, fruitName)
	statValue(player, "Coins").Value += price

	return { sold = 1, earned = price, itemName = fruitName }
end

function InventoryService.start()
	for _, spec in pairs(Config.Plants) do
		local fruitSpec = spec.Fruit
		if fruitSpec then
			priceIndex[fruitSpec.Name] = fruitSpec.SellPrice
		end
	end

	local function setupPlayer(player: Player)
		InventoryService.setup(player)
		player.CharacterAdded:Connect(function()
			-- Roblox may replace the Backpack on respawn. Recreate the visual
			-- stack Tools from the authoritative fruit tally after it arrives.
			task.defer(function()
				player:WaitForChild("Backpack", 10)
				syncAllFruitTools(player)
			end)
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		fruitByPlayer[player] = nil
	end)
end

return InventoryService
