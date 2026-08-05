--!strict

--[[
	Attaches the sell prompt to Workspace.Seller and settles sales.

	The prompt is created server-side so it replicates to everyone; the client
	opens its own dialogue off the same prompt's Triggered signal. The distance
	check is repeated here because the client's dialogue proves nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local InventoryService = require(script.Parent.InventoryService)

local SellService = {}

local seller: BasePart? = nil

local function nearSeller(player: Player): boolean
	local stall = seller
	local character = player.Character
	local root = character and character.PrimaryPart
	if not (stall and root) then
		return false
	end
	return (root.Position - stall.Position).Magnitude <= Config.Seller.MaxSellDistance
end

local function onSellRequest(player: Player): InventoryService.SaleResult
	if not nearSeller(player) then
		return { sold = 0, earned = 0 }
	end
	return InventoryService.sellAllFruit(player)
end

function SellService.start()
	local stall = workspace:FindFirstChild(Config.Seller.PartName)
	if not (stall and stall:IsA("BasePart")) then
		warn(("[SellService] Workspace.%s is not a BasePart — selling disabled.")
			:format(Config.Seller.PartName))
		return
	end
	seller = stall :: BasePart

	local prompt = stall:FindFirstChild("SellPrompt")
	if not prompt then
		local created = Instance.new("ProximityPrompt")
		created.Name = "SellPrompt"
		created.ActionText = "Sell Fruit"
		created.ObjectText = "Seller"
		created.HoldDuration = 0
		created.MaxActivationDistance = Config.Seller.PromptRange
		created.RequiresLineOfSight = false
		created.Parent = stall
	end

	Remotes.func(Remotes.SELL_FRUIT).OnServerInvoke = onSellRequest

	print(("[SellService] Ready on Workspace.%s."):format(Config.Seller.PartName))
end

return SellService
