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
local Seed = require(ReplicatedStorage.Shared.Seed)

local MouseTarget = require(script.Parent.MouseTarget)
local ToolWatcher = require(script.Parent.ToolWatcher)

local PlantingController = {}

function PlantingController.start()
	-- Bound to the attribute, not the name: seeds are typed, so "Apple Seed"
	-- and "Coconut Seed" are different Tools doing the same thing. The species
	-- is not sent — the server reads it off the Tool it can see the player
	-- holding, which is the only copy it would trust anyway.
	ToolWatcher.onActivatedAttribute(Config.Seed.SpeciesAttribute, function(tool: Tool)
		local hit = MouseTarget.raycast()
		if not hit then
			-- Cursor was over empty sky: there is nothing to report.
			print("[PlantingController] click hit nothing")
			return
		end

		print(("[PlantingController] %s click hit %s at %s")
			:format(Seed.speciesOf(tool) or "untyped", hit.Instance:GetFullName(), tostring(hit.Position)))
		Remotes.event(Remotes.PLANT_SEED):FireServer(hit.Position)
	end)

	print("[PlantingController] watching for seed tools.")
end

return PlantingController
