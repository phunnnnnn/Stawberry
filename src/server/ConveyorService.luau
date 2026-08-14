--!strict

--[[
	Spawns seeds at one end of Workspace.Conveyor, slides them down the middle
	of it to the other end, and sells them to players through a proximity
	prompt.

	The belt is the shop. Each seed is rolled from the catalogue, so all eighteen
	species come past in one queue, and each carries its own price — so what
	arrives next is luck and what you take is a decision. A seed nobody can
	afford simply rides off the end.

	**Each seed is rolled for one player, and only they can buy it.** Whose turn
	it is and what their level deals are both `SeedRngService`'s to answer;
	nothing here knows a band or a weight. What this service owns is the seed
	itself, which is why the ownership check lives at the prompt: the id is
	written onto the part when it spawns and re-read when E is pressed, the same
	selector-not-proof split every attribute in this codebase makes.

	A seed rolled for a player who has since left simply rides off the end
	unbought. Destroying it early would pop a seed out of the stream mid-belt for
	everyone watching, to save a few seconds of a lane nobody was going to use.

	One lane, down the centreline: the stream is a single file rather than a
	scatter, so the seed under the prompt is unambiguous and the one behind it
	is readable while you decide.

	Seed positions are computed in the belt's *local* space, so the whole rig
	can be moved or rotated in Studio and the flow follows it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Seed = require(ReplicatedStorage.Shared.Seed)

local InventoryService = require(script.Parent.InventoryService)
local SeedRngService = require(script.Parent.SeedRngService)

type SeedRecord = {
	part: BasePart,
	species: string,
	-- Who this seed was rolled for. Held on the record *and* written to the part:
	-- the record is what the prompt checks, the attribute is what the client reads
	-- to stop showing you prompts you cannot press.
	owner: Player,
	offset: number, -- position along the belt's local Z axis
	claimed: boolean,
}

local ConveyorService = {}

local belt: BasePart? = nil
local seedFolder: Folder? = nil

-- Belt-local geometry, resolved once in `start`.
local entryOffset = 0
local exitOffset = 0
local surfaceOffset = 0

local seeds: { SeedRecord } = {}
local spawnClock = 0
local started = false

local function cframeFor(record: SeedRecord): CFrame
	local activeBelt = belt
	if not activeBelt then
		return CFrame.new()
	end

	-- Dead centre of the belt: the lateral term is zero rather than absent, so
	-- the one place a seed's position is computed still shows all three axes.
	return activeBelt.CFrame
		* CFrame.new(0, surfaceOffset, record.offset)
		* CFrame.Angles(record.offset * Config.Conveyor.SpinRate, 0, 0)
end

local function collect(player: Player, record: SeedRecord)
	-- Guard against the prompt firing twice before the record is reaped.
	if record.claimed then
		return
	end

	-- Prompts are visible to everyone the client has not hidden them from, so this
	-- is the check that makes a seed one player's rather than a race. Refused the
	-- same way as an unaffordable one: the seed keeps riding, for its owner.
	if player ~= record.owner then
		if Config.Conveyor.LogPurchases then
			warn(("[ConveyorService] %s tried to buy %s, which was rolled for %s")
				:format(player.Name, record.part.Name, record.owner.Name))
		end
		return
	end

	-- Refused — too poor, or no room. Leave the seed riding rather than destroying
	-- it: it is still theirs for the rest of the belt, so selling something or
	-- planting a seed is enough to come back for it, and nothing the player paid
	-- for has gone anywhere.
	local bought, reason = InventoryService.buySeed(player, record.species)
	if not bought then
		if Config.Conveyor.LogPurchases then
			-- Named by the part, not by the species, so a log line greps against
			-- what is actually in Workspace — and no article has to agree with
			-- eighteen species.
			warn(("[ConveyorService] %s could not buy %s: %s")
				:format(player.Name, record.part.Name, reason or "unknown"))
		end
		return
	end

	local label = record.part.Name
	record.claimed = true
	record.part:Destroy()

	if Config.Conveyor.LogPurchases then
		print(("[ConveyorService] %s bought %s for %d coins")
			:format(player.Name, label, Seed.price(record.species)))
	end
end

local function spawnSeed()
	-- Whose turn it is, and what their own belt level deals them. Nil when there
	-- is nobody in the server to roll for, in which case nothing spawns — a seed
	-- with no owner is one nobody could buy.
	local deal = SeedRngService.deal()
	if not deal then
		return
	end

	local part = Seed.createPickup(deal.species)
	part:SetAttribute(Config.SeedRng.OwnerAttribute, deal.player.UserId)

	local record: SeedRecord = {
		part = part,
		species = deal.species,
		owner = deal.player,
		offset = entryOffset,
		claimed = false,
	}

	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Triggered:Connect(function(player: Player)
			collect(player, record)
		end)
	end

	part.CFrame = cframeFor(record)
	part.Parent = seedFolder
	table.insert(seeds, record)
end

local function reachedEnd(offset: number): boolean
	if Config.Conveyor.Direction > 0 then
		return offset >= exitOffset
	end
	return offset <= exitOffset
end

local function step(deltaTime: number)
	local cfg = Config.Conveyor
	local travel = cfg.Direction * cfg.Speed * deltaTime

	for index = #seeds, 1, -1 do
		local record = seeds[index]

		if record.claimed or record.part.Parent == nil then
			record.part:Destroy()
			table.remove(seeds, index)
			continue
		end

		record.offset += travel

		if reachedEnd(record.offset) then
			record.part:Destroy()
			table.remove(seeds, index)
			continue
		end

		record.part.CFrame = cframeFor(record)
	end

	spawnClock += deltaTime
	if spawnClock >= cfg.SpawnInterval then
		-- Subtract rather than zero so the spawn rate stays honest under lag.
		spawnClock -= cfg.SpawnInterval
		if #seeds < cfg.MaxActiveSeeds then
			spawnSeed()
		end
	end
end

function ConveyorService.start()
	if started then
		return
	end

	local model = workspace:FindFirstChild("Conveyor")
	if not model then
		warn("[ConveyorService] Workspace.Conveyor not found — conveyor disabled.")
		return
	end

	local found = model:FindFirstChild(Config.Conveyor.BeltName)
	if not (found and found:IsA("BasePart")) then
		warn(
			("[ConveyorService] Workspace.Conveyor.%s is not a BasePart — conveyor disabled.")
				:format(Config.Conveyor.BeltName)
		)
		return
	end

	local activeBelt = found :: BasePart
	if not activeBelt.Anchored then
		warn("[ConveyorService] Belt is unanchored; it will drift and take the seed stream with it.")
	end

	belt = activeBelt

	local halfLength = activeBelt.Size.Z / 2
	local direction = Config.Conveyor.Direction

	-- Enter at the trailing edge, leave at the leading edge.
	entryOffset = -direction * (halfLength - Config.Conveyor.EntryMargin)
	exitOffset = direction * halfLength
	surfaceOffset = activeBelt.Size.Y / 2 + Config.Seed.Size.Y / 2 + Config.Conveyor.HoverOffset

	local folder = workspace:FindFirstChild(Config.Conveyor.SeedFolderName)
	if not folder then
		local created = Instance.new("Folder")
		created.Name = Config.Conveyor.SeedFolderName
		created.Parent = workspace
		folder = created
	end
	seedFolder = folder :: Folder

	RunService.Heartbeat:Connect(step)
	started = true

	-- What each level deals is SeedRngService's to print; this line is the belt
	-- itself. One seed per interval is shared out among the players in the server,
	-- so what any one of them waits is that interval times the headcount.
	print(
		("[ConveyorService] Running on %s — %.1f studs/s, one seed every %.1fs, %d species for sale.")
			:format(
				activeBelt:GetFullName(),
				Config.Conveyor.Speed,
				Config.Conveyor.SpawnInterval,
				#Config.SpeciesOrder
			)
	)
end

return ConveyorService
