--!strict

--[[
	Reports where the player clicked while holding a factory.

	The mirror image of PlantingController: it sends a raw click position and
	nothing else, and FactoryService snaps it to a cell and decides whether that
	cell is placeable. Snapping deliberately does *not* happen here — the server
	would redo it anyway, and a client that snapped differently would just make
	the two disagree.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local MouseTarget = require(script.Parent.MouseTarget)
local ToolWatcher = require(script.Parent.ToolWatcher)

local FactoryController = {}

function FactoryController.start()
	ToolWatcher.onActivated(Config.Factory.ToolName, function()
		local hit = MouseTarget.raycast()
		if not hit then
			print("[FactoryController] click hit nothing")
			return
		end

		print(("[FactoryController] click hit %s at %s")
			:format(hit.Instance:GetFullName(), tostring(hit.Position)))
		Remotes.event(Remotes.PLACE_FACTORY):FireServer(hit.Position)
	end)

	print("[FactoryController] watching for factory tools.")
end

return FactoryController
