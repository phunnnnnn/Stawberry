--!strict

--[[
	Price card shown while produce is held.

	Equipping an item is how you inspect it before selling: the card names it,
	gives its rarity band, the unit price, and totals what you are carrying of
	it. Prices come from Produce — the same index InventoryService charges
	against — so the number quoted here is the number you get paid, for a factory
	pie as much as for a strawberry.

	The band comes from Produce too, which is why a Watermelon Masterpiece reads
	as Mythic: refining carries the species' rarity up the ladder unchanged.

	Display only. Nothing here can change a sale.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Produce = require(ReplicatedStorage.Shared.Produce)
local Rarity = require(ReplicatedStorage.Shared.Rarity)

type Card = {
	gui: ScreenGui,
	title: TextLabel,
	band: TextLabel,
	detail: TextLabel,
}

local FruitInspector = {}

local player = Players.LocalPlayer

-- Must match the attribute InventoryService tags produce Tools with.
local FRUIT_ATTRIBUTE = "FruitName"

local card: Card? = nil

-- The equipped stack Tool, identified by the attribute InventoryService
-- tags it with rather than by name — the same selector SellDialogue uses.
local function heldFruit(): (Tool?, string?)
	local character = player.Character
	if not character then
		return nil, nil
	end

	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			local fruitName = child:GetAttribute(FRUIT_ATTRIBUTE)
			if typeof(fruitName) == "string" then
				return child, fruitName :: string
			end
		end
	end
	return nil, nil
end

-- Produce does not stack, so one Tool is exactly one item and counting them is
-- the quantity. Both containers are searched because equipping moves a Tool
-- from the Backpack to the character — miss that and holding one of three
-- strawberries reports two.
local function countHeld(itemName: string): number
	local containers: { Instance } = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(containers, backpack)
	end
	if player.Character then
		table.insert(containers, player.Character)
	end

	local count = 0
	for _, container in ipairs(containers) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute(FRUIT_ATTRIBUTE) == itemName then
				count += 1
			end
		end
	end
	return count
end

local function build(): Card
	local gui = Instance.new("ScreenGui")
	gui.Name = "FruitInspector"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(230, 93)
	-- Above the hotbar, clear of the sell dialogue in the centre.
	panel.Position = UDim2.new(0.5, 0, 1, -108)
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = panel

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 1
	title.Size = UDim2.new(1, 0, 0, 22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 17
	title.TextColor3 = Color3.fromRGB(240, 240, 245)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = ""
	title.Parent = panel

	-- Its own line rather than a suffix on the title, so the colour has room to
	-- do the work: the band is meant to be recognised before it is read.
	local band = Instance.new("TextLabel")
	band.LayoutOrder = 2
	band.Size = UDim2.new(1, 0, 0, 15)
	band.BackgroundTransparency = 1
	band.Font = Enum.Font.GothamBold
	band.TextSize = 12
	band.TextXAlignment = Enum.TextXAlignment.Left
	band.Text = ""
	band.Parent = panel

	local detail = Instance.new("TextLabel")
	detail.LayoutOrder = 3
	detail.Size = UDim2.new(1, 0, 0, 32)
	detail.BackgroundTransparency = 1
	detail.Font = Enum.Font.Gotham
	detail.TextSize = 14
	detail.TextColor3 = Color3.fromRGB(196, 200, 210)
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextYAlignment = Enum.TextYAlignment.Top
	detail.RichText = true
	detail.Text = ""
	detail.Parent = panel

	return { gui = gui, title = title, band = band, detail = detail }
end

local function refresh()
	local shown = card
	if not shown then
		return
	end

	local tool, fruitName = heldFruit()
	if not (tool and fruitName) then
		shown.gui.Enabled = false
		return
	end

	local price = Produce.price(fruitName)
	local count = countHeld(fruitName)

	-- An item nothing knows about has no band to show. That is the same item
	-- Produce prices at zero, so the card stays honest about both at once.
	local spec = Produce.spec(fruitName)
	local tier = if spec then spec.Rarity else 0

	-- Named for display, so a product out of a levelled machine says so. Two
	-- Strawberry Pies at two prices are the one thing a bare name cannot tell
	-- apart, and this card exists to answer exactly that.
	shown.title.Text = Produce.displayName(fruitName)
	shown.band.Text = Rarity.name(tier):upper()
	shown.band.TextColor3 = Rarity.color(tier)
	shown.detail.Text = ("<b>%d</b> coins each\nCarrying %d — worth <b>%d</b> coins")
		:format(price, count, price * count)
	shown.gui.Enabled = true
end

function FruitInspector.start()
	card = build()

	local function watchContainer(container: Instance)
		container.ChildAdded:Connect(refresh)
		container.ChildRemoved:Connect(refresh)
	end

	-- Equipping moves the tool between the Backpack and the character, so both
	-- containers signal a change. The Backpack is replaced on respawn, hence
	-- re-attaching rather than binding once.
	player.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Backpack") then
			watchContainer(child)
			refresh()
		end
	end)

	player.CharacterAdded:Connect(function(character: Model)
		watchContainer(character)
		refresh()
	end)

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		watchContainer(backpack)
	end

	local character = player.Character
	if character then
		watchContainer(character)
	end

	-- Now that produce does not stack, every award and sale adds or removes a
	-- Tool, so the container signals above already cover quantity changes. The
	-- stat is kept as a backstop: it moves on every one of them, and it costs a
	-- single connection to be certain the card never shows a stale count.
	task.spawn(function()
		local stats = player:WaitForChild("leaderstats", 30)
		local fruitStat = stats and stats:WaitForChild("Fruit", 30)
		if fruitStat and fruitStat:IsA("IntValue") then
			fruitStat.Changed:Connect(refresh)
		end
	end)

	refresh()
end

return FruitInspector
