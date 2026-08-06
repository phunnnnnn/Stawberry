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
	-- The single item consumed, one per run. A raw fruit at tier 1, and the
	-- tier below's product above that — which is what makes the chain a chain.
	Source: string,
	-- Which factory makes it. A tier-N machine accepts exactly the items whose
	-- recipe is tier N, so this number is both "what comes out" and "what eats
	-- the input".
	Tier: number,
	ProcessTime: number,
	SellPrice: number,
	Size: Vector3,
	Color: Color3,
}

--[[ The species catalogue

	Eighteen species, all built from the one PlantModel geometry — a stem, a
	leaf slab, a crown, and a ball of fruit. What tells them apart is entirely
	the numbers below: a coconut is a tall thin trunk under a wide canopy, a
	watermelon is a stub under a sprawling leaf. Nothing here needs new
	geometry code, and adding a nineteenth needs none either.

	Only the *true* form is authored. The seedling stage is derived from it by
	`sproutOf`, so a species is described once and every sprout on the farm
	reads as the same stage of growth. (Derived, the strawberry's sprout comes
	out within a few RGB points and a tenth of a stud of the hand-tuned one it
	replaces — which is the argument for deriving it.)
]]

-- Compact authoring form. Everything that is the same for all eighteen — the
-- seedling, the scale limits, the pickup range, that fruit bears again — is
-- filled in by `species` below rather than written out eighteen times. What
-- comes out is an ordinary PlantSpec; nothing downstream can tell.
type PlantEntry = {
	Name: string,
	-- Seconds from seed to true form. Fruit only starts after this.
	GrowTime: number,
	-- The only stage authored by hand, because it is the only one that has to
	-- look like the species.
	Mature: FormSpec,
	Fruit: {
		GrowTime: number,
		Size: Vector3,
		Color: Color3,
		SellPrice: number,
	},
}

-- How far a seedling is toward white, and how much smaller than the plant it
-- becomes. Young growth is paler and spindlier, which is what makes maturing
-- read as a transformation rather than as one more size step.
local SPROUT_PALENESS = 0.35
local SPROUT_HEIGHT = 0.5
local SPROUT_THICKNESS = 0.6
local SPROUT_LEAF = 0.5

local FRUIT_PICKUP_RANGE = 10
local START_SCALE = 0.2
local MATURE_SCALE = 1

local function pale(color: Color3): Color3
	return color:Lerp(Color3.new(1, 1, 1), SPROUT_PALENESS)
end

-- A seedling of the same plant: pale, thin, short, and crownless.
local function sproutOf(mature: FormSpec): FormSpec
	return {
		StemHeight = mature.StemHeight * SPROUT_HEIGHT,
		StemThickness = mature.StemThickness * SPROUT_THICKNESS,
		StemColor = pale(mature.StemColor),
		LeafSize = mature.LeafSize * SPROUT_LEAF,
		LeafColor = pale(mature.LeafColor),
	}
end

local function species(entry: PlantEntry): PlantSpec
	return {
		DisplayName = entry.Name,
		Growth = {
			Time = entry.GrowTime,
			StartScale = START_SCALE,
			MatureScale = MATURE_SCALE,
		},
		Sprout = sproutOf(entry.Mature),
		Mature = entry.Mature,
		Fruit = {
			Name = entry.Name,
			GrowTime = entry.Fruit.GrowTime,
			Size = entry.Fruit.Size,
			Color = entry.Fruit.Color,
			SellPrice = entry.Fruit.SellPrice,
			-- Bear again after harvest, so one plant is a repeatable source.
			Regrow = true,
			PickupRange = FRUIT_PICKUP_RANGE,
			-- Clear of the leaves by the fruit's own radius, so a watermelon
			-- hangs as far above the canopy as a blueberry does.
			HeightOffset = entry.Fruit.Size.Y / 2 + 0.25,
		},
	}
end

