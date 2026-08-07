--!strict

--[[
	A seed, in two forms:
	  * `createPickup` — the ball that rides the conveyor belt and is bought off
	                     it.
	  * `createTool`   — the Backpack item that purchase grants. Equipping it is
	                     "holding" a seed; clicking the farm plants it.

	**Seeds are typed.** Every seed names the species it grows, in the
	`SeedSpecies` attribute, and takes that species' colour so eighteen kinds
	read apart on a moving belt. The attribute is the selector and the Tool's
	name is display only — exactly the split `FruitName` makes for produce, and
	for the same reason: the server re-checks the species against Config.Plants
	before it plants anything.

	Prices are read from Produce rather than kept here, so the number the belt
	prompt quotes is the number the fruit will later sell for times one
	multiplier. A second copy would eventually advertise a price the server does
	not charge.

	**Seeds are also banded.** A species' rarity decides how often the belt deals
	it, so a seed says which band it is in twice over: the prompt names it, and
	anything above Common wears the band's colour as an outline. Both are read
	from the species through the Rarity module — there is no rarity attribute,
	because `SeedSpecies` already implies one and a second copy could disagree
	with it.

	Both forms are code-generated rather than saved models so they stay in
	version control. Swap the bodies for mesh clones later without touching
	callers.
]]

local Config = require(script.Parent.Config)
local Produce = require(script.Parent.Produce)
local Rarity = require(script.Parent.Rarity)

local Seed = {}

-- Falls back rather than erroring, so a caller with no species in hand — or one
-- naming a species that has since left the catalogue — still gets a real seed
-- instead of an untyped one that PlantingService would have to refuse.
local function resolve(speciesName: string?): string
	if speciesName and Config.Plants[speciesName] then
		return speciesName
	end
	return Config.DefaultSpecies
end

-- The fruit's own colour, darkened. A seed that took the colour raw would read
-- as the fruit lying on the belt.
local function colorFor(speciesName: string): Color3
	local spec = Config.Plants[speciesName]
	local fruit = spec and spec.Fruit
	if not fruit then
		return Config.Seed.Color
	end
	return fruit.Color:Lerp(Color3.new(0, 0, 0), Config.Seed.Darkness)
end

local function labelFor(speciesName: string): string
	return ("%s %s"):format(speciesName, Config.Seed.ToolName)
end

-- The belt's version of the label, with the band in front of it the way loot is
-- named everywhere: "Mythic Watermelon Seed". Only the belt uses it — the Tool
-- keeps the short name, because the hotbar has a slot's width to say it in and
-- the tooltip can carry the band instead.
local function offerFor(speciesName: string): string
	return ("%s %s"):format(Rarity.name(Rarity.ofSpecies(speciesName)), labelFor(speciesName))
end

local function styleBody(part: BasePart, speciesName: string)
	part.Shape = Enum.PartType.Ball
	part.Size = Config.Seed.Size
	part.Color = colorFor(speciesName)
	part.Material = Enum.Material.Grass
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

-- What a seed of this species costs off the belt. Derived from what the fruit
-- sells for, so the two can never drift apart; zero for a species that bears
-- nothing, which is therefore free.
function Seed.price(speciesName: string): number
	return math.ceil(Produce.price(speciesName) * Config.Seed.CostMultiplier)
end

-- The species a Tool plants, or nil if it is not a seed at all. This is the one
-- test for "is this a seed" — the Tool's name is a label, not a contract.
function Seed.speciesOf(tool: Tool): string?
	local speciesName = tool:GetAttribute(Config.Seed.SpeciesAttribute)
	if typeof(speciesName) ~= "string" then
		return nil
	end
	return speciesName :: string
end

-- A rarity outline on the ball, so a seed worth crossing the map for announces
-- itself at belt distance instead of only under the prompt. A Highlight rather
-- than a welded ring because the belt moves every seed by CFrame each frame and
-- a Highlight follows its adornee for free. The fill is left transparent: the
-- body colour is the *species*, and that rule is worth more than a tint.
local function outline(part: BasePart, tier: number)
	if tier < Config.Seed.OutlineFromRarity then
		return
	end

	local glow = Instance.new("Highlight")
	glow.Name = "RarityOutline"
	glow.Adornee = part
	glow.FillTransparency = 1
	glow.OutlineColor = Rarity.color(tier)
	glow.OutlineTransparency = 0
	-- Occluded, not AlwaysOnTop: a rare seed should be visible down the belt,
	-- not through the scenery between here and it.
	glow.DepthMode = Enum.HighlightDepthMode.Occluded
	glow.Parent = part
end

function Seed.createPickup(speciesName: string?): BasePart
	local resolved = resolve(speciesName)

	local part = Instance.new("Part")
	part.Name = offerFor(resolved)
	part:SetAttribute(Config.Seed.SpeciesAttribute, resolved)
	styleBody(part, resolved)

	-- Movement is driven by the server each frame, so the seed is anchored and
	-- non-colliding: players walk through the stream instead of kicking seeds
	-- off the belt.
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PickupPrompt"
	-- The price is on the prompt, so what pressing E costs is visible before it
	-- is pressed rather than only in the refusal afterwards.
	prompt.ActionText = ("Buy — %d coins"):format(Seed.price(resolved))
	prompt.ObjectText = offerFor(resolved)
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.Seed.PickupRange
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	outline(part, Rarity.ofSpecies(resolved))

	return part
end

function Seed.createTool(speciesName: string?): Tool
	local resolved = resolve(speciesName)

	local tool = Instance.new("Tool")
	tool.Name = labelFor(resolved)
	tool.ToolTip = ("%s — click the farm to plant a %s")
		:format(Rarity.name(Rarity.ofSpecies(resolved)), resolved)
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute(Config.Seed.SpeciesAttribute, resolved)

	-- Must be named "Handle" for RequiresHandle to find it.
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	styleBody(handle, resolved)
	handle.Massless = true
	handle.CanCollide = false
	handle.Parent = tool

	return tool
end

return Seed
