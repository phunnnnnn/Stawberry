--!strict

--[[
	Price card shown while a fruit is held.

	Equipping a fruit is how you inspect it before selling: the card names it,
	gives the unit price, and totals what you are carrying of that species. Prices
	come from Config.Plants — the same table SellService charges against — so the
	number quoted here is the number you get paid.

	Display only. Nothing here can change a sale.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

type Card = {
	gui: ScreenGui,
	title: TextLabel,
	detail: TextLabel,
}

local FruitInspector = {}

local player = Players.LocalPlayer

-- Must match the attribute names InventoryService tags the stack Tool with.
local FRUIT_ATTRIBUTE = "FruitName"
local COUNT_ATTRIBUTE = "FruitCount"

local prices: { [string]: number } = {}
local card: Card? = nil

local function indexPrices()
	for _, spec in pairs(Config.Plants) do
		local fruitSpec = spec.Fruit
		if fruitSpec then
			prices[fruitSpec.Name] = fruitSpec.SellPrice
		end
	end
end

-- The equipped fruit stack Tool, identified by the attribute InventoryService
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

-- Quantity comes off the Tool's replicated attribute. Counting Tools would give
-- 1 every time: there is one stack Tool per species, not one per fruit.
local function countHeld(tool: Tool): number
	local count = tool:GetAttribute(COUNT_ATTRIBUTE)
	if typeof(count) == "number" then
		return math.max(0, math.floor(count :: number))
	end
	return 0
end

local function build(): Card
	local gui = Instance.new("ScreenGui")
	gui.Name = "FruitInspector"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(230, 74)
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

	local detail = Instance.new("TextLabel")
	detail.LayoutOrder = 2
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

	return { gui = gui, title = title, detail = detail }
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

	local price = prices[fruitName] or 0
	local count = countHeld(tool)

	shown.title.Text = fruitName
	shown.detail.Text = ("<b>%d</b> coins each\nCarrying %d — worth <b>%d</b> coins")
		:format(price, count, price * count)
	shown.gui.Enabled = true
end

function FruitInspector.start()
	indexPrices()
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

	-- Harvesting more of a species you already hold updates the existing Tool's
	-- attribute rather than adding one, so no container signal fires. The fruit
	-- stat moves on every award and sale, which makes it the reliable trigger.
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