-- Authored cheapest first, which is also slowest-growing last. A species'
-- steady-state earnings are its price over its *fruit* timer, since a mature
-- plant only ever re-runs that one: an apple pays 3 coins a second, a
-- watermelon 5.75, and the long climb to the first melon is what is being
-- bought. Strawberry keeps the numbers it has always had.
--
-- No canopy is wider than 5 studs, because Farm.MinPlantSpacing is 5 — past
-- that the orchard stops looking crowded and starts looking broken.
local Catalogue: { PlantEntry } = {
	{
		Name = "Apple",
		GrowTime = 5,
		Mature = {
			StemHeight = 4.2,
			StemThickness = 0.5,
			StemColor = Color3.fromRGB(99, 72, 48),
			LeafSize = Vector3.new(3.4, 1.2, 3.4),
			LeafColor = Color3.fromRGB(62, 130, 52),
			CrownSize = Vector3.new(1, 0.45, 1),
			CrownColor = Color3.fromRGB(250, 240, 220),
		},
		Fruit = {
			GrowTime = 2,
			Size = Vector3.new(1.2, 1.2, 1.2),
			Color = Color3.fromRGB(198, 44, 44),
			SellPrice = 6,
		},
	},
	{
		Name = "Pear",
		GrowTime = 6,
		Mature = {
			StemHeight = 4.6,
			StemThickness = 0.48,
			StemColor = Color3.fromRGB(108, 82, 54),
			LeafSize = Vector3.new(3.2, 1.1, 3.2),
			LeafColor = Color3.fromRGB(86, 148, 62),
			CrownSize = Vector3.new(0.95, 0.4, 0.95),
			CrownColor = Color3.fromRGB(246, 244, 226),
		},
		Fruit = {
			GrowTime = 2.5,
			Size = Vector3.new(1.25, 1.25, 1.25),
			Color = Color3.fromRGB(206, 198, 96),
			SellPrice = 8,
		},
	},
	{
		-- A vine: low and wide rather than tall.
		Name = "Grape",
		GrowTime = 7,
		Mature = {
			StemHeight = 2.6,
			StemThickness = 0.4,
			StemColor = Color3.fromRGB(118, 92, 66),
			LeafSize = Vector3.new(3.6, 0.7, 3.6),
			LeafColor = Color3.fromRGB(94, 158, 70),
			CrownSize = Vector3.new(0.8, 0.35, 0.8),
			CrownColor = Color3.fromRGB(216, 200, 236),
		},
		Fruit = {
			GrowTime = 3,
			Size = Vector3.new(1.15, 1.15, 1.15),
			Color = Color3.fromRGB(104, 62, 156),
			SellPrice = 10,
		},
	},
	{
		Name = "Strawberry",
		GrowTime = 8,
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
			GrowTime = 3,
			Size = Vector3.new(1.1, 1.1, 1.1),
			Color = Color3.fromRGB(196, 40, 58),
			SellPrice = 12,
		},
	},
	{
		Name = "Blueberry",
		GrowTime = 9,
		Mature = {
			StemHeight = 2.4,
			StemThickness = 0.3,
			StemColor = Color3.fromRGB(96, 118, 84),
			LeafSize = Vector3.new(2.2, 0.9, 2.2),
			LeafColor = Color3.fromRGB(72, 140, 96),
			CrownSize = Vector3.new(0.7, 0.35, 0.7),
			CrownColor = Color3.fromRGB(226, 232, 244),
		},
		Fruit = {
			GrowTime = 3.5,
			Size = Vector3.new(0.95, 0.95, 0.95),
			Color = Color3.fromRGB(62, 86, 172),
			SellPrice = 15,
		},
	},
	{
		Name = "Raspberry",
		GrowTime = 10,
		Mature = {
			StemHeight = 3.4,
			StemThickness = 0.3,
			StemColor = Color3.fromRGB(122, 104, 72),
			LeafSize = Vector3.new(2.4, 0.8, 2.4),
			LeafColor = Color3.fromRGB(96, 152, 74),
			CrownSize = Vector3.new(0.7, 0.3, 0.7),
			CrownColor = Color3.fromRGB(244, 236, 240),
		},
		Fruit = {
			GrowTime = 4,
			Size = Vector3.new(1, 1, 1),
			Color = Color3.fromRGB(196, 52, 84),
			SellPrice = 18,
		},
	},
	{
		Name = "Blackberry",
		GrowTime = 11,
		Mature = {
			StemHeight = 3.6,
			StemThickness = 0.32,
			StemColor = Color3.fromRGB(98, 86, 64),
			LeafSize = Vector3.new(2.6, 0.85, 2.6),
			LeafColor = Color3.fromRGB(72, 128, 62),
			CrownSize = Vector3.new(0.7, 0.3, 0.7),
			CrownColor = Color3.fromRGB(232, 228, 236),
		},
		Fruit = {
			GrowTime = 4.5,
			Size = Vector3.new(1, 1, 1),
			Color = Color3.fromRGB(46, 32, 58),
			SellPrice = 22,
		},
	},
	{
		Name = "Cherry",
		GrowTime = 12,
		Mature = {
			StemHeight = 5,
			StemThickness = 0.45,
			StemColor = Color3.fromRGB(86, 62, 52),
			LeafSize = Vector3.new(3, 1.1, 3),
			LeafColor = Color3.fromRGB(78, 140, 66),
			CrownSize = Vector3.new(1, 0.45, 1),
			CrownColor = Color3.fromRGB(250, 210, 222),
		},
		Fruit = {
			GrowTime = 5,
			Size = Vector3.new(0.9, 0.9, 0.9),
			Color = Color3.fromRGB(168, 28, 46),
			SellPrice = 26,
		},
	},
	{
		Name = "Peach",
		GrowTime = 14,
		Mature = {
			StemHeight = 5.2,
			StemThickness = 0.5,
			StemColor = Color3.fromRGB(104, 74, 52),
			LeafSize = Vector3.new(3.4, 1.2, 3.4),
			LeafColor = Color3.fromRGB(90, 148, 68),
			CrownSize = Vector3.new(1.05, 0.5, 1.05),
			CrownColor = Color3.fromRGB(250, 196, 190),
		},
		Fruit = {
			GrowTime = 5.5,
			Size = Vector3.new(1.35, 1.35, 1.35),
			Color = Color3.fromRGB(244, 158, 108),
			SellPrice = 31,
		},
	},
	{
		Name = "Plum",
		GrowTime = 16,
		Mature = {
			StemHeight = 5,
			StemThickness = 0.5,
			StemColor = Color3.fromRGB(92, 68, 58),
			LeafSize = Vector3.new(3.2, 1.15, 3.2),
			LeafColor = Color3.fromRGB(68, 124, 68),
			CrownSize = Vector3.new(1, 0.45, 1),
			CrownColor = Color3.fromRGB(236, 216, 240),
		},
		Fruit = {
			GrowTime = 6,
			Size = Vector3.new(1.2, 1.2, 1.2),
			Color = Color3.fromRGB(108, 52, 108),
			SellPrice = 36,
		},
	},
	{
		Name = "Kiwi",
		GrowTime = 18,
		Mature = {
			StemHeight = 3,
			StemThickness = 0.42,
			StemColor = Color3.fromRGB(124, 106, 78),
			LeafSize = Vector3.new(3.8, 0.9, 3.8),
			LeafColor = Color3.fromRGB(86, 142, 74),
			CrownSize = Vector3.new(0.85, 0.35, 0.85),
			CrownColor = Color3.fromRGB(248, 244, 224),
		},
		Fruit = {
			GrowTime = 7,
			Size = Vector3.new(1.3, 1.3, 1.3),
			Color = Color3.fromRGB(140, 106, 66),
			SellPrice = 42,
		},
	},
	{
		Name = "Lemon",
		GrowTime = 20,
		Mature = {
			StemHeight = 4.8,
			StemThickness = 0.5,
			StemColor = Color3.fromRGB(110, 88, 62),
			LeafSize = Vector3.new(3.2, 1.2, 3.2),
			LeafColor = Color3.fromRGB(52, 118, 60),
			CrownSize = Vector3.new(0.95, 0.4, 0.95),
			CrownColor = Color3.fromRGB(250, 248, 236),
		},
		Fruit = {
			GrowTime = 8,
			Size = Vector3.new(1.3, 1.3, 1.3),
			Color = Color3.fromRGB(238, 220, 76),
			SellPrice = 48,
		},
	},
	{
		-- Cantaloupe. A ground vine, so almost no stem under a broad leaf.
		Name = "Melon",
		GrowTime = 23,
		Mature = {
			StemHeight = 1.8,
			StemThickness = 0.4,
			StemColor = Color3.fromRGB(110, 148, 82),
			LeafSize = Vector3.new(4.4, 0.7, 4.4),
			LeafColor = Color3.fromRGB(98, 156, 78),
			CrownSize = Vector3.new(0.9, 0.35, 0.9),
			CrownColor = Color3.fromRGB(250, 246, 210),
		},
		Fruit = {
			GrowTime = 9,
			Size = Vector3.new(2.2, 2.2, 2.2),
			Color = Color3.fromRGB(216, 196, 132),
			SellPrice = 56,
		},
	},
	{
		Name = "Orange",
		GrowTime = 26,
		Mature = {
			StemHeight = 5,
			StemThickness = 0.55,
			StemColor = Color3.fromRGB(104, 82, 58),
			LeafSize = Vector3.new(3.6, 1.3, 3.6),
			LeafColor = Color3.fromRGB(46, 112, 56),
			CrownSize = Vector3.new(1, 0.42, 1),
			CrownColor = Color3.fromRGB(250, 250, 240),
		},
		Fruit = {
			GrowTime = 10,
			Size = Vector3.new(1.45, 1.45, 1.45),
			Color = Color3.fromRGB(240, 148, 42),
			SellPrice = 64,
		},
	},
	{
		-- A cactus: the "stem" is the thick green column and the crown is the
		-- oversized night bloom.
		Name = "Dragon Fruit",
		GrowTime = 30,
		Mature = {
			StemHeight = 4.4,
			StemThickness = 0.9,
			StemColor = Color3.fromRGB(76, 140, 84),
			LeafSize = Vector3.new(1.6, 1.4, 1.6),
			LeafColor = Color3.fromRGB(66, 124, 76),
			CrownSize = Vector3.new(1.2, 0.55, 1.2),
			CrownColor = Color3.fromRGB(250, 244, 222),
		},
		Fruit = {
			GrowTime = 12,
			Size = Vector3.new(1.6, 1.6, 1.6),
			Color = Color3.fromRGB(212, 56, 108),
			SellPrice = 74,
		},
	},
	{
		-- Paddle leaves, and the crown is the dark red flower bud.
		Name = "Banana",
		GrowTime = 34,
		Mature = {
			StemHeight = 5.4,
			StemThickness = 0.85,
			StemColor = Color3.fromRGB(128, 138, 92),
			LeafSize = Vector3.new(4.6, 1, 4.6),
			LeafColor = Color3.fromRGB(74, 150, 70),
			CrownSize = Vector3.new(1.1, 0.6, 1.1),
			CrownColor = Color3.fromRGB(152, 76, 78),
		},
		Fruit = {
			GrowTime = 14,
			Size = Vector3.new(1.5, 1.5, 1.5),
			Color = Color3.fromRGB(238, 208, 72),
			SellPrice = 85,
		},
	},
	{
		Name = "Coconut",
		GrowTime = 40,
		Mature = {
			StemHeight = 7.5,
			StemThickness = 0.8,
			StemColor = Color3.fromRGB(146, 122, 88),
			LeafSize = Vector3.new(5, 0.9, 5),
			LeafColor = Color3.fromRGB(62, 134, 66),
			CrownSize = Vector3.new(1, 0.4, 1),
			CrownColor = Color3.fromRGB(238, 232, 208),
		},
		Fruit = {
			GrowTime = 16,
			Size = Vector3.new(1.7, 1.7, 1.7),
			Color = Color3.fromRGB(108, 76, 50),
			SellPrice = 98,
		},
	},
	{
		Name = "Watermelon",
		GrowTime = 48,
		Mature = {
			StemHeight = 1.6,
			StemThickness = 0.45,
			StemColor = Color3.fromRGB(104, 152, 78),
			LeafSize = Vector3.new(4.8, 0.7, 4.8),
			LeafColor = Color3.fromRGB(86, 148, 70),
			CrownSize = Vector3.new(0.95, 0.35, 0.95),
			CrownColor = Color3.fromRGB(248, 244, 200),
		},
		Fruit = {
			GrowTime = 20,
			Size = Vector3.new(2.8, 2.8, 2.8),
			Color = Color3.fromRGB(58, 118, 56),
			SellPrice = 115,
		},
	},
}

