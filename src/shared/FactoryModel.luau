--!strict

--[[
	Builds the factory machine's geometry.

	Like PlantModel, the machine is built with its base at the model's origin and
	`PrimaryPart` is the base slab, whose centre sits half its height above that.
	`place` accounts for the offset so callers pass a ground CFrame and nothing
	else, and `groundOf` is its inverse so the client can recover a machine's
	cell from the replicated model.

	The Slot is the machine's entire interface: whatever is inside it sits there
	in plain sight, so there is no GUI to open and no state to read off a label.

	**A machine's tier has to be readable from outside**, because five of them
	stand side by side on the same pad and putting a Cake into the wrong one is
	the mistake the whole ladder invites. It is said three ways: the body colour
	(at a distance), a row of pips you can count (up close), and the prompts'
	own ObjectText (once you are in range to press anything). The tier is also
	written to an attribute, which is what the client reads — never the colour.

	**Level is a second number that matters just as much**, so it gets its own
	row of pips on the back edge in its own colour, and its own place in the
	prompt text. Two rows rather than one longer row: tier and level are not the
	same quantity, and a single row of pips would have to be counted twice and
	split in the middle to be read at all. Level has no colour of its own — the
	body already means tier, and a body that meant both would mean neither.

	`createOffer` builds the same machine with a single Take prompt instead of the
	three working ones. That is what stands on the generator pad, and it is
	deliberately the real geometry rather than a token: what you see on the pad is
	exactly what you will be placing.
]]

local Config = require(script.Parent.Config)
local Produce = require(script.Parent.Produce)

local FactoryModel = {}

