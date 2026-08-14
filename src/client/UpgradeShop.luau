--!strict

--[[
	The shop that sells generator levels: the belt's, and the factory pad's.

	Both shops deal out of a pool table, so the panel shows the same four things
	for each — what your current level deals, the odds it deals them at, what the
	next level would deal instead, and what that costs. **The whole of that is
	read out of `Config`**, which the client has as well: the pool the server
	rolls against *is* the pool drawn here, so the panel cannot advertise a row
	the generator will not deal. Only the player's own level comes from elsewhere,
	off an attribute the two RNG services publish.

	What it sends is a **track name and nothing else**. Level, price and
	affordability are all re-read server-side in `UpgradeService`; the price on
	the button is a promise the server keeps because both sides read one Config,
	not because the client asked for it.

	The two cards are built from one description apiece and differ only in what a
	box is worth saying — a rarity band for the belt, a tier and level for the
	generator. A third shop would be a third entry in TRACKS.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local UpgradeShop = {}

local player = Players.LocalPlayer

type BoxLabel = {
	Text: string,
	Color: Color3,
}

type Track = {
	-- The string the server keys UpgradeService.TRACKS by. A wire contract, not
	-- display text.
	Key: string,
	Title: string,
	Blurb: string,
	-- Attribute this track's level is published on, on the Player.
	LevelAttribute: string,
	Costs: { number },
	Rows: number,
	Boxes: number,
	BoxRates: { number },
	RowWeights: { Current: number, Below: number, Above: number },
	-- What one box of one row says, and in what colour. The only thing the two
	-- tracks genuinely disagree about.
	describe: (row: number, box: number) -> BoxLabel,
}

type Card = {
	track: Track,
	levelLabel: TextLabel,
	rates: { TextLabel },
	names: { TextLabel },
	nextLabel: TextLabel,
	buyButton: TextButton,
}

type Result = {
	ok: boolean,
	level: number,
	spent: number,
	reason: string?,
}

local PANEL_WIDTH = 440
-- Tall enough for both cards without scrolling on a normal screen, and short
-- enough to fit a laptop's Studio viewport.
local PANEL_MAX_HEIGHT = 600
local PANEL_MIN_HEIGHT = 220
local VIEWPORT_MARGIN = 40
local TITLE_HEIGHT = 26
local CLOSE_HEIGHT = 30

local INK = Color3.fromRGB(240, 240, 245)
local MUTED = Color3.fromRGB(158, 160, 172)
local GOOD = Color3.fromRGB(58, 132, 74)
local DEAD = Color3.fromRGB(70, 70, 78)

local TRACKS: { Track } = {
	{
		Key = "Seed",
		Title = "Seed Belt",
		Blurb = "Which rarity band the belt rolls you.",
		LevelAttribute = Config.SeedRng.LevelAttribute,
		Costs = Config.SeedRng.UpgradeCosts,
		Rows = #Config.SeedRng.Pool,
		Boxes = #Config.SeedRng.BoxRates,
		BoxRates = Config.SeedRng.BoxRates,
		RowWeights = Config.SeedRng.RowWeights,
		describe = function(row: number, box: number): BoxLabel
			local band = Config.SeedRng.Pool[row][box]
			return { Text = Rarity.name(band), Color = Rarity.color(band) }
		end,
	},
	{
		Key = "Factory",
		Title = "Factory Generator",
		Blurb = "Which machine the pad deals you.",
		LevelAttribute = Config.FactoryRng.LevelAttribute,
		Costs = Config.FactoryRng.UpgradeCosts,
		Rows = #Config.FactoryRng.Pool,
		Boxes = #Config.FactoryRng.BoxRates,
		BoxRates = Config.FactoryRng.BoxRates,
		RowWeights = Config.FactoryRng.RowWeights,
		describe = function(row: number, box: number): BoxLabel
			local offer = Config.FactoryRng.Pool[row][box]
			-- Same colour the machine's own body wears, so a box in this list and a
			-- machine on the pad are recognisably the same tier.
			local color = Config.Factory.TierColors[offer.Tier] or Config.Factory.BodyColor
			return { Text = ("Tier %d · Lv %d"):format(offer.Tier, offer.Level), Color = color }
		end,
	},
}

local gui: ScreenGui
local toggleButton: TextButton
local panel: Frame
local coinsLabel: TextLabel
local statusLabel: TextLabel
local cards: { Card } = {}

local busy = false

--[[ Reading state ]]

-- Thousands separators. Upgrades run to six figures and an unpunctuated 150000
-- is a number nobody reads correctly at a glance.
local function comma(amount: number): string
	local text = tostring(math.floor(amount))
	local out = text
	while true do
		local replaced: number
		out, replaced = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return out
end

local function coins(): number
	local stats = player:FindFirstChild("leaderstats")
	local value = stats and stats:FindFirstChild("Coins")
	if value and value:IsA("IntValue") then
		return value.Value
	end
	return 0
end

-- The level the server published, clamped into the pool. Falls back to the
-- bottom row rather than nil: the panel is drawn before the attribute is
-- guaranteed to have arrived, and every track starts at level 1 anyway.
local function levelOf(track: Track): number
	local value = player:GetAttribute(track.LevelAttribute)
	if typeof(value) ~= "number" then
		return 1
	end
	return math.clamp(math.floor(value :: number), 1, track.Rows)
end

local function costOf(track: Track, level: number): number?
	if level >= track.Rows then
		return nil
	end
	return track.Costs[level]
end

--[[ Drawing ]]

local function refreshCard(card: Card)
	local track = card.track
	local level = levelOf(track)

	card.levelLabel.Text = ("Level %d / %d"):format(level, track.Rows)

	local total = 0
	for _, rate in ipairs(track.BoxRates) do
		total += rate
	end

	for box = 1, track.Boxes do
		local share = if total > 0 then track.BoxRates[box] / total * 100 else 0
		local label = track.describe(level, box)
		card.rates[box].Text = ("%d%%"):format(math.round(share))
		card.names[box].Text = label.Text
		card.names[box].TextColor3 = label.Color
	end

	if level < track.Rows then
		local ahead: { string } = {}
		for box = 1, track.Boxes do
			table.insert(ahead, track.describe(level + 1, box).Text)
		end
		-- Joined with a bar rather than a dot, because a factory box says "Tier 3 ·
		-- Lv 2" and a dot between boxes would read as part of the box before it.
		card.nextLabel.Text = ("Next: %s"):format(table.concat(ahead, "  |  "))
	else
		card.nextLabel.Text = "This is the highest level there is."
	end

	local cost = costOf(track, level)
	local affordable = cost ~= nil and coins() >= cost

	if not cost then
		card.buyButton.Text = "Maxed out"
	elseif affordable then
		card.buyButton.Text = ("Upgrade — %s coins"):format(comma(cost))
	else
		card.buyButton.Text = ("Upgrade — %s coins (short %s)")
			:format(comma(cost), comma(cost - coins()))
	end

	card.buyButton.Active = affordable and not busy
	card.buyButton.AutoButtonColor = card.buyButton.Active
	card.buyButton.BackgroundColor3 = if card.buyButton.Active then GOOD else DEAD
end

local function refresh()
	coinsLabel.Text = ("%s coins"):format(comma(coins()))
	for _, card in ipairs(cards) do
		refreshCard(card)
	end
end

local function buy(card: Card)
	if busy or not card.buyButton.Active then
		return
	end

	busy = true
	card.buyButton.Text = "Upgrading..."
	card.buyButton.Active = false

	local ok, response = pcall(function()
		return Remotes.func(Remotes.BUY_UPGRADE):InvokeServer(card.track.Key)
	end)

	busy = false
	local result = if ok and typeof(response) == "table" then response :: Result else nil

	if result and result.ok then
		statusLabel.TextColor3 = Color3.fromRGB(140, 200, 150)
		statusLabel.Text = ("%s is now level %d — %s coins spent.")
			:format(card.track.Title, result.level, comma(result.spent))
	else
		statusLabel.TextColor3 = Color3.fromRGB(210, 140, 140)
		statusLabel.Text = if result and result.reason
			then ("Not upgraded: %s."):format(result.reason)
			else "Upgrade failed. Please try again."
	end

	refresh()
end

--[[ Building ]]

local function label(parent: Instance, order: number, height: number, text: string): TextLabel
	local created = Instance.new("TextLabel")
	created.LayoutOrder = order
	created.Size = UDim2.new(1, 0, 0, height)
	created.BackgroundTransparency = 1
	created.Font = Enum.Font.Gotham
	created.TextSize = 14
	created.TextColor3 = MUTED
	created.TextXAlignment = Enum.TextXAlignment.Left
	created.Text = text
	created.Parent = parent
	return created
end

local function buildCard(parent: Instance, order: number, track: Track): Card
	local frame = Instance.new("Frame")
	frame.LayoutOrder = order
	-- Summed rather than eyeballed: padding, the four fixed rows, one row per box,
	-- and the gaps the list layout puts between them. A card that is short by a
	-- row clips its own Buy button, which is the one control that matters.
	frame.Size = UDim2.new(1, 0, 0, 138 + track.Boxes * 20)
	frame.BackgroundColor3 = Color3.fromRGB(38, 38, 46)
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame

	local title = label(frame, 1, 20, track.Title)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = INK

	local levelLabel = Instance.new("TextLabel")
	levelLabel.Size = UDim2.new(0, 90, 0, 20)
	levelLabel.Position = UDim2.new(1, 0, 0, 0)
	levelLabel.AnchorPoint = Vector2.new(1, 0)
	levelLabel.BackgroundTransparency = 1
	levelLabel.Font = Enum.Font.GothamBold
	levelLabel.TextSize = 14
	levelLabel.TextColor3 = INK
	levelLabel.TextXAlignment = Enum.TextXAlignment.Right
	levelLabel.Text = ""
	-- Parented to the title rather than the list, so it sits on the same line
	-- instead of taking a row of its own.
	levelLabel.Parent = title

	label(frame, 2, 16, track.Blurb).TextSize = 12

	local rates: { TextLabel } = {}
	local names: { TextLabel } = {}
	for box = 1, track.Boxes do
		local row = Instance.new("Frame")
		row.LayoutOrder = 2 + box
		row.Size = UDim2.new(1, 0, 0, 20)
		row.BackgroundTransparency = 1
		row.Parent = frame

		local rate = Instance.new("TextLabel")
		rate.Size = UDim2.new(0, 42, 1, 0)
		rate.BackgroundTransparency = 1
		rate.Font = Enum.Font.GothamMedium
		rate.TextSize = 13
		rate.TextColor3 = MUTED
		rate.TextXAlignment = Enum.TextXAlignment.Left
		rate.Text = ""
		rate.Parent = row

		local name = Instance.new("TextLabel")
		name.Size = UDim2.new(1, -42, 1, 0)
		name.Position = UDim2.fromOffset(42, 0)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.GothamMedium
		name.TextSize = 14
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Text = ""
		name.Parent = row

		table.insert(rates, rate)
		table.insert(names, name)
	end

	-- What the row weights actually mean, per track, rather than as a footnote
	-- shared by both: two shops that strayed at different rates would make one
	-- note a lie, and this is one label either way.
	local stray = label(frame, 3 + track.Boxes, 16, ("%d%% your level · %d%% one below · %d%% one above")
		:format(track.RowWeights.Current, track.RowWeights.Below, track.RowWeights.Above))
	stray.TextSize = 12
	stray.TextColor3 = Color3.fromRGB(120, 122, 134)

	local nextLabel = label(frame, 4 + track.Boxes, 18, "")
	nextLabel.TextSize = 13
	nextLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local buyButton = Instance.new("TextButton")
	buyButton.LayoutOrder = 5 + track.Boxes
	buyButton.Size = UDim2.new(1, 0, 0, 32)
	buyButton.BorderSizePixel = 0
	buyButton.Font = Enum.Font.GothamMedium
	buyButton.TextSize = 15
	buyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	buyButton.Text = ""
	buyButton.Parent = frame

	local buyCorner = Instance.new("UICorner")
	buyCorner.CornerRadius = UDim.new(0, 6)
	buyCorner.Parent = buyButton

	local card: Card = {
		track = track,
		levelLabel = levelLabel,
		rates = rates,
		names = names,
		nextLabel = nextLabel,
		buyButton = buyButton,
	}

	buyButton.MouseButton1Click:Connect(function()
		buy(card)
	end)

	return card
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "UpgradeShop"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	toggleButton = Instance.new("TextButton")
	toggleButton.Name = "Toggle"
	toggleButton.Size = UDim2.fromOffset(150, 34)
	toggleButton.Position = UDim2.new(0, 16, 1, -52)
	toggleButton.BackgroundColor3 = Color3.fromRGB(52, 52, 62)
	toggleButton.BorderSizePixel = 0
	toggleButton.Font = Enum.Font.GothamMedium
	toggleButton.TextSize = 14
	toggleButton.TextColor3 = INK
	toggleButton.Text = ("%s (%s)"):format(Config.Upgrades.ButtonText, Config.Upgrades.ToggleKey.Name)
	toggleButton.Parent = gui

	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(0, 6)
	toggleCorner.Parent = toggleButton

	panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_MAX_HEIGHT)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
	panel.BorderSizePixel = 0
	panel.Visible = false
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

	-- Title pinned to the top and Close pinned to the bottom, with the cards
	-- scrolling between them. Two cards plus their odds come to more than 500
	-- pixels, and on a short viewport a single list ran the title off the top and
	-- the Close button off the bottom — the one control a player needs to leave.
	local title = label(panel, 1, TITLE_HEIGHT, Config.Upgrades.Title)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = INK

	coinsLabel = Instance.new("TextLabel")
	coinsLabel.Size = UDim2.new(0, 160, 0, 26)
	coinsLabel.Position = UDim2.new(1, 0, 0, 0)
	coinsLabel.AnchorPoint = Vector2.new(1, 0)
	coinsLabel.BackgroundTransparency = 1
	coinsLabel.Font = Enum.Font.GothamBold
	coinsLabel.TextSize = 16
	coinsLabel.TextColor3 = Color3.fromRGB(238, 206, 108)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right
	coinsLabel.Text = ""
	coinsLabel.Parent = title

	local body = Instance.new("ScrollingFrame")
	body.Position = UDim2.fromOffset(0, TITLE_HEIGHT + 10)
	body.Size = UDim2.new(1, 0, 1, -(TITLE_HEIGHT + 10 + CLOSE_HEIGHT + 10))
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	-- Grown from the cards rather than measured: a sixth pool row or a fifth box
	-- makes the cards taller, and a hardcoded canvas would cut it off.
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.Parent = panel

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Padding = UDim.new(0, 10)
	bodyLayout.Parent = body

	for index, track in ipairs(TRACKS) do
		table.insert(cards, buildCard(body, index, track))
	end

	statusLabel = label(body, 1 + #TRACKS, 20, "")
	statusLabel.TextSize = 13
	statusLabel.TextWrapped = true

	local close = Instance.new("TextButton")
	close.Size = UDim2.new(1, 0, 0, CLOSE_HEIGHT)
	close.Position = UDim2.new(0, 0, 1, 0)
	close.AnchorPoint = Vector2.new(0, 1)
	close.BackgroundColor3 = Color3.fromRGB(52, 52, 60)
	close.BorderSizePixel = 0
	close.Font = Enum.Font.Gotham
	close.TextSize = 14
	close.TextColor3 = INK
	close.Text = "Close"
	close.Parent = panel

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = close

	close.MouseButton1Click:Connect(function()
		panel.Visible = false
	end)
end

-- The panel is as tall as it wants to be or as tall as there is room for,
-- whichever is less. Driven off the ScreenGui's own size rather than the
-- camera's viewport, so it accounts for the top inset the same way the panel is
-- laid out against it.
local function fit()
	local room = gui.AbsoluteSize.Y - VIEWPORT_MARGIN
	local height = math.clamp(room, PANEL_MIN_HEIGHT, PANEL_MAX_HEIGHT)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, height)
end

local function setOpen(open: boolean)
	if open then
		statusLabel.Text = ""
		refresh()
	end
	panel.Visible = open
end

--[[ Staying current ]]

-- Coins move on every sale and every purchase, and a level moves when one is
-- bought — including by something that is not this panel. Both are watched
-- rather than polled, and the panel is only redrawn while it is open.
local function watch()
	for _, track in ipairs(TRACKS) do
		player:GetAttributeChangedSignal(track.LevelAttribute):Connect(function()
			if panel.Visible then
				refresh()
			end
		end)
	end

	local stats = player:WaitForChild("leaderstats", 30)
	if not stats then
		return
	end
	local coinValue = stats:WaitForChild("Coins", 30)
	if coinValue and coinValue:IsA("IntValue") then
		coinValue.Changed:Connect(function()
			if panel.Visible then
				refresh()
			end
		end)
	end
end

function UpgradeShop.start()
	build()
	fit()
	refresh()

	-- Studio's viewport changes size as panels are dragged, and a phone rotates.
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)

	toggleButton.MouseButton1Click:Connect(function()
		setOpen(not panel.Visible)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		-- Ignored while the player is typing, which is what `processed` is for.
		if processed then
			return
		end
		if input.KeyCode == Config.Upgrades.ToggleKey then
			setOpen(not panel.Visible)
		end
	end)

	task.spawn(watch)
end

return UpgradeShop