local Plants: { [string]: PlantSpec } = {}

-- Every species in catalogue order. `pairs` over Plants is not reproducible, so
-- anything that picks a species — the conveyor deciding what to send down the
-- belt — reads this instead, and a new entry in the catalogue joins the belt
-- with no other edit.
local SpeciesOrder: { string } = {}

for _, entry in ipairs(Catalogue) do
	Plants[entry.Name] = species(entry)
	table.insert(SpeciesOrder, entry.Name)
end

--[[ The refining ladder

	Factories come in tiers. A tier-1 machine eats a raw fruit and makes a Pie; a
	tier-2 machine eats that Pie and makes a Cake, and so on up. **These entries
	are the ladder** — five of them means five machine tiers, and a sixth would
	need nothing else changed anywhere.

	The chain is per species, not shared: an apple line and a watermelon line are
	different businesses all the way up, which is the whole point of having
	eighteen species. That is 18 x 5 products, so they are generated rather than
	written out — the same argument as the species catalogue above.

	Two things are deliberately uniform across every fruit:

	  * **Size means tier.** A Masterpiece is the same size whatever it is made
	    of, so a glance at a factory's slot says how far up the ladder it is.
	  * **Colour means fruit.** Every step bakes the fruit's own colour a little
	    further toward pastry and then toward gilt, but the hue survives to the
	    top — eighteen identical gold bricks would read as one item.
]]
type TierSpec = {
	Suffix: string,
	-- Multiplied onto what the *input* sells for. Falling as the ladder rises,
	-- so depth still pays without the top of an eighteen-species chain running
	-- away from every other number in the game.
	PriceMultiplier: number,
	ProcessTime: number,
	Size: Vector3,
}

