--!strict

--[[
	Ghost disc showing where an equipped seed will land.

	Feedback only — PlantingService still decides. The rules previewed here come
	from the same FarmSurface module the server validates with, and the aim comes
	from the same MouseTarget helper PlantingController fires with, so a green
	disc means that click really will plant.

	One rule is not previewed: the server's MaxPlantsPerPlayer cap, which the
	client has no way to read. Past the cap a green spot is still refused.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local FarmSurface = require(ReplicatedStorage.Shared.FarmSurface)
local PlantModel = require(ReplicatedStorage.Shared.PlantModel)

local MouseTarget = require(script.Parent.MouseTarget)

type Visuals = {
	container: Folder,
	marker: Part,
	spacing: Part?,
	reason: TextLabel?,
}

local PlantIndicator = {}

local player = Players.LocalPlayer
local style = Config.Indicator

local visuals: Visuals? = nil
local shown = false
local pad: BasePart? = nil

-- Footprints of existing plants, rebuilt when the Plants folder changes rather
-- than every frame.
local occupied: { Vector3 } = {}
local occupiedStale = true

local function newDisc(name: string, diameter: number, thickness: number, transparency: number, parent: Folder): Part
	local part = Instance.new("Part")
	part.Name = name
	-- A cylinder's circular faces are on its X axis, so X is the thickness.
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(thickness, diameter, diameter)
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	-- Without this the disc sits under the cursor and blocks its own raycast.
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function build(): Visuals
	local container = Instance.new("Folder")
	container.Name = "PlantIndicator"

	local marker = newDisc(
		"Marker",
		style.MarkerDiameter,
		style.MarkerThickness,
		style.MarkerTransparency,
		container
	)

	local spacing: Part? = nil
	if style.ShowSpacing then
		spacing = newDisc(
			"Spacing",
			Config.Farm.MinPlantSpacing * 2,
			style.SpacingThickness,
			style.SpacingTransparency,
			container
		)
	end

	local reason: TextLabel? = nil
	if style.ShowReason then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Reason"
		billboard.Size = UDim2.fromOffset(240, 32)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, style.ReasonHeight, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = marker

		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.GothamMedium
		text.TextScaled = true
		text.TextStrokeTransparency = 0.4
		text.Text = ""
		text.Parent = billboard
		reason = text
	end

	return {
		container = container,
		marker = marker,
		spacing = spacing,
		reason = reason,
	}
end

local function farmPad(): BasePart?
	local cached = pad
	if cached and cached.Parent then
		return cached
	end

	-- Re-resolve rather than caching once: the pad can be replaced while the
	-- place is being edited in Studio.
	local found = Workspace:FindFirstChild(Config.Farm.PartName)
	if found and found:IsA("BasePart") then
		pad = found :: BasePart
		return pad
	end

	pad = nil
	return nil
end

local function heldSeed(): Tool?
	local character = player.Character
	if not character then
		return nil
	end

	-- A Tool parented to the character is the one being held, matching the
	-- check PlantingService makes.
	local tool = character:FindFirstChildOfClass("Tool")
	if tool and tool.Name == Config.Seed.ToolName then
		return tool
	end
	return nil
end

local function rebuildOccupied()
	local positions: { Vector3 } = {}

	local folder = Workspace:FindFirstChild(Config.Farm.PlantFolderName)
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") then
				local ground = PlantModel.groundOf(child)
				if ground then
					table.insert(positions, ground)
				end
			end
		end
	end

	occupied = positions
	occupiedStale = false
end

-- Where the disc belongs, and why the spot is refused. A nil position means the
-- cursor is not on the farm at all, so nothing should be drawn.
local function evaluate(surface: BasePart): (Vector3?, string?)
	local hit = MouseTarget.raycast()
	if not hit or hit.Instance ~= surface then
		return nil, nil
	end

	local point = FarmSurface.project(surface, hit.Position)
	if not point then
		-- On the pad but inside the edge margin. Draw at the raw hit so the
		-- player can see which edge they are fouling.
		return hit.Position, "Too close to the edge"
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if root and (root.Position - point).Magnitude > Config.Farm.MaxPlantDistance then
		return point, "Too far away"
	end

	if FarmSurface.tooClose(point, occupied) then
		return point, "Too close to another plant"
	end

	return point, nil
end

-- Lays a disc flat on the pad's top face. The pad's LookVector is the reference
-- up so the lookAt cannot degenerate on a level pad, and the quarter turn puts
-- the cylinder's X axis along the pad's normal.
local function discCFrame(surface: BasePart, point: Vector3): CFrame
	local aim = CFrame.lookAt(point, point + surface.CFrame.UpVector, surface.CFrame.LookVector)
	return aim * CFrame.Angles(0, math.rad(90), 0)
end

-- Parenting only on a state change keeps this off the per-frame path.
local function setShown(container: Folder, visible: boolean)
	if visible == shown then
		return
	end
	shown = visible
	container.Parent = if visible then Workspace else nil
end

local function update()
	local parts = visuals
	if not parts then
		return
	end

	local surface = farmPad()
	if not (surface and heldSeed()) then
		setShown(parts.container, false)
		return
	end

	if occupiedStale then
		rebuildOccupied()
	end

	local point, blocked = evaluate(surface)
	if not point then
		setShown(parts.container, false)
		return
	end

	local colour = if blocked then style.BlockedColor else style.ValidColor

	parts.marker.CFrame = discCFrame(surface, point + surface.CFrame.UpVector * style.HoverOffset)
	parts.marker.Color = colour

	local spacing = parts.spacing
	if spacing then
		-- Half the lift, so the wider disc never z-fights with the marker.
		local under = point + surface.CFrame.UpVector * (style.HoverOffset / 2)
		spacing.CFrame = discCFrame(surface, under)
		spacing.Color = colour
	end

	local reason = parts.reason
	if reason then
		reason.Text = blocked or ""
		reason.TextColor3 = colour
	end

	setShown(parts.container, true)
end

function PlantIndicator.start()
	visuals = build()

	local function watch(folder: Instance)
		folder.ChildAdded:Connect(function()
			occupiedStale = true
		end)
		folder.ChildRemoved:Connect(function()
			occupiedStale = true
		end)
		occupiedStale = true
	end

	-- The folder is created by PlantingService, so it may not exist yet.
	local plants = Workspace:FindFirstChild(Config.Farm.PlantFolderName)
	if plants then
		watch(plants)
	else
		local connection: RBXScriptConnection
		connection = Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == Config.Farm.PlantFolderName then
				connection:Disconnect()
				watch(child)
			end
		end)
	end

	RunService.RenderStepped:Connect(update)
end

return PlantIndicator
