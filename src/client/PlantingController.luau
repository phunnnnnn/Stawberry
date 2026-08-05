--!strict

--[[
	Reports where the player clicked while holding a seed.

	This sends a position and nothing else — PlantingService decides whether the
	point is plantable. Existing plants and belt seeds are excluded from the
	raycast so you can click "through" them onto the farm pad.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local RAY_LENGTH = 500

local PlantingController = {}

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local function raycastFromMouse(): RaycastResult?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

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

	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	return Workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
end

-- Equipping moves a tool to the character and unequipping moves it back, so
-- ChildAdded fires repeatedly for the same tool. Without this set each cycle
-- would add another Activated connection and one click would plant twice.
local watched: { [Tool]: true } = {}

local function watchTool(tool: Tool)
	if tool.Name ~= Config.Seed.ToolName or watched[tool] then
		return
	end
	watched[tool] = true

	tool.Activated:Connect(function()
		local hit = raycastFromMouse()
		if hit then
			Remotes.event(Remotes.PLANT_SEED):FireServer(hit.Position)
		end
	end)

	tool.Destroying:Connect(function()
		watched[tool] = nil
	end)
end

function PlantingController.start()
	-- Seeds arrive in the Backpack, but an equipped tool moves to the
	-- character, so watch both containers.
	local function watchContainer(container: Instance)
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				watchTool(child)
			end
		end
		container.ChildAdded:Connect(function(child: Instance)
			if child:IsA("Tool") then
				watchTool(child)
			end
		end)
	end

	local backpack = player:WaitForChild("Backpack", 30)
	if backpack then
		watchContainer(backpack)
	else
		warn("[PlantingController] Backpack never arrived.")
	end
end

return PlantingController
