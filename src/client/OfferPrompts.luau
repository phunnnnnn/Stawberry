--!strict

--[[
	Hides the prompts on offers that are not yours.

	Both shops deal per player now — a belt seed is rolled for one player and a
	generator offer stands in one player's slot — and a ProximityPrompt has no way
	to be shown to one client and not another. The server refuses a stranger's
	press either way; what it cannot do is stop five players seeing five prompts
	each and learning that four of them do nothing.

	So this is display-only, and deliberately so: it reads the same owner
	attribute the server checks, and turns `Enabled` off locally for the ones that
	are not the local player's. **Nothing here is a permission.** A tampered
	client can turn every prompt back on and will still be refused, because the
	check that matters is the one in `ConveyorService.collect` and
	`FactoryRngService.take`.

	It is safe to write `Enabled` here only because nothing on the server ever
	writes it on these two: a belt seed's prompt and an offer's Take prompt are
	created enabled and destroyed with the thing they sit on. The *placed*
	factory prompts are the opposite — `FactoryService.refreshPrompts` owns their
	Enabled outright — which is why they are left alone here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local OfferPrompts = {}

local player = Players.LocalPlayer

local FOLDER_TIMEOUT = 60

-- Every prompt under an offer, on or off together. An offer has one prompt
-- today; walking the descendants rather than naming it keeps this working if a
-- second is ever added, and costs nothing on a model this size.
local function setEnabled(offer: Instance, enabled: boolean)
	for _, descendant in ipairs(offer:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			descendant.Enabled = enabled
		end
	end
end

local function watch(offer: Instance, attribute: string)
	local function apply()
		setEnabled(offer, offer:GetAttribute(attribute) == player.UserId)
	end

	apply()

	-- The attribute is written before the instance is parented, so it arrives with
	-- it — but re-applying on both signals is a line each and means a change of
	-- owner, or a prompt built a frame late, cannot leave a stale state behind.
	offer:GetAttributeChangedSignal(attribute):Connect(apply)
	offer.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("ProximityPrompt") then
			descendant.Enabled = offer:GetAttribute(attribute) == player.UserId
		end
	end)
end

-- One folder of offers: everything already in it, and everything that lands in
-- it later. Waits rather than gives up, because the folder is created by the
-- server on start-up and may not exist when the client gets here.
local function watchFolder(folderName: string, attribute: string)
	local folder = Workspace:WaitForChild(folderName, FOLDER_TIMEOUT)
	if not folder then
		warn(("[OfferPrompts] Workspace.%s never arrived — offers from it will show their prompts to everyone.")
			:format(folderName))
		return
	end

	for _, child in ipairs(folder:GetChildren()) do
		watch(child, attribute)
	end
	folder.ChildAdded:Connect(function(child: Instance)
		watch(child, attribute)
	end)
end

function OfferPrompts.start()
	task.spawn(watchFolder, Config.Conveyor.SeedFolderName, Config.SeedRng.OwnerAttribute)
	task.spawn(watchFolder, Config.FactoryRng.FolderName, Config.FactoryRng.OwnerAttribute)
end

return OfferPrompts
