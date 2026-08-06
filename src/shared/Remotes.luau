--!strict

--[[
	Lazily creates (server) or waits for (client) the remotes under
	ReplicatedStorage.Remotes, so neither side depends on load order.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"
local WAIT_TIMEOUT = 30

local Remotes = {
	PLANT_SEED = "PlantSeed",
	PLACE_FACTORY = "PlaceFactory",
	SELL_FRUIT = "SellFruit",
}

local function container(): Instance
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			return existing
		end

		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
		return folder
	end

	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT)
	assert(folder, "[Remotes] ReplicatedStorage.Remotes never replicated")
	return folder
end

local function resolve(name: string, isEvent: boolean): Instance
	local folder = container()

	if RunService:IsServer() then
		local existing = folder:FindFirstChild(name)
		if existing then
			return existing
		end

		local remote: Instance = if isEvent then Instance.new("RemoteEvent") else Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
		return remote
	end

	local remote = folder:WaitForChild(name, WAIT_TIMEOUT)
	assert(remote, ("[Remotes] %s never replicated"):format(name))
	return remote
end

function Remotes.event(name: string): RemoteEvent
	return resolve(name, true) :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	return resolve(name, false) :: RemoteFunction
end

return Remotes
