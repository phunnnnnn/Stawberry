--!strict

--[[
	Which cells of the factory zone a machine may be placed on.

	Shared for the same reason FarmSurface is: the client's placement indicator
	and the server's validation must snap to the *same* lattice, or the preview
	square will sit on a cell the server then refuses. Pure and stateless — the
	server is still the only thing that decides anything.
]]

local Config = require(script.Parent.Config)

local FactoryGrid = {}

-- Snaps a point to the centre of its grid cell on the zone's top face, or nil
-- if that cell is off the placeable area: on the underside or sides, or close
-- enough to the edge that the machine would overhang.
function FactoryGrid.project(zone: BasePart, position: Vector3): Vector3?
	local localPoint = zone.CFrame:PointToObjectSpace(position)
	local half = zone.Size / 2

	-- Reject the underside and the sides. The +1 tolerance lets a click land
	-- slightly above the surface, as a raycast hit does.
	if localPoint.Y <= 0 or localPoint.Y > half.Y + 1 then
		return nil
	end

	-- Cells are centred on the zone rather than on world origin, so moving or
	-- rotating the pad carries the lattice with it.
	local grid = Config.Factory.GridSize
	local snappedX = math.floor(localPoint.X / grid + 0.5) * grid
	local snappedZ = math.floor(localPoint.Z / grid + 0.5) * grid

	-- A machine fills its whole cell, so it is the cell that has to clear the
	-- margin, not the point the player happened to click.
	local reach = grid / 2 + Config.Factory.EdgeMargin
	if math.abs(snappedX) > half.X - reach or math.abs(snappedZ) > half.Z - reach then
		return nil
	end

	return zone.CFrame * Vector3.new(snappedX, half.Y, snappedZ)
end

-- The zone's rotation with no translation, so callers can stand a machine or a
-- preview square square-on to the pad.
function FactoryGrid.orientation(zone: BasePart): CFrame
	return zone.CFrame.Rotation
end

-- True when `position` lands on a cell that is already taken. Everything passed
-- here has been through `project`, so cells either coincide or are a full
-- GridSize apart; the tolerance only absorbs float error in the CFrame round
-- trip.
function FactoryGrid.occupied(position: Vector3, taken: { Vector3 }): boolean
	local tolerance = Config.Factory.GridSize / 2
	for _, cell in ipairs(taken) do
		if (cell - position).Magnitude < tolerance then
			return true
		end
	end
	return false
end

return FactoryGrid
