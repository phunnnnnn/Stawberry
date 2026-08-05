--!strict

--[[
	Sell dialogue, opened by the Seller's proximity prompt.

	The prompt lives on the server-created part, but Triggered also fires
	locally, so the dialogue opens without a round trip. The sale itself is a
	server call — this UI only displays what the server reports back.
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
local sellButton: TextButton

local busy = false

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

local function refresh()
	local count = fruitCount()
	local price = unitPrice()

	fruitLabel.Text = ("Fruit: %d    Value: %d coins"):format(count, count * price)
	sellButton.Text = if count > 0 then ("Sell All (%d)"):format(count) else "Nothing to sell"
	sellButton.AutoButtonColor = count > 0
	sellButton.BackgroundColor3 = if count > 0
		then Color3.fromRGB(58, 132, 74)
		else Color3.fromRGB(70, 70, 78)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "SellDialogue"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(340, 190)
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

	sellButton = Instance.new("TextButton")
	sellButton.LayoutOrder = 4
	sellButton.Size = UDim2.new(1, 0, 0, 38)
	sellButton.BorderSizePixel = 0
	sellButton.Font = Enum.Font.GothamMedium
	sellButton.TextSize = 16
	sellButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	sellButton.Text = "Sell All"
	sellButton.Parent = panel

	local sellCorner = Instance.new("UICorner")
	sellCorner.CornerRadius = UDim.new(0, 6)
	sellCorner.Parent = sellButton

	local closeButton = Instance.new("TextButton")
	closeButton.LayoutOrder = 5
	closeButton.Size = UDim2.new(1, 0, 0, 30)
	closeButton.BorderSizePixel = 0
	closeButton.BackgroundColor3 = Color3.fromRGB(52, 52, 60)
	closeButton.Font = Enum.Font.Gotham
	closeButton.TextSize = 14
	closeButton.TextColor3 = Color3.fromRGB(215, 215, 225)
	closeButton.Text = "Close"
	closeButton.Parent = panel

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = closeButton

	closeButton.MouseButton1Click:Connect(function()
		gui.Enabled = false
	end)

	sellButton.MouseButton1Click:Connect(function()
		if busy or fruitCount() == 0 then
			return
		end
		busy = true
		sellButton.Text = "Selling..."

		local ok, result = pcall(function()
			return Remotes.func(Remotes.SELL_FRUIT):InvokeServer()
		end)

		busy = false

		local sale = if ok and typeof(result) == "table" then result :: { sold: number, earned: number } else nil

		if sale and sale.sold > 0 then
			statusLabel.TextColor3 = Color3.fromRGB(140, 200, 150)
			statusLabel.Text = ("Sold %d for %d coins."):format(sale.sold, sale.earned)
		else
			statusLabel.TextColor3 = Color3.fromRGB(210, 140, 140)
			statusLabel.Text = "Sale failed — move closer to the seller."
		end

		refresh()
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
		warn("[SellDialogue] SellPrompt missing — is SellService running?")
		return
	end

	prompt.Triggered:Connect(function()
		statusLabel.Text = ""
		refresh()
		gui.Enabled = true
	end)
end

return SellDialogue
