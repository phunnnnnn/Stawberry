--!strict

--[[
	Builds placeholder plant and fruit geometry from a Config species entry.

	A plant lives in two stages. It sprouts as the species' `Sprout` form at
	`Growth.StartScale` and is scaled up by PlantingService until it reaches
	`Growth.MatureScale`; `mature` then rebuilds the geometry as the `Mature`
	form — the plant's true form, and the only one that bears fruit.

	Parts are positioned in world space from the model's `Ground` attribute
	rather than by pivoting the model as a whole, because the offset between the
	base and the pivot changes as the plant scales. `groundOf` reads that
	attribute back, so a plant's footprint is the same number at every stage and
	at every scale.
]]

local Config = require(script.Parent.Config)

export type Stage = "Sprout" | "Mature"

local SPROUT: Stage = "Sprout"
local MATURE: Stage = "Mature"

local PlantModel = {}

local function newPart(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function stageOf(model: Model): Stage
	return if model:GetAttribute("Stage") == MATURE then MATURE else SPROUT
end

local function scaleOf(model: Model): number
	local value = model:GetAttribute("Scale")
	return if typeof(value) == "number" then value else 1
end

local function formOf(spec: Config.PlantSpec, stage: Stage): Config.FormSpec
	return if stage == MATURE then spec.Mature else spec.Sprout
end

-- Replaces the model's geometry with one form's parts. Anything that is not a
-- stage part is left alone — notably a ripe Fruit, which belongs to the plant
-- rather than to the form it is hanging on.
local function buildForm(model: Model, form: Config.FormSpec)
	for _, child in ipairs(model:GetChildren()) do
		if child.Name == "Stem" or child.Name == "Leaves" or child.Name == "Crown" then
			child:Destroy()
		end
	end

	local stem = newPart("Stem", model)
	stem.Color = form.StemColor
	stem.Material = Enum.Material.Grass

	local leaves = newPart("Leaves", model)
	leaves.Color = form.LeafColor
	leaves.Material = Enum.Material.Grass

	if form.CrownSize and form.CrownColor then
		local crown = newPart("Crown", model)
		crown.Color = form.CrownColor
		crown.Material = Enum.Material.SmoothPlastic
	end

	model.PrimaryPart = stem
end

-- Sizes and positions the current parts for one form at one scale, standing on
-- `ground`. Everything is derived from the spec each time rather than stepped
-- from the last frame's values, so repeated calls cannot accumulate drift.
local function layout(model: Model, form: Config.FormSpec, scale: number, ground: Vector3)
	local height = form.StemHeight * scale

	local stem = model:FindFirstChild("Stem")
	if stem and stem:IsA("BasePart") then
		local thickness = form.StemThickness * scale
		stem.Size = Vector3.new(thickness, height, thickness)
		stem.CFrame = CFrame.new(ground + Vector3.new(0, height / 2, 0))
	end

	local leafSize = form.LeafSize * scale
	local leaves = model:FindFirstChild("Leaves")
	if leaves and leaves:IsA("BasePart") then
		leaves.Size = leafSize
		leaves.CFrame = CFrame.new(ground + Vector3.new(0, height, 0))
	end

	local crown = model:FindFirstChild("Crown")
	if crown and crown:IsA("BasePart") and form.CrownSize then
		local crownSize = form.CrownSize * scale
		crown.Size = crownSize
		crown.CFrame = CFrame.new(ground + Vector3.new(0, height + (leafSize.Y + crownSize.Y) / 2, 0))
	end
end

-- Where a built plant is standing. The attribute is authoritative because the
-- pivot moves as the plant grows; the fallback covers a model that predates it.
function PlantModel.groundOf(model: Model): Vector3?
	local stored = model:GetAttribute("Ground")
	if typeof(stored) == "Vector3" then
		return stored :: Vector3
	end

	local spec = Config.Plants[model.Name]
	if not spec then
		return nil
	end
	-- The pivot is the stem's centre, so half the stem's *current* height is the
	-- distance down to the ground.
	local height = formOf(spec, stageOf(model)).StemHeight * scaleOf(model)
	return model:GetPivot().Position - Vector3.new(0, height / 2, 0)
end

function PlantModel.create(speciesName: string): Model?
	local spec = Config.Plants[speciesName]
	if not spec then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = speciesName
	model:SetAttribute("Stage", SPROUT)
	model:SetAttribute("Scale", spec.Growth.StartScale)

	buildForm(model, spec.Sprout)
	-- Stood at the origin until `place` says where the ground is.
	layout(model, spec.Sprout, spec.Growth.StartScale, Vector3.zero)

	return model
end

-- Moves a plant so its base rests on `groundPosition`.
function PlantModel.place(model: Model, groundPosition: Vector3)
	local spec = Config.Plants[model.Name]
	if not spec then
		return
	end
	model:SetAttribute("Ground", groundPosition)
	layout(model, formOf(spec, stageOf(model)), scaleOf(model), groundPosition)
end

-- Resizes a growing plant in place. Scaling the sprout is the whole of growth
-- until it hits the limit, so this runs every frame for every immature plant.
function PlantModel.setScale(model: Model, scale: number)
	local spec = Config.Plants[model.Name]
	local ground = PlantModel.groundOf(model)
	if not (spec and ground) then
		return
	end
	model:SetAttribute("Scale", scale)
	layout(model, formOf(spec, stageOf(model)), scale, ground)
end

function PlantModel.isMature(model: Model): boolean
	return stageOf(model) == MATURE
end

-- Swaps a fully grown sprout for the species' true form, at full size. Callers
-- gate fruit on this: a sprout bears nothing.
function PlantModel.mature(model: Model)
	local spec = Config.Plants[model.Name]
	local ground = PlantModel.groundOf(model)
	if not (spec and ground) then
		return
	end

	model:SetAttribute("Stage", MATURE)
	model:SetAttribute("Scale", 1)
	buildForm(model, spec.Mature)
	layout(model, spec.Mature, 1, ground)
end

-- World position a fruit should occupy for a plant based at `groundPosition`.
-- Measured against the true form, which is the only one that fruits.
function PlantModel.fruitPosition(speciesName: string, groundPosition: Vector3): Vector3
	local spec = Config.Plants[speciesName]
	if not spec or not spec.Fruit then
		return groundPosition
	end
	return groundPosition + Vector3.new(0, spec.Mature.StemHeight + spec.Fruit.HeightOffset, 0)
end

function PlantModel.createFruit(fruitSpec: Config.FruitSpec): BasePart
	local part = Instance.new("Part")
	part.Name = "Fruit"
	part.Shape = Enum.PartType.Ball
	part.Size = fruitSpec.Size
	part.Color = fruitSpec.Color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HarvestPrompt"
	prompt.ActionText = "Harvest"
	prompt.ObjectText = fruitSpec.Name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = fruitSpec.PickupRange
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	return part
end

return PlantModel
