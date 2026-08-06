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

function FactoryModel.create(): Model
	local cfg = Config.Factory

	local model = Instance.new("Model")
	model.Name = "Factory"

	local base = newPart("Base", model)
	base.Size = cfg.BaseSize
	base.Color = cfg.BaseColor
	base.Material = Enum.Material.Metal
	base.CFrame = CFrame.new(0, cfg.BaseSize.Y / 2, 0)

	local body = newPart("Body", model)
	body.Size = cfg.BodySize
	body.Color = cfg.BodyColor
	body.Material = Enum.Material.WoodPlanks
	body.CFrame = CFrame.new(0, cfg.BaseSize.Y + cfg.BodySize.Y / 2, 0)

	-- Holds whatever the machine currently contains. Invisible and
	-- non-colliding while empty; `showItem` gives it a body.
	local slot = newPart("Slot", model)
	slot.Size = Vector3.one
	slot.Material = Enum.Material.SmoothPlastic
	slot.Transparency = 1
	slot.CanCollide = false
	slot.CanTouch = false
	slot.CanQuery = false
	slot.CFrame = CFrame.new(0, cfg.BaseSize.Y + cfg.BodySize.Y + cfg.SlotOffset, 0)

	-- One prompt per end of the machine's cycle rather than one that rewrites
	-- itself. FactoryService enables exactly one at a time — insert while empty,
	-- neither while it works, collect once it is done — so a glance at a machine
	-- says what it wants without reading the text. They can share a key because
	-- they are never enabled together.
	local input = Instance.new("ProximityPrompt")
	input.Name = "InputPrompt"
	input.ActionText = "Insert Fruit"
	input.ObjectText = "Factory"
	input.HoldDuration = 0
	input.MaxActivationDistance = cfg.PromptRange
	input.RequiresLineOfSight = false
	input.Parent = body

	-- Hidden until there is something to collect, which is the state a machine
	-- is built in. Enabling it is FactoryService's job.
	local output = Instance.new("ProximityPrompt")
	output.Name = "OutputPrompt"
	output.ActionText = "Collect"
	output.ObjectText = "Factory"
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
	remove.ObjectText = "Factory"
	remove.KeyboardKeyCode = cfg.RemoveKey
	remove.HoldDuration = cfg.RemoveHoldDuration
	remove.MaxActivationDistance = cfg.PromptRange
	remove.RequiresLineOfSight = false
	remove.Enabled = cfg.CanRemove
	remove.Parent = body

	model.PrimaryPart = base
	return model
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
-- look comes from Produce, so what sits in the machine matches the stack Tool
-- the same item produces in the Backpack.
function FactoryModel.showItem(model: Model, itemName: string?)
	local slot = model:FindFirstChild("Slot")
	if not (slot and slot:IsA("BasePart")) then
		return
	end
	local part = slot :: BasePart

	if not itemName then
		part.Transparency = 1
		return
	end

	local spec = Produce.spec(itemName)
	if not spec then
		part.Transparency = 1
		return
	end

	part.Shape = spec.Shape
	part.Size = spec.Size
	part.Color = spec.Color
	part.Transparency = 0
end

return FactoryModel
