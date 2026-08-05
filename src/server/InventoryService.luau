--!strict

--[[
	Owns everything the player carries.

	Seeds live in the Backpack as Tools — that Tool list *is* the seed
	inventory, so there is no parallel seed counter to drift out of sync.
	Fruit is a server-side per-species tally, mirrored to leaderstats as a
	single total for display. Coins are the sale payout.

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
end

export type SaleResult = {
	sold: number,
	earned: number,
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
		return { sold = 0, earned = 0 }
	end

	fruitByPlayer[player] = {}
	syncFruitStat(player)
	statValue(player, "Coins").Value += earned

	return { sold = sold, earned = earned }
end

function InventoryService.start()
	for _, spec in pairs(Config.Plants) do
		local fruitSpec = spec.Fruit
		if fruitSpec then
			priceIndex[fruitSpec.Name] = fruitSpec.SellPrice
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		InventoryService.setup(player)
	end
	Players.PlayerAdded:Connect(InventoryService.setup)
	Players.PlayerRemoving:Connect(function(player: Player)
		fruitByPlayer[player] = nil
	end)
end

return InventoryService
