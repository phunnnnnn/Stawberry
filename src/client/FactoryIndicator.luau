--!strict

--[[
	Ghost square showing which grid cell an equipped factory will land on.

	Snap-to-grid is invisible without it: the machine does not go where you
	clicked, it goes to the middle of the cell you clicked in, and there is no
	way to tell those apart until it is already placed.

	Feedback only — FactoryService still decides. The cell previewed here is the
	one FactoryGrid.project returns for the server too, and the aim comes from
	the same MouseTarget helper FactoryController fires with, so a green square
	means that click really will place there.

	The square also names the tier *and level* it is about to place, which matters
	more than it sounds: the hotbar can hold several machines that differ only by
	level, they look alike from above, and level is the whole of what a machine is
	worth. Putting the wrong one down costs a cell and a pick-up.

	Two rules are not previewed, because the client has no way to read either:
	the server's MaxPlaced cap and the remaining unplaced stock.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local FactoryGrid = require(ReplicatedStorage.Shared.FactoryGrid)
local FactoryModel = require(ReplicatedStorage.Shared.FactoryModel)

local MouseTarget = require(script.Parent.MouseTarget)

type Visuals = {
	container: Folder,
	marker: Part,
	reason: TextLabel?,
}

local FactoryIndicator = {}

local player = Players.LocalPlayer
local style = Config.Indicator

local visuals: Visuals? = nil
local shown = false
local zone: BasePart? = nil

-- Cells of existing machines, rebuilt when the Factories folder changes rather
-- than every frame.
local occupied: { Vector3 } = {}
local occupiedStale = true

local function build(): Visuals
	local container = Instance.new("Folder")
	container.Name = "FactoryIndicator"

	local marker = Instance.new("Part")
	marker.Name = "Cell"
	-- A flat slab covering the whole cell, so the square you see is the exact
	-- footprint the machine will take.
	marker.Size = Vector3.new(Config.Factory.GridSize, style.MarkerThickness, Config.Factory.GridSize)
	marker.Material = Enum.Material.Neon
	marker.Transparency = style.MarkerTransparency
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	-- Without this the square sits under the cursor and blocks its own raycast.
	marker.CanQuery = false
	marker.CastShadow = false
	marker.Parent = container

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

	return { container = container, marker = marker, reason = reason }
end

local function factoryZone(): BasePart?
	local cached = zone
	if cached and cached.Parent then
		return cached
	end

	-- Re-resolve rather than caching once: the pad can be replaced while the
	-- place is being edited in Studio.
	local found = Workspace:FindFirstChild(Config.Factory.ZoneName)
	if found and found:IsA("BasePart") then
		zone = found :: BasePart
		return zone
	end

	zone = nil
	return nil
end

-- The equipped factory Tool and the machine it places, or nil for neither.
--
-- Matched on the attributes rather than the name, the same check FactoryService
-- makes: a name is a label, and both numbers have to come from the same place
-- the server will read them from or the preview can promise the wrong machine.
local function heldFactory(): (Tool?, number?, number?)
	local character = player.Character
	if not character then
		return nil, nil
	end

	local tool = character:FindFirstChildOfClass("Tool")
	if not tool then
		return nil, nil, nil
	end

	local tier = tool:GetAttribute(Config.Factory.TierAttribute)
	local level = tool:GetAttribute(Config.Factory.LevelAttribute)
	if typeof(tier) ~= "number" or typeof(level) ~= "number" then
		return nil, nil, nil
	end
	return tool, tier :: number, level :: number
end

local function rebuildOccupied()
	local cells: { Vector3 } = {}

	local folder = Workspace:FindFirstChild(Config.Factory.FolderName)
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") then
				table.insert(cells, FactoryModel.groundOf(child))
			end
		end
	end

	occupied = cells
	occupiedStale = false
end

-- Where the square belongs, and why the cell is refused. A nil position means
-- the cursor is not on the zone at all, so nothing should be drawn.
local function evaluate(pad: BasePart): (Vector3?, string?)
	local hit = MouseTarget.raycast()
	if not hit or hit.Instance ~= pad then
		return nil, nil
	end

	local cell = FactoryGrid.project(pad, hit.Position)
	if not cell then
		-- On the pad but in a cell that would overhang the edge. Draw at the raw
		-- hit so the player can see which edge they are fouling.
		return hit.Position, "Too close to the edge"
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if root and (root.Position - cell).Magnitude > Config.Factory.MaxPlaceDistance then
		return cell, "Too far away"
	end

	if FactoryGrid.occupied(cell, occupied) then
		return cell, "Cell already taken"
	end

	return cell, nil
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

	local pad = factoryZone()
	local _, tier, level = heldFactory()
	if not (pad and tier and level) then
		setShown(parts.container, false)
		return
	end

	if occupiedStale then
		rebuildOccupied()
	end

	local cell, blocked = evaluate(pad)
	if not cell then
		setShown(parts.container, false)
		return
	end

	local colour = if blocked then style.BlockedColor else style.ValidColor

	-- Squared up with the pad, so the preview lines up with the lattice the
	-- machines actually sit on.
	parts.marker.CFrame = CFrame.new(cell + pad.CFrame.UpVector * style.HoverOffset)
		* FactoryGrid.orientation(pad)
	parts.marker.Color = colour

	-- Names the machine when the cell is free, rather than going blank. Every
	-- square looks alike otherwise, and a hotbar full of machines that differ only
	-- by level makes "which one is this" worth answering before the click rather
	-- than after.
	local reason = parts.reason
	if reason then
		reason.Text = blocked or ("Tier %d · Lv %d"):format(tier, level)
		reason.TextColor3 = colour
	end

	setShown(parts.container, true)
end

function FactoryIndicator.start()
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

	-- The folder is created by FactoryService, so it may not exist yet.
	local placed = Workspace:FindFirstChild(Config.Factory.FolderName)
	if placed then
		watch(placed)
	else
		local connection: RBXScriptConnection
		connection = Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == Config.Factory.FolderName then
				connection:Disconnect()
				watch(child)
			end
		end)
	end

	RunService.RenderStepped:Connect(update)
end

return FactoryIndicator
