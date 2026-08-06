--!strict

--[[
	Tuning values for the game. Everything here is data only — no behaviour.
]]

-- A species with `Fruit = nil` grows but never bears anything. Only the
-- fruit-bearing case is populated for now; the field stays optional so
-- barren species can be added without touching the growth code.
export type FruitSpec = {
	Name: string,
	GrowTime: number,
	Size: Vector3,
	Color: Color3,
	SellPrice: number,
	Regrow: boolean,
	PickupRange: number,
	HeightOffset: number,
}

-- The geometry of a plant at one stage of its life. A seed sprouts as the
-- species' `Sprout` form and is scaled up until it reaches the growth limit, at
-- which point the geometry is rebuilt as `Mature` — the plant's true form, and
-- the only one that bears fruit.
export type FormSpec = {
	StemHeight: number,
	StemThickness: number,
	StemColor: Color3,
	LeafSize: Vector3,
	LeafColor: Color3,
	-- Blossom on top of the true form. Left nil on the sprout, which is what
	-- makes maturing read as a transformation rather than one more size step.
	CrownSize: Vector3?,
	CrownColor: Color3?,
}

export type GrowthSpec = {
	-- Seconds from planting to the scale limit. Fruit only starts growing after
	-- this, so a plant's first fruit is Time + FruitSpec.GrowTime away.
	Time: number,

	-- Fraction of the sprout's full size it appears at when planted.
	StartScale: number,

	-- The limit. Reaching it swaps the sprout for the true form.
	MatureScale: number,
}

export type PlantSpec = {
	DisplayName: string,
	Growth: GrowthSpec,
	Sprout: FormSpec,
	Mature: FormSpec,
	Fruit: FruitSpec?,
}

-- What a factory turns `Source` into. Products are carried, priced and sold
-- through exactly the same machinery as harvested fruit — see Produce — so the
-- only thing that makes a pie a pie is this entry.
export type ProductSpec = {
	Name: string,
	-- Fruit consumed, one per run. Must match a FruitSpec.Name.
	Source: string,
	ProcessTime: number,
	SellPrice: number,
	Size: Vector3,
	Color: Color3,
}

local Plants: { [string]: PlantSpec } = {
	Strawberry = {
		DisplayName = "Strawberry",
		Growth = {
			Time = 8,
			StartScale = 0.2,
			MatureScale = 1,
		},
		-- Pale, spindly, and small: a seedling, not a short strawberry plant.
		Sprout = {
			StemHeight = 1.6,
			StemThickness = 0.22,
			StemColor = Color3.fromRGB(122, 176, 96),
			LeafSize = Vector3.new(1, 0.35, 1),
			LeafColor = Color3.fromRGB(146, 200, 108),
		},
		Mature = {
			StemHeight = 3,
			StemThickness = 0.35,
			StemColor = Color3.fromRGB(58, 110, 48),
			LeafSize = Vector3.new(1.9, 0.6, 1.9),
			LeafColor = Color3.fromRGB(86, 156, 62),
			CrownSize = Vector3.new(0.9, 0.45, 0.9),
			CrownColor = Color3.fromRGB(240, 238, 228),
		},
		Fruit = {
			Name = "Strawberry",
			GrowTime = 3,
			Size = Vector3.new(1.1, 1.1, 1.1),
			Color = Color3.fromRGB(196, 40, 58),
			SellPrice = 12,
			-- Bear again after harvest, so one plant is a repeatable source.
			Regrow = true,
			PickupRange = 10,
			-- Studs above the top of the stem.
			HeightOffset = 0.8,
		},
	},
}

local Products: { [string]: ProductSpec } = {
	["Strawberry Pie"] = {
		Name = "Strawberry Pie",
		Source = "Strawberry",
		ProcessTime = 3,
		-- The whole point of the factory: worth more than the fruit it ate.
		SellPrice = 30,
		Size = Vector3.new(1.8, 0.7, 1.8),
		Color = Color3.fromRGB(214, 152, 96),
	},
}

