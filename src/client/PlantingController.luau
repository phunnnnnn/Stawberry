--!strict

--[[
	Reports where the player clicked while holding a seed.

	This sends a position and nothing else — PlantingService decides whether the
	point is plantable. The aim comes from MouseTarget, which PlantIndicator also
	uses, so the preview disc and the click agree on the spot.

	ToolWatcher owns the equip/respawn bookkeeping that decides *when* this runs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local MouseTarget = require(script.Parent.MouseTarget)
local ToolWatcher = require(script.Parent.ToolWatcher)

local PlantingController = {}

function PlantingController.start()
	ToolWatcher.onActivated(Config.Seed.ToolName, function()
		local hit = MouseTarget.raycast()
		if not hit then
			-- Cursor was over empty sky: there is nothing to report.
			print("[PlantingController] click hit nothing")
			return
		end

		print(("[PlantingController] click hit %s at %s")
			:format(hit.Instance:GetFullName(), tostring(hit.Position)))
		Remotes.event(Remotes.PLANT_SEED):FireServer(hit.Position)
	end)

	print("[PlantingController] watching for seed tools.")
end

return PlantingController
