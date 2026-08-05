--!strict

--[[
	Sell dialogue, opened by the Seller's proximity prompt.

	The client chooses one of three actions: sell every harvested fruit, sell
	one unit of the fruit stack currently equipped, or close the dialogue. The
	server validates distance, ownership, quantity, and price before payout.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local SellDialogue = {}

local player = Players.LocalPlayer

local gui: ScreenGui
local fruitLabel: TextLabel
local statusLabel: TextLabel
local sellAllButton: TextButton
local sellHeldButton: TextButton

local busy = false

type SaleResponse = {
	sold: number,
	earned: number,
	itemName: string?,
	reason: string?,
}

local function fruitCount(): number
	local stats = player:FindFirstChild("leaderstats")
	local fruit = stats and stats:FindFirstChild("Fruit")
	if fruit and fruit:IsA("IntValue") then
		return fruit.Value
	end
	return 0
end

local function unitPrice(): number
	local spec = Config.Plants[Config.DefaultSpecies]
	local fruitSpec = spec and spec.Fruit
	return if fruitSpec then fruitSpec.SellPrice else 0
end

local function heldFruitName(): string?
	local character = player.Character
	if not character then
		return nil
	end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			local fruitName = child:GetAttribute("FruitName")
			if typeof(fruitName) == "string" then
				return fruitName
			end
		end
	end
	return nil
end

local function refresh()
	local count = fruitCount()
	local price = unitPrice()
	local held = heldFruitName()

	fruitLabel.Text = ("Fruit: %d    Value: %d coins"):format(count, count * price)

	sellAllButton.Text = if count > 0 then ("Sell All (%d)"):format(count) else "Sell All (Nothing to sell)"
	sellAllButton.Active = count > 0
	sellAllButton.AutoButtonColor = count > 0
	sellAllButton.BackgroundColor3 = if count > 0
		then Color3.fromRGB(58, 132, 74)
		else Color3.fromRGB(70, 70, 78)

	sellHeldButton.Text = if held
		then ("Sell Thing That I Hold (%s)"):format(held)
		else "Sell Thing That I Hold"
	sellHeldButton.Active = held ~= nil
	sellHeldButton.AutoButtonColor = held ~= nil
	sellHeldButton.BackgroundColor3 = if held
		then Color3.fromRGB(63, 105, 166)
		else Color3.fromRGB(70, 70, 78)
end

local function requestSale(mode: string, button: TextButton)
	if busy or not button.Active then
		return
	end
	busy = true
	button.Text = "Selling..."

	local ok, result = pcall(function()
		return Remotes.func(Remotes.SELL_FRUIT):InvokeServer(mode)
	end)

	busy = false
	local sale = if ok and typeof(result) == "table" then result :: SaleResponse else nil

	if sale and sale.sold > 0 then
		statusLabel.TextColor3 = Color3.fromRGB(140, 200, 150)
		if sale.itemName then
			statusLabel.Text = ("Sold 1 %s for %d coins."):format(sale.itemName, sale.earned)
		else
			statusLabel.Text = ("Sold %d fruit for %d coins."):format(sale.sold, sale.earned)
		end
	else
		statusLabel.TextColor3 = Color3.fromRGB(210, 140, 140)
		statusLabel.Text = if sale and sale.reason then sale.reason else "Sale failed. Please try again."
	end

	refresh()
end

local function makeButton(parent: Instance, order: number, text: string, height: number): TextButton
	local button = Instance.new("TextButton")
	button.LayoutOrder = order
	button.Size = UDim2.new(1, 0, 0, height)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 16
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Text = text
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	return button
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "SellDialogue"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(360, 300)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 16)
	padding.PaddingBottom = UDim.new(0, 16)
	padding.PaddingLeft = UDim.new(0, 18)
	padding.PaddingRight = UDim.new(0, 18)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = panel

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 1
	title.Size = UDim2.new(1, 0, 0, 26)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(240, 240, 245)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Seller"
	title.Parent = panel

	fruitLabel = Instance.new("TextLabel")
	fruitLabel.LayoutOrder = 2
	fruitLabel.Size = UDim2.new(1, 0, 0, 22)
	fruitLabel.BackgroundTransparency = 1
	fruitLabel.Font = Enum.Font.Gotham
	fruitLabel.TextSize = 15
	fruitLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	fruitLabel.TextXAlignment = Enum.TextXAlignment.Left
	fruitLabel.Text = ""
	fruitLabel.Parent = panel

	statusLabel = Instance.new("TextLabel")
	statusLabel.LayoutOrder = 3
	statusLabel.Size = UDim2.new(1, 0, 0, 20)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 14
	statusLabel.TextColor3 = Color3.fromRGB(140, 200, 150)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Text = ""
	statusLabel.Parent = panel

	sellAllButton = makeButton(panel, 4, "Sell All", 38)
	sellHeldButton = makeButton(panel, 5, "Sell Thing That I Hold", 38)
	local nevermindButton = makeButton(panel, 6, "Nevermind", 30)
	nevermindButton.BackgroundColor3 = Color3.fromRGB(52, 52, 60)
	nevermindButton.Font = Enum.Font.Gotham
	nevermindButton.TextSize = 14

	nevermindButton.MouseButton1Click:Connect(function()
		gui.Enabled = false
	end)

	sellAllButton.MouseButton1Click:Connect(function()
		requestSale("all", sellAllButton)
	end)

	sellHeldButton.MouseButton1Click:Connect(function()
		requestSale("held", sellHeldButton)
	end)
end

local function watchFruitStat()
	local stats = player:WaitForChild("leaderstats", 30)
	if not stats then
		return
	end
	local fruit = stats:WaitForChild("Fruit", 30)
	if fruit and fruit:IsA("IntValue") then
		fruit.Changed:Connect(function()
			if gui.Enabled then
				refresh()
			end
		end)
	end
end

function SellDialogue.start()
	build()
	task.spawn(watchFruitStat)

	local stall = Workspace:WaitForChild(Config.Seller.PartName, 30)
	if not stall then
		warn(("[SellDialogue] Workspace.%s never arrived."):format(Config.Seller.PartName))
		return
	end

	local prompt = stall:WaitForChild("SellPrompt", 30)
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		warn("[SellDialogue] SellPrompt missing - is SellService running?")
		return
	end

	prompt.Triggered:Connect(function()
		statusLabel.Text = ""
		refresh()
		gui.Enabled = true
	end)
end

return SellDialogue
