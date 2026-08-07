--!strict

--[[
	Runs the NPC workers: each one harvests its owner's ripe fruit, carries it to
	one of the owner's factories, comes back for the finished product and walks it
	to the seller. The coins land on the owner.

	**A worker is a second actor on the same farm, not a second set of rules.** It
	never touches `records` in PlantingService or FactoryService and never writes a
	prompt's `Enabled` other than its own hire/dismiss pair. Every commit goes
	through the same transition a player's prompt uses — takeFruit, beginCycle,
	endCycle — so a machine a worker loaded advertises itself exactly like one a
	player loaded, and neither can take the same fruit twice.

	**A worker carries exactly one item, in its hands, and it is not a second
	Backpack.** The fruit it picks never enters the owner's tally, so it does not
	count against Config.Inventory.MaxProduce and a worker keeps earning while its
	owner's Backpack is full. It also means the item is visible in the world for
	the whole trip: what the worker is holding *is* its state, the same way what
	sits in a factory's Slot is that machine's.

	**Workers are hired, not granted.** A pool of `Config.Worker.PoolSize` unhired
	candidates stands on the zone at all times, each rolled its own walk speed and
	priced from it. A player has none until they walk up to one and hire it — hiring
	does not create anything new, it flips that same rig's `owner` from nil to the
	hiring player and lets it start choosing jobs. An unhired candidate left too
	long is destroyed and re-rolled (`RotateInterval`), so a bad batch of offers is
	never permanent, and hiring or rotating one refills its slot from `topUpPool`.

	Everything here is server-side. There is no remote and no client module.
	Hiring and dismissing are plain ProximityPrompt triggers, which Roblox already
	delivers with the triggering Player attached and already enforces
	`MaxActivationDistance` for — there is nothing here for a client to lie about.

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
local InventoryService = require(script.Parent.InventoryService)
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

-- Rolled once at spawn and never changed for the life of the rig. Only walk
-- speed for now; kept as a table so a second stat later does not change every
-- signature that passes one around.
export type WorkerStats = {
	WalkSpeed: number,
}

type WorkerRecord = {
	model: Model,
	hirePrompt: ProximityPrompt,
	dismissPrompt: ProximityPrompt,

	-- Nil while standing unhired in the pool. That is the only thing that changes
	-- at hire time — the rig, its stats and its price all already existed.
	owner: Player?,

	-- Rolled once at spawn.
	stats: WorkerStats,
	-- Derived from stats once, so the prompt's price and the amount actually
	-- charged can never disagree.
	hireCost: number,

	-- Which pool slot this candidate occupies, so hiring or rotating it can free
	-- that exact slot for topUpPool to refill. Nil once hired — a hired worker's
	-- post lives further out along the same row and is never reclaimed.
	poolSlot: number?,
	-- When an unhired candidate is replaced by a fresh roll. Meaningless once
	-- hired.
	rotateAt: number,

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

-- Every rig the service is stepping, hired and unhired alike.
local workers: { WorkerRecord } = {}

-- Slot index (1..PoolSize) -> the candidate standing there. Missing for the
-- instant between one leaving (hired or rotated) and topUpPool refilling it.
local pool: { [number]: WorkerRecord } = {}

-- Hired workers take post slots after the pool's own, counting up and never
-- reused — posts are cosmetic, so there is no need to reclaim one a dismissed
-- worker leaves behind.
local hiredSlots = 0

-- Hiring and dismissal refuse by simply returning, which makes a failed prompt
-- press impossible to diagnose from inside the game. Config.Worker.LogActions
-- silences this, the same flag every other message in this file is gated on.
local function refuse(player: Player, reason: string, ...: any)
	if not Config.Worker.LogActions then
		return
	end
	warn(("[WorkerService] %s: %s"):format(player.Name, reason:format(...)))
end

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
	if not worker.owner then
		return ("For hire — %d studs/s, %d coins"):format(worker.stats.WalkSpeed, worker.hireCost)
	end

	local job = worker.job
	if job then
		if job.kind == "Harvest" then
			return ("Fetching %s"):format(if job.fruit then Produce.displayName(job.fruit.itemName) else "fruit")
		elseif job.kind == "Insert" then
			return ("Loading %s"):format(if worker.carrying then Produce.displayName(worker.carrying) else "fruit")
		elseif job.kind == "Collect" then
			return "Collecting"
		end
		return ("Selling %s"):format(if worker.carrying then Produce.displayName(worker.carrying) else "produce")
	end

	if worker.carrying then
		return ("Holding %s"):format(Produce.displayName(worker.carrying))
	end
	return "Idle"
end

-- Only called when the job, the carried item or the hire state changes: the text
-- replicates to every client, so rewriting it every frame would cost real
-- bandwidth to say the same thing.
local function refreshStatus(worker: WorkerRecord)
	local owner = worker.owner
	WorkerModel.setStatus(worker.model, if owner then owner.Name else "Unhired", describe(worker))
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
		local step = math.min(worker.stats.WalkSpeed * deltaTime, distance)
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
	`owner` is `worker.owner`, passed in already non-nil — this is only ever called
	for a hired worker (see stepWorker).

	The order is deliberate, and the constraint driving it is that a worker has one
	pair of hands:

	  1. Carrying something a machine will take, and a machine is free -> load it.
	  2. Carrying something, the machines that take it are busy -> wait, but not
	     forever.
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

	**Tiers change nothing about the order and everything about "a machine".**
	Since a machine only accepts the rung below it, every question a worker asks
	about factories is now asked *about the item in its hands* — is there a free
	machine for this, is one that takes this busy, does the owner own one at all —
	and FactoryService answers each by matching tiers. Asking the untiered
	question instead is the bug to watch for: a worker holding a Pie that waits
	because some tier-1 is busy is waiting on a machine that can never help it,
	and it will do that for the full RefineTimeout every single trip.

	What falls out of this for free is that a worker walks the whole ladder.
	Rule 4 hands it a Pie, rule 1 finds the tier-2 that eats Pies, rule 4 hands it
	the Cake, and so on until rule 3 finds nothing that refines a Masterpiece and
	sends it to the stall. No step of that is special-cased.

	Rule 4 stays ungated on purpose, and it is the one asymmetry left: a worker
	will collect a finished product even with nowhere to take it next. Emptying a
	machine is progress regardless — it unblocks the rung below — and the worst
	case is bounded by rule 2's timeout and a raw sale.
]]
local function chooseJob(worker: WorkerRecord, owner: Player, claims: Claims, now: number): Job?
	local at = worker.position

	local carrying = worker.carrying
	if carrying then
		local machine = FactoryService.idleFactoryFor(owner, carrying, at, claims.machines)
		if machine then
			return insertJob(worker, machine)
		end

		-- Nothing free right now. Worth waiting only while a machine *of the tier
		-- that takes this* is mid-cycle, and only up to RefineTimeout — see that
		-- config comment for the narrow case this covers.
		if FactoryService.hasWorkingFactoryFor(owner, carrying)
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
	-- the owner owns no machine of the tier that takes it and raw is the only
	-- route anyway. That last clause is per-tier: an owner with four machines and
	-- no tier-1 among them cannot refine a strawberry any more than an owner with
	-- none, and a worker that could not tell the difference would refuse to pick
	-- fruit at all.
	local placeable = not Produce.recipeFor(fruit.itemName)
		or FactoryService.idleFactoryFor(owner, fruit.itemName, at, claims.machines) ~= nil
		or not FactoryService.hasFactoryFor(owner, fruit.itemName)
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
	local owner = worker.owner
	if not owner then
		-- Unreachable: chooseJob only ever runs for a hired worker (see
		-- stepWorker), so a job can never exist without one. Warn rather than
		-- silently doing nothing, in case that stops being true.
		warn("[WorkerService] a job existed on an unhired worker — discarding it.")
		return
	end

	if job.kind == "Harvest" then
		local fruit = job.fruit
		if fruit and PlantingService.pluck(fruit) then
			take(worker, fruit.itemName, now)
			log("%s's worker picked a %s", owner.Name, fruit.itemName)
		end
		return
	end

	if job.kind == "Insert" then
		local machine = job.machine
		local carrying = worker.carrying
		if machine and carrying and FactoryService.insertItem(machine, carrying) then
			release(worker)
			log("%s's worker loaded a %s into the factory at %s",
				owner.Name, Produce.displayName(carrying), tostring(machine.position))
		end
		return
	end

	if job.kind == "Collect" then
		local machine = job.machine
		local product = if machine then FactoryService.collectProduct(machine) else nil
		if product then
			take(worker, product, now)
			log("%s's worker collected a %s worth %d coins",
				owner.Name, Produce.displayName(product), Produce.price(product))
		end
		return
	end

	local carrying = worker.carrying
	if not carrying then
		return
	end

	-- SellService logs the payout, alongside the players' own sales, so there is one
	-- record of everything the stall paid out rather than two that can disagree.
	SellService.sellCarried(owner, carrying)

	-- Released either way. An item nothing prices earns nothing, but leaving it in
	-- the worker's hands would jam it at the stall re-selling the same thing
	-- forever; SellService has already warned about the unpriced item.
	release(worker)
end

--[[ The loop ]]

-- Only ever reaches the job/idle machinery for a hired worker. An unhired
-- candidate has nothing to decide — it stands at its slot until a player hires
-- it or rotation replaces it, both handled by the caller (see `step`) before this
-- point, so returning immediately here is correct, not a shortfall.
local function stepWorker(worker: WorkerRecord, deltaTime: number, now: number)
	local owner = worker.owner
	if not owner then
		return
	end

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
		worker.job = chooseJob(worker, owner, claimsFor(owner, worker), now)
		refreshStatus(worker)
		if worker.job then
			return
		end
	end

	-- Nothing to do. Standing by a machine that is about to finish beats walking
	-- home: on this map the round trip to the post is longer than the cycle it
	-- would be waiting out, so the worker would arrive home just in time to turn
	-- around.
	if FactoryService.hasWorkingFactory(owner) then
		return
	end

	advance(worker, worker.post, deltaTime)
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

local function rollStats(): WorkerStats
	return { WalkSpeed = math.random(Config.Worker.MinWalkSpeed, Config.Worker.MaxWalkSpeed) }
end

-- The one formula behind a hire's price, used by both the prompt text and the
-- charge — so what a candidate advertises and what it actually costs can never
-- disagree.
local function hireCostFor(stats: WorkerStats): number
	local cfg = Config.Worker
	return cfg.HireBaseCost + (stats.WalkSpeed - cfg.MinWalkSpeed) * cfg.HireCostPerStud
end

-- The only writer of either prompt's `Enabled`, the same contract
-- FactoryService.refreshPrompts holds for a machine's two prompts. Enable one of
-- these anywhere else and the two states can contradict each other — a hired
-- worker still advertising itself for hire is the exact bug this prevents.
local function refreshHirePrompt(worker: WorkerRecord)
	if worker.owner then
		worker.hirePrompt.Enabled = false
		worker.dismissPrompt.Enabled = Config.Worker.CanDismiss
		return
	end

	worker.hirePrompt.ActionText = ("Hire — %d coins"):format(worker.hireCost)
	worker.hirePrompt.ObjectText = ("Worker — %d studs/s"):format(worker.stats.WalkSpeed)
	worker.hirePrompt.Enabled = true
	worker.dismissPrompt.Enabled = false
end

-- Forward declarations: spawnCandidate wires both prompts to these before they
-- are defined below it — the same forward-declare PlantingService uses for
-- takeFruit.
local onHirePrompt: (worker: WorkerRecord, player: Player) -> ()
local onDismissPrompt: (worker: WorkerRecord, player: Player) -> ()

-- A fresh, unhired rig standing at pool slot `slotIndex`. Called both to fill an
-- empty slot at startup and to replace one that was just hired or rotated out.
local function spawnCandidate(slotIndex: number)
	local pad = zone
	local folder = workerFolder
	if not (pad and folder) then
		return
	end

	local stats = rollStats()
	local cost = hireCostFor(stats)
	local post = postFor(pad, slotIndex)

	local model = WorkerModel.create()
	model.Parent = folder
	-- Mirrors the roll for the Explorer while debugging. The record stays
	-- authoritative — nothing here reads this back to make a decision, the same
	-- relationship the produce tally has with its Tools.
	model:SetAttribute("WalkSpeed", stats.WalkSpeed)
	model:SetAttribute("HireCost", cost)

	-- Recursive: the prompts are parented to the rig's Torso, not to the model
	-- directly, the same reason FactoryService looks up its own prompts with the
	-- recursive flag.
	local hirePrompt = model:FindFirstChild("HirePrompt", true)
	local dismissPrompt = model:FindFirstChild("DismissPrompt", true)
	if not (hirePrompt and hirePrompt:IsA("ProximityPrompt")
		and dismissPrompt and dismissPrompt:IsA("ProximityPrompt")) then
		-- Without both prompts a candidate could be neither hired nor later
		-- dismissed, so it would stand there as inert scenery blocking its slot.
		warn("[WorkerService] built a worker without both prompts — discarding it.")
		model:Destroy()
		return
	end

	local worker: WorkerRecord = {
		model = model,
		hirePrompt = hirePrompt :: ProximityPrompt,
		dismissPrompt = dismissPrompt :: ProximityPrompt,
		owner = nil,
		stats = stats,
		hireCost = cost,
		poolSlot = slotIndex,
		rotateAt = os.clock() + Config.Worker.RotateInterval,
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

	pool[slotIndex] = worker
	table.insert(workers, worker)

	worker.hirePrompt.Triggered:Connect(function(player: Player)
		onHirePrompt(worker, player)
	end)
	worker.dismissPrompt.Triggered:Connect(function(player: Player)
		onDismissPrompt(worker, player)
	end)

	pose(worker)
	refreshHirePrompt(worker)
	refreshStatus(worker)

	log("a %d studs/s worker is available to hire for %d coins", stats.WalkSpeed, cost)
end

-- Fills every empty pool slot. Call after any hire, rotation or removal, so the
-- zone always offers Config.Worker.PoolSize candidates.
local function topUpPool()
	for slotIndex = 1, Config.Worker.PoolSize do
		if not pool[slotIndex] then
			spawnCandidate(slotIndex)
		end
	end
end

local function hiredCountFor(player: Player): number
	local count = 0
	for _, worker in ipairs(workers) do
		if worker.owner == player then
			count += 1
		end
	end
	return count
end

function onHirePrompt(worker: WorkerRecord, player: Player)
	-- Re-checked rather than trusted: the prompt can fire twice before its own
	-- teardown, and two players can trigger the same candidate in the same frame.
	-- FactoryService's handlers re-check state for exactly this reason.
	if worker.owner then
		refuse(player, "that worker has already been hired")
		return
	end

	if hiredCountFor(player) >= Config.Worker.MaxHired then
		refuse(player, "already at the %d worker limit", Config.Worker.MaxHired)
		return
	end

	-- Charged last, only once every other gate has passed — the seed and the
	-- factory stock are both consumed on the same rule.
	if not InventoryService.spendCoins(player, worker.hireCost) then
		refuse(player, "cannot afford %d coins for this worker", worker.hireCost)
		return
	end

	local pad = zone
	hiredSlots += 1
	worker.owner = player
	worker.model:SetAttribute("OwnerUserId", player.UserId)
	if pad then
		worker.post = postFor(pad, Config.Worker.PoolSize + hiredSlots)
	end

	local slotIndex = worker.poolSlot
	if slotIndex then
		worker.poolSlot = nil
		pool[slotIndex] = nil
	end

	refreshHirePrompt(worker)
	refreshStatus(worker)
	topUpPool()

	log("%s hired a %d studs/s worker for %d coins", player.Name, worker.stats.WalkSpeed, worker.hireCost)
end

function onDismissPrompt(worker: WorkerRecord, player: Player)
	-- Re-checked here and not just left to the hidden prompt, for the same reason
	-- every other gate in this game is server-side: a disabled prompt is a
	-- client-side fact, and this hands a worker's slot away for good.
	if not Config.Worker.CanDismiss then
		refuse(player, "worker dismissal is switched off")
		return
	end

	if worker.owner ~= player then
		refuse(player, "does not own that worker")
		return
	end

	-- The item in its hands was never in the tally, so dismissing mid-trip would
	-- destroy it with no record anywhere. Same shape as the factory refusing to be
	-- picked up mid-cycle: the player collects first.
	if worker.carrying then
		refuse(player, "that worker is carrying a %s — let it deliver that first",
			Produce.displayName(worker.carrying))
		return
	end

	for index, candidate in ipairs(workers) do
		if candidate == worker then
			table.remove(workers, index)
			break
		end
	end
	worker.model:Destroy()

	-- No refund, and the freed slot does not return to the pool — see the plan
	-- this shipped with for why: growing the pool back would reintroduce a stat
	-- rolled for a moment that has passed.
	log("%s dismissed a %d studs/s worker", player.Name, worker.stats.WalkSpeed)
end

-- Replaces an unhired candidate whose offer has expired. Called from `step`,
-- never from inside a loop over `workers` that is still iterating by ipairs — see
-- the comment on `step` for why that distinction matters here.
local function rotateCandidate(worker: WorkerRecord, index: number)
	local slotIndex = worker.poolSlot
	table.remove(workers, index)
	worker.model:Destroy()

	if slotIndex then
		pool[slotIndex] = nil
		spawnCandidate(slotIndex)
	end

	log("a %d studs/s worker's offer expired and was replaced", worker.stats.WalkSpeed)
end

local function step(deltaTime: number)
	local now = os.clock()

	-- Iterated backwards by index, not with ipairs: rotating a candidate removes
	-- an entry mid-pass, and ipairs would then skip whatever used to be the next
	-- worker — the kind of bug that looks random rather than erroring.
	for index = #workers, 1, -1 do
		local worker = workers[index]
		if worker.model.Parent == nil then
			continue
		end

		if not worker.owner and now >= worker.rotateAt then
			rotateCandidate(worker, index)
			continue
		end

		stepWorker(worker, deltaTime, now)
	end
end

local function removePlayer(owner: Player)
	-- A worker only ever works for one player and pays only that player, so
	-- leaving one standing would be scenery that harvests their old plants. Their
	-- slot is not returned to the pool, matching how a manual dismissal works.
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

	topUpPool()

	Players.PlayerRemoving:Connect(removePlayer)

	print(("[WorkerService] Ready on Workspace.%s — %d candidate(s) to hire, %d-%d studs/s, up to %d per player.")
		:format(Config.Worker.ZoneName, Config.Worker.PoolSize,
			Config.Worker.MinWalkSpeed, Config.Worker.MaxWalkSpeed, Config.Worker.MaxHired))
end

return WorkerService
