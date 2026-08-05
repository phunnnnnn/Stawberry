--!strict

--[[
	Which points on the farm pad may be planted on.

	Shared so the client's placement indicator and the server's validation apply
	the *same* rules. If these drifted apart the indicator would promise spots
	the server silently refuses. Pure and stateless — the server is still the
	only thing that decides anything.
]]

local Config = require(script.Parent.Config)

local FarmSurface = {}

-- Projects a point onto the pad's top face, or nil if it is off the plantable
-- area: inside the edge margin, or on the underside or sides.
function FarmSurface.project(pad: BasePart, position: Vector3): Vector3?
	local localPoint = pad.CFrame:PointToObjectSpace(position)
	local half = pad.Size / 2
	local margin = Config.Farm.EdgeMargin

	if math.abs(localPoint.X) > half.X - margin or math.abs(localPoint.Z) > half.Z - margin then
		return nil
	end

	-- Reject the underside and the sides. The +1 tolerance lets a click land
	-- slightly above the surface, as a raycast hit does.
	if localPoint.Y <= 0 or localPoint.Y > half.Y + 1 then
		return nil
	end

	return pad.CFrame * Vector3.new(localPoint.X, half.Y, localPoint.Z)
end

-- True when `position` sits within MinPlantSpacing of anything already planted.
function FarmSurface.tooClose(position: Vector3, occupied: { Vector3 }): boolean
	local minimum = Config.Farm.MinPlantSpacing
	for _, taken in ipairs(occupied) do
		if (taken - position).Magnitude < minimum then
			return true
		end
	end
	return false
end

return FarmSurface
