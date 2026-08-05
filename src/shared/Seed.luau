--!strict

--[[
	Placeholder seed, in two forms:
	  * `createPickup` — the ball that rides the conveyor belt.
	  * `createTool`   — the Backpack item granted on pickup. Equipping it is
	                     "holding" a seed; clicking the farm plants it.

	Both are code-generated rather than saved models so they stay in version
	control. Swap the bodies for mesh clones later without touching callers.
]]

local Config = require(script.Parent.Config)

local Seed = {}

local function styleBody(part: BasePart)
	part.Shape = Enum.PartType.Ball
	part.Size = Config.Seed.Size
	part.Color = Config.Seed.Color
	part.Material = Enum.Material.Grass
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

function Seed.createPickup(): BasePart
	local part = Instance.new("Part")
	part.Name = "Seed"
	styleBody(part)

	-- Movement is driven by the server each frame, so the seed is anchored and
	-- non-colliding: players walk through the stream instead of kicking seeds
	-- off the belt.
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PickupPrompt"
	prompt.ActionText = "Pick Up"
	prompt.ObjectText = "Seed"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.Seed.PickupRange
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	return part
end

function Seed.createTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = Config.Seed.ToolName
	tool.ToolTip = "Click the farm to plant"
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	-- Must be named "Handle" for RequiresHandle to find it.
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	styleBody(handle)
	handle.Massless = true
	handle.CanCollide = false
	handle.Parent = tool

	return tool
end

return Seed
