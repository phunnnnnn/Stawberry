--!strict

--[[
	Reports where the player clicked while holding a factory.

	The mirror image of PlantingController: it sends a raw click position and
	nothing else, and FactoryService snaps it to a cell and decides whether that
	cell is placeable. Snapping deliberately does *not* happen here — the server
	would redo it anyway, and a client that snapped differently would just make
	the two disagree.

	Which *tier* is placed is not sent either. The server reads it off the Tool it
	can see the player holding, the same way PlantingController leaves the species
	to the seed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local MouseTarget = require(script.Parent.MouseTarget)
local ToolWatcher = require(script.Parent.ToolWatcher)

local FactoryController = {}

function FactoryController.start()
	-- Bound to the attribute, not the name: there is one Tool per tier and they
	-- all place when clicked.
	ToolWatcher.onActivatedAttribute(Config.Factory.TierAttribute, function(tool: Tool)
		local hit = MouseTarget.raycast()
		if not hit then
			print("[FactoryController] click hit nothing")
			return
		end

		print(("[FactoryController] %s click hit %s at %s")
			:format(tool.Name, hit.Instance:GetFullName(), tostring(hit.Position)))
		Remotes.event(Remotes.PLACE_FACTORY):FireServer(hit.Position)
	end)

	print("[FactoryController] watching for factory tools.")
end

return FactoryController