local Tiers: { TierSpec } = {
	{ Suffix = "Pie", PriceMultiplier = 2.5, ProcessTime = 3, Size = Vector3.new(1.8, 0.7, 1.8) },
	{ Suffix = "Cake", PriceMultiplier = 2.2, ProcessTime = 5, Size = Vector3.new(2.1, 1.1, 2.1) },
	{ Suffix = "Tower", PriceMultiplier = 2, ProcessTime = 8, Size = Vector3.new(2.4, 1.6, 2.4) },
	{ Suffix = "Banquet", PriceMultiplier = 1.9, ProcessTime = 12, Size = Vector3.new(2.7, 2.1, 2.7) },
	{ Suffix = "Masterpiece", PriceMultiplier = 1.8, ProcessTime = 18, Size = Vector3.new(3, 2.7, 3) },
}

-- Pastry, and the gilt a high tier is finished with. The first tier's blend is
-- what turns a strawberry into something that reads as baked; the per-tier gilt
-- is small on purpose, so five steps enrich the colour without erasing it.
local BAKED_COLOR = Color3.fromRGB(214, 152, 96)
local BAKED_BLEND = 0.45
local GILT_COLOR = Color3.fromRGB(240, 202, 92)
local GILT_PER_TIER = 0.12

local Products: { [string]: ProductSpec } = {}