local function newPart(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Clamped rather than trusted: a tier past the end of the palette gets the
-- fallback colour instead of erroring in the middle of building a machine.
local function bodyColorFor(tier: number): Color3
	local palette = Config.Factory.TierColors
	return palette[tier] or Config.Factory.BodyColor
end

-- Studs from the model's own origin up to the top of the body — where a pip
-- sits, and where an item in the slot rests.
local function roofHeight(): number
	return Config.Factory.BaseSize.Y + Config.Factory.BodySize.Y
end

-- One pip per unit, in a row along one edge of the roof and centred on it, so
-- three pips read as three whatever the machine is made of. `inset` picks the
-- edge: negative is the front (tier), positive the back (level).
local function addPipRow(model: Model, prefix: string, count: number, color: Color3, inset: number)
	local cfg = Config.Factory
	local top = roofHeight()

	for index = 1, count do
		local pip = newPart(("%s%d"):format(prefix, index), model)
		pip.Size = cfg.PipSize
		pip.Color = color
		pip.Material = Enum.Material.Neon
		pip.CanCollide = false
		pip.CanTouch = false
		pip.CanQuery = false

		local offset = (index - (count + 1) / 2) * cfg.PipSpacing
		pip.CFrame = CFrame.new(offset, top + cfg.PipSize.Y / 2, inset)
	end
end

-- How a machine says what it is, on every prompt it carries. One string built in
-- one place, so the three prompts on a machine and the one on an offer cannot
-- describe it differently.
function FactoryModel.describe(tier: number, level: number): string
	return ("Tier %d · Lv %d Factory"):format(tier, level)
end

-- Everything a machine is made of except its prompts: the real geometry, shared
-- by a placed machine and by the offer standing on the generator pad.
--
-- The body comes back alongside the model because it is what every prompt hangs
-- off, and looking it up again by name would be a nil check on a part this
-- function just created.
local function buildMachine(tier: number, level: number): (Model, BasePart)
	local cfg = Config.Factory

	local model = Instance.new("Model")
	model.Name = FactoryModel.describe(tier, level)
	model:SetAttribute(cfg.TierAttribute, tier)
	model:SetAttribute(cfg.LevelAttribute, level)

	local base = newPart("Base", model)
	base.Size = cfg.BaseSize
	base.Color = cfg.BaseColor
	base.Material = Enum.Material.Metal
	base.CFrame = CFrame.new(0, cfg.BaseSize.Y / 2, 0)

	local body = newPart("Body", model)
	body.Size = cfg.BodySize
	body.Color = bodyColorFor(tier)
	body.Material = Enum.Material.WoodPlanks
	body.CFrame = CFrame.new(0, cfg.BaseSize.Y + cfg.BodySize.Y / 2, 0)

	addPipRow(model, "Pip", tier, cfg.PipColor, -cfg.PipInset)
	addPipRow(model, "LevelPip", level, cfg.LevelPipColor, cfg.PipInset)

	-- Holds whatever the machine currently contains. Invisible and
	-- non-colliding while empty; `showItem` gives it a body and stands it on
	-- the roof.
	local slot = newPart("Slot", model)
	slot.Size = Vector3.one
	slot.Material = Enum.Material.SmoothPlastic
	slot.Transparency = 1
	slot.CanCollide = false
	slot.CanTouch = false
	slot.CanQuery = false
	slot.CFrame = CFrame.new(0, roofHeight() + cfg.SlotOffset + 0.5, 0)

	model.PrimaryPart = base
	return model, body
end

function FactoryModel.create(tier: number, level: number): Model
	local cfg = Config.Factory

	local model, body = buildMachine(tier, level)

	local objectText = FactoryModel.describe(tier, level)

	-- One prompt per end of the machine's cycle rather than one that rewrites
	-- itself. FactoryService enables exactly one at a time — insert while empty,
	-- neither while it works, collect once it is done — so a glance at a machine
	-- says what it wants without reading the text. They can share a key because
	-- they are never enabled together.
	local input = Instance.new("ProximityPrompt")
	input.Name = "InputPrompt"
	input.ActionText = "Insert"
	input.ObjectText = objectText
	input.HoldDuration = 0
	input.MaxActivationDistance = cfg.PromptRange
	input.RequiresLineOfSight = false
	input.Parent = body

	-- Hidden until there is something to collect, which is the state a machine
	-- is built in. Enabling it is FactoryService's job.
	local output = Instance.new("ProximityPrompt")
	output.Name = "OutputPrompt"
	output.ActionText = "Collect"
	output.ObjectText = objectText
	output.HoldDuration = 0
	output.MaxActivationDistance = cfg.PromptRange
	output.RequiresLineOfSight = false
	output.Enabled = false
	output.Parent = body

	-- Separate key and a hold, so taking the machine back can never happen by
	-- accident while tapping E to run it. Built either way and hidden when
	-- Config.Factory.CanRemove is off, so turning pick-up back on is one flag
	-- rather than a change here and a matching one in FactoryService.
	local remove = Instance.new("ProximityPrompt")
	remove.Name = "RemovePrompt"
	remove.ActionText = "Pick Up"
	remove.ObjectText = objectText
	remove.KeyboardKeyCode = cfg.RemoveKey
	remove.HoldDuration = cfg.RemoveHoldDuration
	remove.MaxActivationDistance = cfg.PromptRange
	remove.RequiresLineOfSight = false
	remove.Enabled = cfg.CanRemove
	remove.Parent = body

	return model
end

-- The machine as it stands on the generator pad: identical geometry, one Take
-- prompt, and none of the three working ones. Built from the same builder on
-- purpose — an offer that only approximated the machine would be advertising
-- something other than what it hands over.
--
-- The prompt is returned rather than looked up again by the caller, so the one
-- thing an offer can do is wired to the one thing that built it.
function FactoryModel.createOffer(tier: number, level: number): (Model, ProximityPrompt)
	local model, body = buildMachine(tier, level)

	local take = Instance.new("ProximityPrompt")
	take.Name = "TakePrompt"
	take.ActionText = "Take"
	take.ObjectText = FactoryModel.describe(tier, level)
	take.HoldDuration = 0
	take.MaxActivationDistance = Config.FactoryRng.PromptRange
	take.RequiresLineOfSight = false
	take.Parent = body

	return model, take
end

-- Which tier a built machine is, straight off the attribute. The client reads
-- this rather than inferring anything from the body colour or the pip count,
-- both of which are presentation.
function FactoryModel.tierOf(model: Model): number
	local tier = model:GetAttribute(Config.Factory.TierAttribute)
	return if typeof(tier) == "number" then tier :: number else 1
end

-- Which level a built machine is, straight off its own attribute. Never counted
-- off the back row of pips, which is presentation the same way the body colour
-- is.
function FactoryModel.levelOf(model: Model): number
	local level = model:GetAttribute(Config.Factory.LevelAttribute)
	return if typeof(level) == "number" then level :: number else 1
end

-- Stands a freshly built machine on `ground`, which carries the zone's rotation
-- so the machine lines up with the pad rather than with world axes.
function FactoryModel.place(model: Model, ground: CFrame)
	model:PivotTo(ground * CFrame.new(0, Config.Factory.BaseSize.Y / 2, 0))
end

-- Inverse of `place`: the cell centre a built machine is standing on. Lets the
-- client recover occupied cells from the replicated models.
function FactoryModel.groundOf(model: Model): Vector3
	return (model:GetPivot() * CFrame.new(0, -Config.Factory.BaseSize.Y / 2, 0)).Position
end

-- Puts an item on display in the slot, or clears it when `itemName` is nil. The
-- look comes from Produce, so what sits in the machine matches the Tool the
-- same item produces in the Backpack.
--
-- The slot is re-*positioned* as well as resized, because an item's height now
-- says which tier it is: a Masterpiece is four times a Pie, and a fixed centre
-- offset would bury the tall ones in the roof and float the short ones. Resting
-- everything on the roof by its underside makes the height difference the thing
-- you actually see.
function FactoryModel.showItem(model: Model, itemName: string?)
	local slot = model:FindFirstChild("Slot")
	if not (slot and slot:IsA("BasePart")) then
		return
	end
	local part = slot :: BasePart

	local spec = if itemName then Produce.spec(itemName) else nil
	if not spec then
		part.Transparency = 1
		return
	end

	part.Shape = spec.Shape
	part.Size = spec.Size
	part.Color = spec.Color
	part.Transparency = 0

	-- Measured from where the machine stands rather than from the slot's current
	-- CFrame, so repeated calls cannot walk the item up off the roof — the same
	-- anti-drift rule PlantModel.layout follows.
	local ground = FactoryModel.groundOf(model)
	part.CFrame = CFrame.new(
		ground.X,
		ground.Y + roofHeight() + Config.Factory.SlotOffset + spec.Size.Y / 2,
		ground.Z
	)
end

return FactoryModel
