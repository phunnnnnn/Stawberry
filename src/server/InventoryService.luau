--!strict

--[[
	Owns everything the player carries.

	Seeds live in the Backpack as Tools — that Tool list *is* the seed
	inventory, so there is no parallel seed counter to drift out of sync. They
	are typed, one per species, and identified by the attribute Seed tags them
	with rather than by name; they are also *bought*, so `buySeed` is a second
	place coins leave a player and it goes through `spendCoins` like the first.
	Produce — harvested fruit and factory products alike — is a server-side
	per-item tally, mirrored to leaderstats as a single total for display. The
	server tally remains authoritative. Coins are the sale payout, plus the
	stake every player joins with.

	**Produce does not stack.** The tally materialises as one Tool per item, so
	three strawberries are three Tools. That is why the tally is kept rather than
	letting the Tool list be the truth outright: the Backpack is replaced on
	respawn, and rebuilding from a server-side number is what stops death from
	wiping an inventory. The Tools mirror the tally; the tally never mirrors the
	Tools.

	Because one Tool is exactly one item, counting Tools is now a correct way to
	get a quantity — the opposite of the stacked design this replaced. Anything
	that pays out still reads the tally.

	Fruit and products are held by exactly the same machinery; Produce is what
	tells them apart, and only the factory cares about the difference. The
	replicated `FruitName` attribute and `leaderstats.Fruit` predate products and
	are kept as-is on purpose: client modules read them, and renaming a wire
	contract to gain the word "item" would buy nothing.

	**What the tally is keyed by is an item *id*, not a bare name.** Factories
	have levels, so two Strawberry Pies can be worth different amounts, and the
	dearer one is a different thing to hold: `Produce` encodes that as a grade
	suffix on the id. Nothing here has to know that — an id is a string, it keys
	the tally, it goes on the `FruitName` attribute, and every price question goes
	through `Produce.price` rather than reading `spec.SellPrice` directly. That
	last part is the rule to keep: `spec.SellPrice` is the *base* price and would
	silently sell a levelled product for what an unlevelled one is worth.

	No persistence: everything resets when the server shuts down.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Produce = require(ReplicatedStorage.Shared.Produce)
local Seed = require(ReplicatedStorage.Shared.Seed)

local InventoryService = {}

-- player -> item name -> count
local itemsByPlayer: { [Player]: { [string]: number } } = {}

-- Marks a Tool as one unit of produce, and names which item it is. Used as a
-- selector when the player equips something; never as proof of quantity.
local FRUIT_ATTRIBUTE = "FruitName"

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

-- What a stat is worth the moment it is created. Held here rather than passed
-- in by `setup`, so whichever path happens to create Coins first — a sale, a
-- hire, a seed purchase — starts it at the same number.
local STAT_DEFAULTS: { [string]: number } = {
	Fruit = 0,
	Coins = Config.Inventory.StartingCoins,
}

local function statValue(player: Player, name: string): IntValue
	local stats = statsFolder(player)
	local existing = stats:FindFirstChild(name)
	if existing then
		return existing :: IntValue
	end

	local value = Instance.new("IntValue")
	value.Name = name
	value.Value = STAT_DEFAULTS[name] or 0
	value.Parent = stats
	return value
end

local function itemTable(player: Player): { [string]: number }
	local existing = itemsByPlayer[player]
	if existing then
		return existing
	end

	local created: { [string]: number } = {}
	itemsByPlayer[player] = created
	return created
end

local function totalItems(player: Player): number
	local total = 0
	for _, count in pairs(itemTable(player)) do
		total += count
	end
	return total
end

local function syncItemStat(player: Player)
	statValue(player, "Fruit").Value = totalItems(player)
end

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

local function createStackTool(itemId: string): Tool?
	local spec = Produce.spec(itemId)
	if not spec then
		return nil
	end

	-- The name is a label and the attribute is the contract, the same split seeds
	-- and factories use. So the hotbar shows "Strawberry Pie ×3" while the id that
	-- keys the tally rides on the attribute, unmangled.
	local display = Produce.displayName(itemId)

	local tool = Instance.new("Tool")
	tool.Name = display
	tool.ToolTip = ("%s — %d coins"):format(display, Produce.price(itemId))
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute(FRUIT_ATTRIBUTE, itemId)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Shape = spec.Shape
	handle.Size = spec.Size
	handle.Color = spec.Color
	handle.Material = Enum.Material.SmoothPlastic
	handle.Massless = true
	handle.CanCollide = false
	handle.CanTouch = false
	handle.Parent = tool

	return tool
end

-- Every Tool of one item the player is carrying, equipped ones first.
--
-- Order matters when trimming: keeping from the front means selling one of
-- three leaves the player still holding one, instead of emptying their hand.
local function toolsFor(player: Player, itemName: string): { Tool }
	local found: { Tool } = {}
	local character = player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute(FRUIT_ATTRIBUTE) == itemName then
				table.insert(found, child)
			end
		end
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute(FRUIT_ATTRIBUTE) == itemName then
				table.insert(found, child)
			end
		end
	end
	return found
end

-- Bring the Tools in line with the tally: one Tool per item, no stacking.
-- Reconciles in both directions, so it is safe to call after any change and
-- again after a respawn has replaced the Backpack.
local function syncItemTools(player: Player, itemName: string)
	local wanted = itemTable(player)[itemName] or 0
	local existing = toolsFor(player, itemName)

	for index = #existing, wanted + 1, -1 do
		existing[index]:Destroy()
	end

	if #existing >= wanted then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	for _ = #existing + 1, wanted do
		local created = createStackTool(itemName)
		if not created then
			return
		end
		created.Parent = backpack
	end
end

local function removeAllStackTools(player: Player)
	for _, container in ipairs(containers(player)) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and typeof(child:GetAttribute(FRUIT_ATTRIBUTE)) == "string" then
				child:Destroy()
			end
		end
	end
end

local function syncAllStackTools(player: Player)
	for itemName, count in pairs(itemTable(player)) do
		if count > 0 then
			syncItemTools(player, itemName)
		end
	end
end

local function equippedStackTool(player: Player): Tool?
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
	itemTable(player)
end

-- Seeds of every species together. Counted by the attribute rather than by
-- name, because eighteen species mean eighteen Tool names and only one of them
-- would be found by a name check.
function InventoryService.seedCount(player: Player): number
	local count = 0

	-- An equipped seed lives on the character, not the Backpack.
	for _, container in ipairs(containers(player)) do
		for _, item in ipairs(container:GetChildren()) do
			if item:IsA("Tool") and Seed.speciesOf(item) then
				count += 1
			end
		end
	end

	return count
end

-- Hands over a seed of `speciesName`, free. Returns false when the Backpack is
-- already at Config.Seed.MaxHeld, so the caller can leave the belt seed in
-- place rather than destroying it.
function InventoryService.grantSeed(player: Player, speciesName: string?): boolean
	if InventoryService.seedCount(player) >= Config.Seed.MaxHeld then
		return false
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false
	end

	Seed.createTool(speciesName).Parent = backpack
	return true
end

-- Sells the player a seed off the belt: the one place coins turn into one.
--
-- Coins move before the Tool exists and only through spendCoins, which is
-- all-or-nothing, so a player cannot be half-charged. The room check comes
-- first for the same reason harvesting checks before picking — being charged
-- for a seed with nowhere to put it would be the one unrecoverable outcome.
--
-- The reason is returned rather than logged here so the caller can report it
-- against the seed that was refused.
function InventoryService.buySeed(player: Player, speciesName: string): (boolean, string?)
	if InventoryService.seedCount(player) >= Config.Seed.MaxHeld then
		return false, ("already carrying %d seeds"):format(Config.Seed.MaxHeld)
	end

	local price = Seed.price(speciesName)
	if not InventoryService.spendCoins(player, price) then
		return false, ("costs %d coins, has %d"):format(price, statValue(player, "Coins").Value)
	end

	if not InventoryService.grantSeed(player, speciesName) then
		-- Only reachable if the Backpack vanished between the two checks. Refund
		-- rather than pocket the coins for nothing.
		InventoryService.addCoins(player, price)
		return false, "no Backpack to put it in"
	end

	return true, nil
end

-- Awards produce, and returns how many actually fit.
--
-- Since produce stopped stacking, every item costs a Backpack slot, so this can
-- award fewer than asked or none at all. Callers must check: harvesting and
-- collecting leave the item where it is rather than destroying something the
-- player never received.
function InventoryService.addItem(player: Player, itemName: string, count: number): number
	local room = Config.Inventory.MaxProduce - InventoryService.produceCount(player)
	local granted = math.min(count, math.max(0, room))
	if granted <= 0 then
		return 0
	end

	local items = itemTable(player)
	items[itemName] = (items[itemName] or 0) + granted
	syncItemStat(player)
	syncItemTools(player, itemName)
	return granted
end

function InventoryService.itemCount(player: Player, itemName: string): number
	return itemTable(player)[itemName] or 0
end

-- Every distinct item the player is carrying, in a fixed order.
--
-- Sorted rather than handed back in `pairs` order, which is not stable: a
-- factory picking "the first thing I will accept" out of this must pick the same
-- one every run, or the same inventory loads a different machine each time.
function InventoryService.itemIds(player: Player): { string }
	local found: { string } = {}
	for itemId, count in pairs(itemTable(player)) do
		if count > 0 then
			table.insert(found, itemId)
		end
	end
	table.sort(found)
	return found
end

-- Every piece of produce carried, of any kind. This is what MaxProduce caps.
function InventoryService.produceCount(player: Player): number
	return totalItems(player)
end

-- Removes `count` of an item, or changes nothing and returns false when the
-- player does not have that many. All-or-nothing so a caller that goes on to
-- hand something back cannot consume a partial input.
function InventoryService.takeItem(player: Player, itemName: string, count: number): boolean
	local items = itemTable(player)
	local held = items[itemName] or 0
	if held < count then
		return false
	end

	items[itemName] = held - count
	syncItemStat(player)
	syncItemTools(player, itemName)
	return true
end

-- The item the player currently has equipped, by the attribute the stack Tool
-- is tagged with. Only a selector: quantity and price come from the tally.
function InventoryService.heldItemName(player: Player): string?
	local tool = equippedStackTool(player)
	if not tool then
		return nil
	end
	local itemName = tool:GetAttribute(FRUIT_ATTRIBUTE)
	if typeof(itemName) ~= "string" then
		return nil
	end
	return itemName :: string
end

-- One of the two places Coins moves — the other is spendCoins, just below.
-- Selling out of the tally comes through here, and so does a worker being paid
-- for something it carried to the stall in its hands and that therefore was
-- never in the tally at all.
function InventoryService.addCoins(player: Player, amount: number): number
	local coins = statValue(player, "Coins")
	coins.Value += amount
	return coins.Value
end

-- Spends coins, or changes nothing and returns false when the player cannot
-- afford it. All-or-nothing, the same contract as takeItem, so a caller that goes
-- on to hand something over — a hired worker, say — cannot half-charge for it.
function InventoryService.spendCoins(player: Player, amount: number): boolean
	local coins = statValue(player, "Coins")
	if coins.Value < amount then
		return false
	end

	coins.Value -= amount
	return true
end

export type SaleResult = {
	sold: number,
	earned: number,
	itemName: string?,
	reason: string?,
}

-- Clears the player's produce and pays out at per-item prices.
function InventoryService.sellAllItems(player: Player): SaleResult
	local items = itemTable(player)
	local sold = 0
	local earned = 0

	for itemName, count in pairs(items) do
		if count > 0 then
			sold += count
			earned += count * Produce.price(itemName)
		end
	end

	if sold == 0 then
		return { sold = 0, earned = 0, reason = "You have nothing to sell." }
	end

	itemsByPlayer[player] = {}
	syncItemStat(player)
	removeAllStackTools(player)
	InventoryService.addCoins(player, earned)

	return { sold = sold, earned = earned }
end

-- Sells one unit from the stack Tool currently equipped by the player. The Tool
-- attribute is only a selector; quantity and price are validated from
-- server-owned state before anything is paid out.
function InventoryService.sellHeldItem(player: Player): SaleResult
	local itemName = InventoryService.heldItemName(player)
	if not itemName then
		return { sold = 0, earned = 0, reason = "Hold something in your hand first." }
	end

	-- Priced through Produce rather than off spec.SellPrice, which is the *base*
	-- price and would pay a Masterpiece out of a level-4 machine exactly what one
	-- out of a level-1 is worth.
	local price = Produce.price(itemName)
	if not (Produce.spec(itemName) and InventoryService.takeItem(player, itemName, 1)) then
		syncItemTools(player, itemName)
		return { sold = 0, earned = 0, reason = "That is not in your inventory." }
	end

	InventoryService.addCoins(player, price)

	return { sold = 1, earned = price, itemName = Produce.displayName(itemName) }
end

function InventoryService.start()
	local function setupPlayer(player: Player)
		InventoryService.setup(player)
		player.CharacterAdded:Connect(function()
			-- Roblox may replace the Backpack on respawn. Recreate the visual
			-- stack Tools from the authoritative tally after it arrives.
			task.defer(function()
				player:WaitForChild("Backpack", 10)
				syncAllStackTools(player)
			end)
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		itemsByPlayer[player] = nil
	end)
end

return InventoryService
