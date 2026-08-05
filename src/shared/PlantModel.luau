--!strict

--[[
	Builds placeholder plant and fruit geometry from a Config species entry.

	Plants are built with their base at the model's origin. `PrimaryPart` is the
	stem, whose centre sits at StemHeight/2 above that base — `place` accounts
	for the offset so callers pass a ground position and nothing else.
]]

local Config = require(script.Parent.Config)

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

function PlantModel.create(speciesName: string): Model?
	local spec = Config.Plants[speciesName]
	if not spec then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = speciesName

	local stem = newPart("Stem", model)
	stem.Size = Vector3.new(spec.StemThickness, spec.StemHeight, spec.StemThickness)
	stem.Color = spec.StemColor
	stem.Material = Enum.Material.Grass
	stem.CFrame = CFrame.new(0, spec.StemHeight / 2, 0)

	local leaves = newPart("Leaves", model)
	leaves.Size = spec.LeafSize
	leaves.Color = spec.LeafColor
	leaves.Material = Enum.Material.Grass
	leaves.CFrame = CFrame.new(0, spec.StemHeight, 0)

	model.PrimaryPart = stem
	return model
end

-- Moves a freshly built plant so its base rests on `groundPosition`.
function PlantModel.place(model: Model, groundPosition: Vector3)
	local spec = Config.Plants[model.Name]
	if not spec then
		return
	end
	model:PivotTo(CFrame.new(groundPosition + Vector3.new(0, spec.StemHeight / 2, 0)))
end

-- Inverse of `place`: the ground position a built plant is standing on. Lets
-- the client recover plant footprints from the replicated models.
function PlantModel.groundOf(model: Model): Vector3?
	local spec = Config.Plants[model.Name]
	if not spec then
		return nil
	end
	return model:GetPivot().Position - Vector3.new(0, spec.StemHeight / 2, 0)
end

-- World position a fruit should occupy for a plant based at `groundPosition`.
function PlantModel.fruitPosition(speciesName: string, groundPosition: Vector3): Vector3
	local spec = Config.Plants[speciesName]
	if not spec or not spec.Fruit then
		return groundPosition
	end
	return groundPosition + Vector3.new(0, spec.StemHeight + spec.Fruit.HeightOffset, 0)
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