for _, speciesName in ipairs(SpeciesOrder) do
	local fruit = Plants[speciesName].Fruit
	if fruit then
		-- Both carried down the ladder: each step eats what the last one made and
		-- is priced against what that was worth.
		local source = fruit.Name
		local price = fruit.SellPrice
		local baked = fruit.Color:Lerp(BAKED_COLOR, BAKED_BLEND)

		for tier, step in ipairs(Tiers) do
			price = math.ceil(price * step.PriceMultiplier)

			local name = ("%s %s"):format(speciesName, step.Suffix)
			Products[name] = {
				Name = name,
				Source = source,
				Tier = tier,
				ProcessTime = step.ProcessTime,
				SellPrice = price,
				Size = step.Size,
				Color = baked:Lerp(GILT_COLOR, (tier - 1) * GILT_PER_TIER),
			}

			source = name
		end
	end
end

local Config = {
	-- Fallback for a seed that names no species of its own. Seeds are typed —
	-- the belt sends one of every species — so nothing should reach this; it is
	-- what a Tool built with no argument plants, rather than a nil species
	-- reaching PlantingService.
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

		-- Gap between the belt's top face and the underside of a seed.
		HoverOffset = 0.4,

		-- Safety cap: if nobody collects, stop adding seeds rather than
		-- filling Workspace indefinitely.
		MaxActiveSeeds = 40,

		-- Radians per stud of travel, purely cosmetic tumble.
		SpinRate = 0.15,

		-- Log every purchase and every refusal. A seed the player could not
		-- afford simply keeps riding, which is otherwise indistinguishable from
		-- a prompt that did nothing.
		LogPurchases = true,
	},

	Seed = {
		-- Suffix on the Tool's name, so a seed reads as "Apple Seed" in the
		-- hotbar. Display only — SpeciesAttribute below is what identifies a
		-- Tool as a seed and decides what it plants.
		ToolName = "Seed",

		-- Attribute naming the species a seed grows. The same
		-- selector-not-proof role FruitName plays for produce: the server
		-- re-checks the species against Config.Plants before planting it.
		SpeciesAttribute = "SeedSpecies",

		Size = Vector3.new(1.6, 1.6, 1.6),

		-- Fallback colour, for a seed whose species bears no fruit to take a
		-- colour from.
		Color = Color3.fromRGB(86, 156, 62),

		-- How far a seed's colour is darkened from the fruit it grows. Eighteen
		-- kinds have to read apart on a moving belt, but a seed should not look
		-- like the fruit itself.
		Darkness = 0.35,

		-- Seeds are bought off the belt, priced at this many times what one of
		-- the fruit sells for. A plant bears forever, so any seed eventually
		-- pays for itself; the multiplier is how many harvests that takes, and
		-- with it the reach of a starting purse. At 4, an apple seed is 24 coins
		-- and a watermelon 460 — so a new player can spread their thousand
		-- across a row of fast cheap plants or gamble it on two slow ones.
		CostMultiplier = 4,

		-- How close a player must be for the belt purchase prompt to appear.
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

		-- Coins a player joins with. Seeds are bought rather than found, so
		-- without a stake there is no first plant and no way to earn one — this
		-- is the seed capital, and it is what makes the cheapest species a real
		-- alternative to the dearest rather than the only one affordable.
		StartingCoins = 1000,
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

		-- Suffix on the Tool's name, so a machine reads as "Tier 3 Factory" in the
		-- hotbar. Display only — TierAttribute below is what identifies a Tool as
		-- a factory and decides which tier gets placed. One Tool *per tier*, each
		-- carrying that tier's whole unplaced stock as a count attribute.
		ToolName = "Factory",

		-- Attribute naming the tier, on both the Tool and the placed model. The
		-- same selector-not-proof role SeedSpecies plays for seeds: the server
		-- re-checks it against the ladder before placing anything.
		TierAttribute = "FactoryTier",

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

		-- Handed out on join, and re-issued after a respawn replaces the Backpack.
		-- One entry per tier, so the array's length *is* how many tiers exist.
		--
		-- Six machines in total against a MaxPlaced of 6: exactly one full ladder
		-- plus a second tier-1, which is the shape the loop wants. Tier 1 runs in
		-- 3s and tier 5 in 18s, so the bottom of the chain is what starves first.
		StartingStock = { 2, 1, 1, 1, 1 },

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

		-- Fallback body colour, for a tier with no entry of its own below.
		BodyColor = Color3.fromRGB(148, 122, 96),

		-- One body colour per tier, rising from workshop timber to something that
		-- looks like it belongs at the top of the ladder. Read at a distance;
		-- the pips below are what you count up close.
		TierColors = {
			Color3.fromRGB(148, 122, 96),
			Color3.fromRGB(112, 132, 148),
			Color3.fromRGB(104, 108, 168),
			Color3.fromRGB(148, 94, 164),
			Color3.fromRGB(186, 146, 62),
		},

		-- A machine wears one pip per tier along the front of its roof, because a
		-- colour tells five machines apart only once you have learnt the code and
		-- a count never needs learning. Deliberately bright and Neon rather than
		-- tinted per tier — the point is to be countable against any body colour.
		PipSize = Vector3.new(0.5, 0.45, 0.5),
		PipSpacing = 0.85,
		PipInset = 1.9,
		PipColor = Color3.fromRGB(252, 232, 130),

		-- Studs between the top of the body and the *underside* of the item on
		-- display in the slot. Measured to the underside, not the centre, because
		-- a tier-5 Masterpiece is four times the height of a tier-1 Pie and a
		-- centre offset would sink it into the roof.
		SlotOffset = 0.35,

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
	SpeciesOrder = SpeciesOrder,
	Products = Products,

	-- The refining ladder itself. Its length is how many factory tiers exist,
	-- so nothing counts tiers by hand.
	Tiers = Tiers,
}

return Config