local Config = {
	-- Species planted when a plain seed is used. Seeds are untyped for now.
	DefaultSpecies = "Strawberry",

	Conveyor = {
		-- Name of the BasePart inside Workspace.Conveyor that seeds ride along.
		BeltName = "conveyor",

		-- Folder that holds live seeds, created under Workspace at runtime.
		SeedFolderName = "ConveyorSeeds",

		-- Studs per second a seed travels.
		Speed = 14,

		-- Seconds between spawns.
		SpawnInterval = 1.5,

		-- Which way along the belt's local Z axis seeds travel: 1 or -1.
		-- Flip this to reverse the flow.
		Direction = -1,

		-- Seeds spawn this far in from the belt's leading edge so they start
		-- fully on the belt rather than hanging off it.
		EntryMargin = 2,

		-- Random left/right spread from the belt centreline, in studs, so the
		-- stream doesn't look like a single rigid line.
		LaneJitter = 5,

		-- Gap between the belt's top face and the underside of a seed.
		HoverOffset = 0.4,

		-- Safety cap: if nobody collects, stop adding seeds rather than
		-- filling Workspace indefinitely.
		MaxActiveSeeds = 40,

		-- Radians per stud of travel, purely cosmetic tumble.
		SpinRate = 0.15,
	},

	Seed = {
		-- Tool name in the Backpack. Planting checks for this exact name.
		ToolName = "Seed",

		Size = Vector3.new(1.6, 1.6, 1.6),
		Color = Color3.fromRGB(86, 156, 62),

		-- How close a player must be for the belt pickup prompt to appear.
		PickupRange = 12,

		-- Backpack cap. At the limit, belt seeds are left alone rather than
		-- silently vanishing.
		MaxHeld = 20,
	},

	Inventory = {
		-- Backpack cap across all produce, fruit and factory products together.
		-- Produce does not stack — every item is its own Tool — so without a cap
		-- one productive farm buries the Backpack in identical strawberries.
		--
		-- At the cap, harvesting and collecting *refuse* rather than silently
		-- swallowing the item: the fruit stays on the plant and the pie stays in
		-- the machine, so nothing is ever destroyed for lack of room.
		MaxProduce = 30,
	},

	-- Board ranking players by coins. leaderstats already feeds Roblox's own
	-- player list; this is the always-visible version of the same numbers.
	Leaderboard = {
		Title = "Top Farmers",
		MaxRows = 8,
		RowHeight = 24,
		Width = 210,
	},

	Farm = {
		PartName = "Farm",
		PlantFolderName = "Plants",

		-- Server-side guards on plant requests.
		MaxPlantDistance = 60,
		MinPlantSpacing = 5,
		MaxPlantsPerPlayer = 60,
		PlantCooldown = 0.2,

		-- Keep plants off the very lip of the farm pad.
		EdgeMargin = 2,

		-- Log the outcome of every plant request: the gate that refused it, or the
		-- plant that resulted. A refusal is otherwise completely silent, so leave
		-- this on while developing.
		LogPlantRequests = true,
	},

	-- Placement preview drawn while a seed is equipped. Cosmetic only — the
	-- server validates the click regardless of what this shows.
	Indicator = {
		-- Disc marking the exact spot the seed would land.
		MarkerDiameter = 3.2,
		MarkerThickness = 0.12,
		MarkerTransparency = 0.25,

		-- Wider disc covering the MinPlantSpacing exclusion zone, so a refused
		-- spot explains itself.
		ShowSpacing = true,
		SpacingThickness = 0.06,
		SpacingTransparency = 0.82,

		ValidColor = Color3.fromRGB(96, 214, 96),
		BlockedColor = Color3.fromRGB(214, 74, 74),

		-- Lift above the pad's top face so the discs don't z-fight with it.
		HoverOffset = 0.06,

		-- Floating text naming the reason a spot is refused.
		ShowReason = true,
		ReasonHeight = 3,
	},

	Factory = {
		-- The zone machines may be placed on. "Fatory" is a typo in the place
		-- file and load-bearing — grep before renaming it.
		ZoneName = "Fatory",
		FolderName = "Factories",

		-- Tool name in the Backpack. One Tool carries the whole unplaced stock
		-- as a count attribute, the way a fruit stack does.
		ToolName = "Factory",

		-- Placement lattice, in studs. Cells are measured from the zone's own
		-- centre, so the grid moves and rotates with the pad instead of being
		-- pinned to world origin.
		GridSize = 8,

		-- Keep a machine's whole footprint off the lip of the pad, not just the
		-- point that was clicked.
		EdgeMargin = 2,

		-- Server-side guards on placement requests, mirroring the farm's.
		MaxPlaceDistance = 60,
		MaxPlaced = 6,
		PlaceCooldown = 0.2,

		-- Handed out on join, and re-issued after a respawn replaces the
		-- Backpack.
		StartingStock = 3,

		-- Taking a machine back. Currently off, so the Pick Up prompt never shows
		-- and a placed factory stays where it was put — it burns one of a fixed
		-- number of machines *and* blocks its cell for the rest of the round.
		-- Flip this to bring the prompt back; the handler behind it is still wired
		-- and still refuses a machine that is working or has a product waiting.
		CanRemove = false,

		-- Held rather than tapped, and on its own key, so taking a machine back
		-- can never be hit while spamming E to insert and collect.
		RemoveKey = Enum.KeyCode.X,
		RemoveHoldDuration = 0.6,

		BaseSize = Vector3.new(7, 1, 7),
		BaseColor = Color3.fromRGB(72, 76, 84),
		BodySize = Vector3.new(5, 3.5, 5),
		BodyColor = Color3.fromRGB(148, 122, 96),

		-- Studs between the top of the body and the item on display in the
		-- slot. The slot is the machine's whole interface: what sits there is
		-- what is inside it.
		SlotOffset = 0.9,

		PromptRange = 12,

		-- Log the outcome of every placement, insert and collect. A refusal is
		-- otherwise completely silent, so leave this on while developing.
		LogRequests = true,
	},

	-- NPCs that run the whole loop on the owner's behalf: harvest a ripe fruit,
	-- carry it to one of the owner's factories, come back for the product, walk it
	-- to the seller. The coins land on the owner.
	Worker = {
		-- The pad workers stand on when idle, and spawn from. Like Farm and
		-- Fatory this is a zone in the place file, not a marker.
		ZoneName = "Worker",
		FolderName = "Workers",

		-- The candidates standing on the zone waiting to be hired.
		PoolSize = 4,

		-- Seconds before an unhired candidate is replaced by a fresh roll. Without
		-- this a player who is offered four slow workers is stuck with that offer
		-- all round.
		RotateInterval = 45,

		-- Workers one player may have at once. Coins are the near-term limit; this
		-- is the ceiling, and also the performance one — every worker is stepped on
		-- Heartbeat.
		MaxHired = 3,

		-- Walk speed is rolled per worker, in whole studs per second so the number
		-- on the prompt is readable. Tuned against this map rather than against
		-- Roblox's default 16: the farm, the factory zone and the seller sit
		-- roughly 100 studs apart, so one harvest-refine-sell round trip is a few
		-- hundred studs of walking. The old fixed value was 22; this brackets it.
		MinWalkSpeed = 12,
		MaxWalkSpeed = 30,

		-- Hire price, derived from the roll:
		--     HireBaseCost + (WalkSpeed - MinWalkSpeed) * HireCostPerStud
		-- So the slowest worker costs HireBaseCost and the fastest 50 + 18*15 = 320.
		-- For scale: a worker at 22 studs/s cleared roughly 100 coins a minute in
		-- testing, so a mid-range hire pays for itself in about two minutes. A pie
		-- is 30 coins, so the cheapest worker is two pies of hand-farming — reachable
		-- before any income at all.
		HireBaseCost = 50,
		HireCostPerStud = 15,

		-- Dismissing a hired worker, freeing its slot. No refund. Off switch, exactly
		-- like Config.Factory.CanRemove: the handler stays wired either way.
		CanDismiss = true,

		-- Held rather than tapped, and on its own key, so dismissing can never be hit
		-- while mashing E to hire.
		DismissKey = Enum.KeyCode.X,
		DismissHoldDuration = 0.6,

		PromptRange = 12,

		-- How close to its destination counts as arrived. Must stay comfortably
		-- wider than one frame's step at MaxWalkSpeed, or a worker overshoots and
		-- orbits its target forever.
		ArriveDistance = 2.5,

		-- Gap left between a worker and the thing it is working on, measured from
		-- the target's own footprint. Without it a worker stands inside the
		-- factory it is loading.
		StandClearance = 3,

		-- Seconds between decisions while idle. Every decision rescans the
		-- owner's plants and machines, which is wasted work every frame.
		ThinkInterval = 0.5,

		-- Pause at each stop, so picking and loading read as work being done
		-- rather than items teleporting between buildings.
		ActionDelay = 0.5,

		-- How long a worker holding a fruit waits for one of the owner's machines
		-- to come free before giving up and selling it raw for a fraction of what
		-- refining it would have earned.
		--
		-- A worker will not pick a fruit up unless a machine is already free, so
		-- this only fires when the owner loaded that machine by hand in the seconds
		-- the worker spent walking to it. It exists because the alternative is a
		-- worker that stands holding a strawberry forever, which reads as broken.
		RefineTimeout = 12,

		-- Idle workers line up along the pad's own X axis, so moving or rotating
		-- the pad carries the posts with it. One row: more workers than the row
		-- fits simply share posts.
		PostSpacing = 6,
		PostMargin = 3,

		--[[ Geometry: a stock R6 rig.

			The same six parts, the same names and the same 5-stud proportions as a
			player's own character, with the built-in head mesh and face.

			Built part by part rather than fetched through
			`Players:CreateHumanoidModelFromDescription`, which yields on the avatar
			web API: a worker has to be able to start work on a server with no
			network, and hiring one must not block the join that hired it.

			These sizes are R6's own, not tuning knobs. The joint offsets are all
			derived from them, so they stay consistent if you change one — but the
			rig stops matching a real character.
		]]
		TorsoSize = Vector3.new(2, 2, 1),
		LimbSize = Vector3.new(1, 2, 1),
		HeadSize = Vector3.new(2, 1, 1),

		-- The classic head: a 2x1x1 block wearing the built-in Head mesh, which is
		-- what makes it round. MeshType.Head needs no asset.
		HeadMeshScale = Vector3.new(1.25, 1.25, 1.25),

		-- A built-in texture, so the face costs no asset fetch either.
		FaceTexture = "rbxasset://textures/face.png",

		-- Two 1-wide legs side by side under a 2-wide torso put their centres half a
		-- stud out. Arm spacing is derived from the torso and limb widths instead,
		-- since arms hang outside the torso rather than under it.
		LegSpacing = 0.5,

		TorsoColor = Color3.fromRGB(216, 176, 92),
		LegColor = Color3.fromRGB(52, 62, 88),
		-- Skin on the head and arms. Bare arms are what show that a worker is
		-- carrying something.
		ArmColor = Color3.fromRGB(236, 202, 148),
		HeadColor = Color3.fromRGB(236, 202, 148),

		-- Cosmetic walk cycle, driven by script rather than by Roblox's animation
		-- system — see WorkerModel for why the rig stays anchored. The phase is
		-- accumulated from distance travelled, not from time, so a stopped worker's
		-- limbs stop with it.
		LegSwing = 0.7,
		StepLength = 2.6,
		BobHeight = 0.12,

		-- Arms held out in front while carrying something, instead of swinging. The
		-- carried item is placed at whatever this puts the hands at, so it stays in
		-- them if you change the angle.
		CarryArmAngle = 1.4,

		-- Nameplate above the worker naming its owner and what it is doing.
		--
		-- Off: the rig reads as a character rather than as a labelled game object,
		-- and with one worker per player there is nothing to tell apart. Turning it
		-- back on is worth it while debugging, because an autonomous NPC is
		-- otherwise a black box — a worker walking to the far side of the map looks
		-- identical to one that is stuck. `LogActions` covers the same ground from
		-- Output in the meantime.
		--
		-- Everything downstream is already conditional: no BillboardGui is built,
		-- and `setStatus` finds nothing and returns.
		ShowStatus = false,
		StatusHeight = 2.2,

		-- Log every pick, load, collect and sale. A worker acts with nobody
		-- watching, so this is the only record that it is working at all.
		LogActions = true,
	},

	Seller = {
		PartName = "Seller",
		PromptRange = 14,

		-- Server re-checks this when a sale is submitted.
		MaxSellDistance = 30,

		-- Log every sale and every refusal in Output. A refused sale otherwise
		-- only appears in the player's dialogue.
		LogSales = true,
	},

	Plants = Plants,
	Products = Products,
}

return Config
