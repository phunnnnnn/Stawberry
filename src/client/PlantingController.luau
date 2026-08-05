--!strict

--[[
	Reports where the player clicked while holding a seed.

	This sends a position and nothing else — PlantingService decides whether the
	point is plantable. The aim comes from MouseTarget, which PlantIndicator also
	uses, so the preview disc and the click agree on the spot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local MouseTarget = require(script.Parent.MouseTarget)

local PlantingController = {}

local player = Players.LocalPlayer

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

	tool.Destroying:Connect(function()
		watched[tool] = nil
	end)
end

function PlantingController.start()
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

	-- Respawning replaces the Backpack, so binding to whichever one exists at
	-- startup stops working the first time the player dies: seeds land in a
	-- Backpack nobody is watching and clicks do nothing, silently. Re-attach on
	-- every new one instead. The character is watched for the same reason — an
	-- equipped tool lives there, not in the Backpack.
	player.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Backpack") then
			watchContainer(child)
		end
	end)
	player.CharacterAdded:Connect(watchContainer)

	local backpack = player:WaitForChild("Backpack", 30)
	if backpack then
		watchContainer(backpack)
	else
		warn("[PlantingController] Backpack never arrived.")
	end

	local character = player.Character
	if character then
		watchContainer(character)
	end

	print("[PlantingController] watching for seed tools.")
end

return PlantingController
