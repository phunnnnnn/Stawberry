--!strict

--[[
	The world point under the cursor.

	Shared by PlantingController and PlantIndicator so the preview disc sits on
	exactly the position a click reports — two separate raycasts could disagree
	and show green on a spot the server then refuses.

	Existing plants and belt seeds are excluded so you can aim "through" them
	onto the farm pad. The indicator's own discs set CanQuery = false, so they
	are skipped without needing to be listed here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local RAY_LENGTH = 500

local MouseTarget = {}

local player = Players.LocalPlayer
local mouse = player:GetMouse()

function MouseTarget.raycast(): RaycastResult?
	local ignored: { Instance } = {}
	if player.Character then
		table.insert(ignored, player.Character)
	end

	local plants = Workspace:FindFirstChild(Config.Farm.PlantFolderName)
	if plants then
		table.insert(ignored, plants)
	end

	local beltSeeds = Workspace:FindFirstChild(Config.Conveyor.SeedFolderName)
	if beltSeeds then
		table.insert(ignored, beltSeeds)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignored
	params.IgnoreWater = true

	-- UnitRay rather than ViewportPointToRay(mouse.X, mouse.Y): it is already the
	-- ray through the cursor, so there is no viewport/GUI-inset conversion to get
	-- wrong. The old pairing may or may not have been off by the topbar inset —
	-- this way the question cannot arise.
	local ray = mouse.UnitRay
	return Workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
end

return MouseTarget
