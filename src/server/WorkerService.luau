--!strict

--[[
	Runs the NPC workers: each one harvests its owner's ripe fruit, carries it to
	one of the owner's factories, comes back for the finished product and walks it
	to the seller. The coins land on the owner.

	**A worker is a second actor on the same farm, not a second set of rules.** It
	never touches `records` in PlantingService or FactoryService and never writes a
	prompt's `Enabled`. Every commit goes through the same transition a player's
	prompt uses — takeFruit, beginCycle, endCycle — so a machine a worker loaded
	advertises itself exactly like one a player loaded, and neither can take the
	same fruit twice.

	**A worker carries exactly one item, in its hands, and it is not a second
	Backpack.** The fruit it picks never enters the owner's tally, so it does not
	count against Config.Inventory.MaxProduce and a worker keeps earning while its
	owner's Backpack is full. It also means the item is visible in the world for
	the whole trip: what the worker is holding *is* its state, the same way what
	sits in a factory's Slot is that machine's.

	Everything here is server-side. There is no remote, no client module and no
	dependency on the owner's character even existing — a worker spawned at join
	starts working before its owner has finished loading in.

	Movement is anchored and script-driven, like the belt seeds and for the same
	reasons (see WorkerModel). Two consequences worth knowing:

	  - There is no pathfinding. Workers walk straight lines across a flat map,
	    which is all this map needs.
	  - A worker's height comes from wherever it is walking *to*, not from a
	    raycast underneath it. The pads differ by a stud at most, so interpolating
	    between the surface it left and the surface it is heading for is
	    indistinguishable from following the ground, at no per-frame cost.

	The one thing a worker cannot do is hold two items, and that shapes the job
	priority: it will not pick a fruit up unless there is already somewhere to put
	it, because a worker holding a strawberry with every machine busy can only
	stand still or sell it raw. See `chooseJob`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Produce = require(ReplicatedStorage.Shared.Produce)
local WorkerModel = require(ReplicatedStorage.Shared.WorkerModel)

local FactoryService = require(script.Parent.FactoryService)
local PlantingService = require(script.Parent.PlantingService)
local SellService = require(script.Parent.SellService)

type JobKind = "Harvest" | "Insert" | "Collect" | "Sell"

type Job = {
	kind: JobKind,

	-- Where to stand, frozen when the job is chosen. Recomputing it as the worker
	-- approaches would let the destination drift with every step.
	stand: Vector3,

	-- What to turn towards on arrival.
	look: Vector3,

	-- The thing that has to still be in the world for the trip to be worth
	-- finishing. Checked while walking, so a worker does not cross the map to
	-- arrive at a fruit somebody else already picked.
	subject: Instance,

	-- Exactly one of these is set, according to `kind`.
	fruit: PlantingService.RipeFruit?,
	machine: FactoryService.MachineHandle?,
}

type WorkerRecord = {
	model: Model,
	owner: Player,

	-- Where it stands when there is nothing to do.
	post: Vector3,

	-- Authoritative position; the model mirrors it, never the other way round.
	position: Vector3,
	facing: Vector3,

	-- Accumulated from distance walked, so the legs stop when the worker does.
	walkPhase: number,

	-- Whether the pose has already been settled since the worker stopped. Without
	-- it a standing worker is frozen mid-stride.
	settled: boolean,

	-- The single item in its hands, if any.
	carrying: string?,
	-- When it picked that item up, for Config.Worker.RefineTimeout.
	holdSince: number,

	job: Job?,
	-- Pause at a stop, so work reads as work.
	waitUntil: number,
	-- Throttles decision-making; every decision rescans the owner's plants and
	-- machines, which is wasted effort at 60 Hz.
	thinkAt: number,
}

-- Targets already spoken for by another of the owner's workers, so two of them do
-- not walk to opposite ends of the farm for the same strawberry.
type Claims = {
	fruit: { [Instance]: boolean },
	machines: { [Instance]: boolean },
}

local WorkerService = {}

local zone: BasePart? = nil
local workerFolder: Folder? = nil

local workers: { WorkerRecord } = {}

-- Runs across every worker on the server, so posts are handed out without two
-- players' workers standing inside each other.
local postIndex = 0

local function log(message: string, ...: any)
	if Config.Worker.LogActions then
		print(("[WorkerService] " .. message):format(...))
	end
end

--[[ Geometry helpers ]]

-- The world-axis-aligned footprint of whatever the worker is walking up to.
local function footprintOf(thing: Instance): Vector3
	if thing:IsA("Model") then
		return thing:GetExtentsSize()
	end
	if thing:IsA("BasePart") then
		return thing.Size
	end
	return Vector3.zero
end

-- How far the target's own footprint reaches along `direction`. Exact for a box,
-- which is what everything here is, so a worker stops just clear of the thing it
-- is working on instead of clear of a circle drawn around it — the difference
-- between standing beside the seller's wall and standing fifteen studs off it.
local function reachAlong(size: Vector3, direction: Vector3): number
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-4 then
		return math.max(size.X, size.Z) / 2
	end
	local unit = flat.Unit

	local alongX = if math.abs(unit.X) > 1e-4 then (size.X / 2) / math.abs(unit.X) else math.huge
	local alongZ = if math.abs(unit.Z) > 1e-4 then (size.Z / 2) / math.abs(unit.Z) else math.huge
	return math.min(alongX, alongZ)
end

-- A spot to stand beside `target`, on the side the worker is already coming from
-- so it does not walk past its work and turn around.
local function standNear(from: Vector3, target: Vector3, thing: Instance): Vector3
	local away = Vector3.new(from.X - target.X, 0, from.Z - target.Z)
	local direction = if away.Magnitude > 1e-3 then away.Unit else Vector3.new(0, 0, 1)
	return target + direction * (reachAlong(footprintOf(thing), direction) + Config.Worker.StandClearance)
end

-- Where a fixture is standing, as opposed to where its centre is.
local function groundOf(part: BasePart): Vector3
	return part.Position - Vector3.new(0, part.Size.Y / 2, 0)
end

--[[ Pose and status ]]

local function pose(worker: WorkerRecord)
	WorkerModel.setPose(worker.model, worker.position, worker.facing, worker.walkPhase, worker.carrying ~= nil)
end

local function describe(worker: WorkerRecord): string
	local job = worker.job
	if job then
		if job.kind == "Harvest" then
			return ("Fetching %s"):format(if job.fruit then job.fruit.itemName else "fruit")
		elseif job.kind == "Insert" then
			return ("Loading %s"):format(worker.carrying or "fruit")
		elseif job.kind == "Collect" then
			return "Collecting"
		end
		return ("Selling %s"):format(worker.carrying or "produce")
	end

	if worker.carrying then
		return ("Holding %s"):format(worker.carrying)
	end
	return "Idle"
end

-- Only called when the job or the carried item changes: the text replicates to
-- every client, so rewriting it every frame would cost real bandwidth to say the
-- same thing.
local function refreshStatus(worker: WorkerRecord)
	WorkerModel.setStatus(worker.model, worker.owner.Name, describe(worker))
end

--[[ Walking ]]

-- Moves a worker one frame towards `destination` and keeps its pose in step.
-- Returns true once it has arrived.
--
-- The pose is rewritten only on frames where the worker actually moved, plus one
-- final frame to bring its legs together. A worker standing at its post rewriting
-- ten CFrames every frame would replicate all of them to every client to say
-- nothing at all.
local function advance(worker: WorkerRecord, destination: Vector3, deltaTime: number): boolean
	local delta = destination - worker.position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local distance = flat.Magnitude

	if distance > Config.Worker.ArriveDistance then
		local step = math.min(Config.Worker.WalkSpeed * deltaTime, distance)
		local direction = flat.Unit

		worker.facing = direction
		-- Height eases towards the destination's own surface at the same rate; see
		-- the header for why there is no raycast here.
		worker.position = worker.position
			+ direction * step
			+ Vector3.new(0, math.clamp(delta.Y, -step, step), 0)

		-- A full cycle is two steps, hence StepLength twice per 2*pi.
		worker.walkPhase = (worker.walkPhase + (step / Config.Worker.StepLength) * math.pi) % (math.pi * 2)
		worker.settled = false
		pose(worker)
		return false
	end

	if not worker.settled then
		worker.settled = true
		worker.walkPhase = 0
		worker.position = Vector3.new(worker.position.X, destination.Y, worker.position.Z)
		pose(worker)
	end
	return true
end

local function faceTowards(worker: WorkerRecord, target: Vector3)
	local delta = Vector3.new(target.X - worker.position.X, 0, target.Z - worker.position.Z)
	if delta.Magnitude > 1e-3 then
		worker.facing = delta.Unit
		pose(worker)
	end
end

--[[ Deciding what to do ]]

local function claimsFor(owner: Player, except: WorkerRecord): Claims
	local claims: Claims = { fruit = {}, machines = {} }

	for _, other in ipairs(workers) do
		local job = other.job
		if other.owner == owner and other ~= except and job then
			if job.fruit then
				claims.fruit[job.fruit.part] = true
			end
			if job.machine then
				claims.machines[job.machine.model] = true
			end
		end
	end

	return claims
end

local function sellJob(worker: WorkerRecord): Job?
	local stall = SellService.stall()
	if not stall then
		return nil
	end
	local ground = groundOf(stall)
	return {
		kind = "Sell",
		stand = standNear(worker.position, ground, stall),
		look = stall.Position,
		subject = stall,
	}
end

local function insertJob(worker: WorkerRecord, machine: FactoryService.MachineHandle): Job
	return {
		kind = "Insert",
		stand = standNear(worker.position, machine.position, machine.model),
		look = machine.position,
		subject = machine.model,
		machine = machine,
	}
end

--[[
	Picks the most valuable thing this worker could be doing, or nil to stand by.

	The order is deliberate, and the constraint driving it is that a worker has one
	pair of hands:

	  1. Carrying something a machine will take, and a machine is free -> load it.
	  2. Carrying something, everything is busy -> wait, but not forever.
	  3. Carrying something nothing will refine -> sell it.
	  4. Empty, a machine has a product waiting -> collect it. Finishing work the
	     owner has already paid a fruit for beats starting more.
	  5. Empty, fruit is ripe *and there is somewhere to put it* -> fetch it.

	Rule 5 is the important one. Fetching a fruit with every machine busy strands
	the worker holding it: it cannot collect the product that machine is about to
	finish without free hands, so its only ways out are standing still or selling
	the fruit raw. Refusing to pick it up in the first place is what keeps the loop
	from ever reaching that state. An owner with no factory at all still gets fruit
	fetched and sold — raw is the only option there, so it is not a compromise.
]]
local function chooseJob(worker: WorkerRecord, claims: Claims, now: number): Job?
	local owner = worker.owner
	local at = worker.position

	local carrying = worker.carrying
	if carrying then
		local machine = FactoryService.idleFactoryFor(owner, carrying, at, claims.machines)
		if machine then
			return insertJob(worker, machine)
		end

		-- Nothing free right now. Worth waiting only while a machine is actually
		-- mid-cycle, and only up to RefineTimeout — see that config comment for the
		-- narrow case this covers.
		if Produce.recipeFor(carrying)
			and FactoryService.hasWorkingFactory(owner)
			and now - worker.holdSince < Config.Worker.RefineTimeout
		then
			return nil
		end

		return sellJob(worker)
	end

	local ready = FactoryService.readyFactoryFor(owner, at, claims.machines)
	if ready then
		return {
			kind = "Collect",
			stand = standNear(at, ready.position, ready.model),
			look = ready.position,
			subject = ready.model,
			machine = ready,
		}
	end

	local fruit = PlantingService.nearestRipeFruit(owner, at, claims.fruit)
	if not fruit then
		return nil
	end

	-- Rule 5's gate. Nothing refines it, or a machine is standing ready for it, or
	-- the owner has no factory and raw is the only route anyway.
	local placeable = not Produce.recipeFor(fruit.itemName)
		or FactoryService.idleFactoryFor(owner, fruit.itemName, at, claims.machines) ~= nil
		or not FactoryService.hasFactory(owner)
	if not placeable then
		return nil
	end

	return {
		kind = "Harvest",
		stand = standNear(at, fruit.ground, fruit.part),
		look = fruit.position,
		subject = fruit.part,
		fruit = fruit,
	}
end

--[[ Doing it ]]

local function take(worker: WorkerRecord, itemName: string, now: number)
	worker.carrying = itemName
	worker.holdSince = now
	WorkerModel.showItem(worker.model, itemName)
end

local function release(worker: WorkerRecord)
	worker.carrying = nil
	WorkerModel.showItem(worker.model, nil)
end

-- Commits the job the worker has just walked to.
--
-- Every branch can legitimately come up empty: the owner can harvest the same
-- fruit, load the same machine or collect the same product by hand during the
-- seconds a worker spends walking over. Nothing is retried and nothing is warned
-- about — the worker simply has nothing in its hands and picks again next think.
local function finish(worker: WorkerRecord, job: Job, now: number)
	if job.kind == "Harvest" then
		local fruit = job.fruit
		if fruit and PlantingService.pluck(fruit) then
			take(worker, fruit.itemName, now)
			log("%s's worker picked a %s", worker.owner.Name, fruit.itemName)
		end
		return
	end

	if job.kind == "Insert" then
		local machine = job.machine
		local carrying = worker.carrying
		if machine and carrying and FactoryService.insertItem(machine, carrying) then
			release(worker)
			log("%s's worker loaded a %s into the factory at %s",
				worker.owner.Name, carrying, tostring(machine.position))
		end
		return
	end

	if job.kind == "Collect" then
		local machine = job.machine
		local product = if machine then FactoryService.collectProduct(machine) else nil
		if product then
			take(worker, product, now)
			log("%s's worker collected a %s", worker.owner.Name, product)
		end
		return
	end

	local carrying = worker.carrying
	if not carrying then
		return
	end

	-- SellService logs the payout, alongside the players' own sales, so there is one
	-- record of everything the stall paid out rather than two that can disagree.
	SellService.sellCarried(worker.owner, carrying)

	-- Released either way. An item nothing prices earns nothing, but leaving it in
	-- the worker's hands would jam it at the stall re-selling the same thing
	-- forever; SellService has already warned about the unpriced item.
	release(worker)
end

--[[ The loop ]]

local function stepWorker(worker: WorkerRecord, deltaTime: number, now: number)
	-- Paused at a stop: picking and loading take a beat.
	if now < worker.waitUntil then
		return
	end

	local job = worker.job
	if job then
		-- Abandon a trip whose target has left the world rather than walking the
		-- rest of the way to nothing.
		if job.subject.Parent == nil then
			worker.job = nil
			refreshStatus(worker)
			return
		end

		if advance(worker, job.stand, deltaTime) then
			worker.job = nil
			faceTowards(worker, job.look)
			finish(worker, job, now)
			worker.waitUntil = now + Config.Worker.ActionDelay
			refreshStatus(worker)
		end
		return
	end

	if now >= worker.thinkAt then
		worker.thinkAt = now + Config.Worker.ThinkInterval
		worker.job = chooseJob(worker, claimsFor(worker.owner, worker), now)
		refreshStatus(worker)
		if worker.job then
			return
		end
	end

	-- Nothing to do. Standing by a machine that is about to finish beats walking
	-- home: on this map the round trip to the post is longer than the cycle it
	-- would be waiting out, so the worker would arrive home just in time to turn
	-- around.
	if FactoryService.hasWorkingFactory(worker.owner) then
		return
	end

	advance(worker, worker.post, deltaTime)
end

local function step(deltaTime: number)
	local now = os.clock()
	for _, worker in ipairs(workers) do
		if worker.model.Parent ~= nil then
			stepWorker(worker, deltaTime, now)
		end
	end
end

--[[ Hiring and firing ]]

-- Idle workers line up along the pad's own X axis, measured from the pad's
-- CFrame, so moving or rotating the pad in Studio carries the posts with it — the
-- same reason the belt computes seed positions in its own local space. One row:
-- more workers than the row fits share posts rather than marching off the pad.
local function postFor(pad: BasePart, index: number): Vector3
	local cfg = Config.Worker
	local usable = math.max(cfg.PostSpacing, pad.Size.X - cfg.PostMargin * 2)
	local perRow = math.max(1, math.floor(usable / cfg.PostSpacing))

	local column = index % perRow
	local offset = (column - (perRow - 1) / 2) * cfg.PostSpacing
	return (pad.CFrame * CFrame.new(offset, pad.Size.Y / 2, 0)).Position
end

local function spawnWorker(owner: Player)
	local pad = zone
	local folder = workerFolder
	if not (pad and folder) then
		return
	end

	local post = postFor(pad, postIndex)
	postIndex += 1

	local model = WorkerModel.create()
	model:SetAttribute("OwnerUserId", owner.UserId)
	model.Parent = folder

	local worker: WorkerRecord = {
		model = model,
		owner = owner,
		post = post,
		position = post,
		facing = Vector3.new(0, 0, -1),
		walkPhase = 0,
		settled = true,
		carrying = nil,
		holdSince = 0,
		job = nil,
		waitUntil = 0,
		thinkAt = 0,
	}
	table.insert(workers, worker)

	pose(worker)
	refreshStatus(worker)

	log("%s's worker reported for work at %s", owner.Name, tostring(post))
end

local function removePlayer(owner: Player)
	-- A worker only ever works for one player and pays only that player, so
	-- leaving one standing would be scenery that harvests their old plants.
	for index = #workers, 1, -1 do
		local worker = workers[index]
		if worker.owner == owner then
			worker.model:Destroy()
			table.remove(workers, index)
		end
	end
end

function WorkerService.start()
	local pad = workspace:FindFirstChild(Config.Worker.ZoneName)
	if not (pad and pad:IsA("BasePart")) then
		warn(("[WorkerService] Workspace.%s is not a BasePart — workers disabled.")
			:format(Config.Worker.ZoneName))
		return
	end
	zone = pad :: BasePart

	local existing = workspace:FindFirstChild(Config.Worker.FolderName)
	if existing then
		workerFolder = existing :: Folder
	else
		local folder = Instance.new("Folder")
		folder.Name = Config.Worker.FolderName
		folder.Parent = workspace
		workerFolder = folder
	end

	RunService.Heartbeat:Connect(step)

	-- Workers are hired on join and never need the owner's character, so one is
	-- already walking to the farm while its owner is still loading in.
	local function setupPlayer(player: Player)
		for _ = 1, Config.Worker.StartingWorkers do
			spawnWorker(player)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	print(("[WorkerService] Ready on Workspace.%s — %d worker(s) per player at %d studs/s.")
		:format(Config.Worker.ZoneName, Config.Worker.StartingWorkers, Config.Worker.WalkSpeed))
end

return WorkerService
