--!strict

--[[
	Standings board ranking every player by coins, fruit held alongside.

	Roblox's own player list already shows leaderstats; this is the always-visible
	version of the same two values, sorted, with the local player highlighted.
	Reads leaderstats straight off each Player — no remotes, nothing to authorise.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local Leaderboard = {}

local player = Players.LocalPlayer
local style = Config.Leaderboard

local rowHolder: Frame? = nil

local function statOf(target: Player, name: string): number
	local stats = target:FindFirstChild("leaderstats")
	local value = stats and stats:FindFirstChild(name)
	if value and value:IsA("IntValue") then
		return value.Value
	end
	return 0
end

local function newRow(index: number, target: Player, parent: Frame)
	local mine = target == player

	local row = Instance.new("Frame")
	row.LayoutOrder = index
	row.Size = UDim2.new(1, 0, 0, style.RowHeight)
	row.BackgroundColor3 = Color3.fromRGB(52, 84, 60)
	row.BackgroundTransparency = if mine then 0.35 else 1
	row.BorderSizePixel = 0
	row.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = row

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -84, 1, 0)
	name.Position = UDim2.fromOffset(6, 0)
	name.BackgroundTransparency = 1
	name.Font = if mine then Enum.Font.GothamBold else Enum.Font.Gotham
	name.TextSize = 13
	name.TextColor3 = Color3.fromRGB(232, 234, 240)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = ("%d. %s"):format(index, target.DisplayName)
	name.Parent = row

	local figures = Instance.new("TextLabel")
	figures.Size = UDim2.new(0, 78, 1, 0)
	figures.Position = UDim2.new(1, -78, 0, 0)
	figures.BackgroundTransparency = 1
	figures.Font = Enum.Font.GothamMedium
	figures.TextSize = 13
	figures.TextColor3 = Color3.fromRGB(246, 214, 120)
	figures.TextXAlignment = Enum.TextXAlignment.Right
	figures.Text = ("%d c   %d f"):format(statOf(target, "Coins"), statOf(target, "Fruit"))
	figures.Parent = row
end

local function refresh()
	local holder = rowHolder
	if not holder then
		return
	end

	for _, child in ipairs(holder:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local ranked = Players:GetPlayers()
	table.sort(ranked, function(a: Player, b: Player): boolean
		local coinsA, coinsB = statOf(a, "Coins"), statOf(b, "Coins")
		if coinsA ~= coinsB then
			return coinsA > coinsB
		end
		-- Stable tiebreak, so equal scores do not shuffle on every refresh.
		return a.Name < b.Name
	end)

	for index, target in ipairs(ranked) do
		if index > style.MaxRows then
			break
		end
		newRow(index, target, holder)
	end
end

local function build(): Frame
	local gui = Instance.new("ScreenGui")
	gui.Name = "Leaderboard"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(style.Width, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	-- Left side: Roblox's own player list owns the top right.
	panel.Position = UDim2.fromOffset(12, 12)
	panel.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = panel

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 0
	title.Size = UDim2.new(1, 0, 0, 22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextColor3 = Color3.fromRGB(240, 240, 245)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = style.Title
	title.Parent = panel

	local holder = Instance.new("Frame")
	holder.LayoutOrder = 1
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.BackgroundTransparency = 1
	holder.Parent = panel

	local rows = Instance.new("UIListLayout")
	rows.SortOrder = Enum.SortOrder.LayoutOrder
	rows.Padding = UDim.new(0, 2)
	rows.Parent = holder

	return holder
end

-- Any change to any player's stats reorders the board, so every IntValue is
-- watched — including ones that appear after the player joins.
local function watchPlayer(target: Player)
	task.spawn(function()
		local stats = target:WaitForChild("leaderstats", 30)
		if not stats then
			return
		end

		local function watchValue(value: Instance)
			if value:IsA("IntValue") then
				value.Changed:Connect(refresh)
			end
		end

		for _, value in ipairs(stats:GetChildren()) do
			watchValue(value)
		end
		stats.ChildAdded:Connect(watchValue)

		refresh()
	end)
end

function Leaderboard.start()
	rowHolder = build()

	for _, target in ipairs(Players:GetPlayers()) do
		watchPlayer(target)
	end

	Players.PlayerAdded:Connect(function(target: Player)
		watchPlayer(target)
		refresh()
	end)

	Players.PlayerRemoving:Connect(function()
		-- Deferred: the player is still in GetPlayers() while this fires.
		task.defer(refresh)
	end)

	refresh()
end

return Leaderboard
