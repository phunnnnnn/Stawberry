--!strict

--[[
	Attaches the sell prompt to Workspace.Seller and settles sales.

	The prompt is created server-side so it replicates to everyone; the client
	opens its own dialogue off the same prompt's Triggered signal. The distance
	check is repeated here because the client's dialogue proves nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Produce = require(ReplicatedStorage.Shared.Produce)
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

local function resolveSale(player: Player, mode: unknown): InventoryService.SaleResult
	if not nearSeller(player) then
		return { sold = 0, earned = 0, reason = "Move closer to the seller." }
	end

	if mode == "held" then
		return InventoryService.sellHeldItem(player)
	end
	if mode ~= nil and mode ~= "all" then
		return { sold = 0, earned = 0, reason = "Unknown sale option." }
	end
	return InventoryService.sellAllItems(player)
end

-- A refused sale only ever surfaced in the player's own dialogue, so from
-- outside the game a failed sale was indistinguishable from one nobody tried.
-- Config.Seller.LogSales silences this.
local function onSellRequest(player: Player, mode: unknown): InventoryService.SaleResult
	local result = resolveSale(player, mode)

	if Config.Seller.LogSales then
		if result.sold > 0 then
			print(("[SellService] %s sold %d %s for %d coins."):format(
				player.Name,
				result.sold,
				result.itemName or (if result.sold == 1 then "item" else "items"),
				result.earned))
		else
			warn(("[SellService] %s sale refused (mode %s): %s"):format(
				player.Name, tostring(mode), result.reason or "no reason given"))
		end
	end

	return result
end

-- The stall itself, so a worker can work out where to walk and how wide a berth
-- to give it. Nil until start() has found it.
function SellService.stall(): BasePart?
	return seller
end

-- Pays `player` for one item a worker carried to the stall.
--
-- Nothing is taken from the inventory tally because the item was never in it —
-- the worker held it in its hands the whole way. There is no distance check
-- either: the worker's arrival is the server's own fact, not a client's claim.
-- The price still comes from Produce, so a worker cannot be paid a number the
-- player's own sale would not honour.
function SellService.sellCarried(player: Player, itemName: string): number
	local earned = Produce.price(itemName)
	if earned <= 0 then
		if Config.Seller.LogSales then
			warn(("[SellService] refused a worker's %s — nothing prices it."):format(itemName))
		end
		return 0
	end

	InventoryService.addCoins(player, earned)

	if Config.Seller.LogSales then
		print(("[SellService] %s's worker sold a %s for %d coins."):format(player.Name, itemName, earned))
	end
	return earned
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
