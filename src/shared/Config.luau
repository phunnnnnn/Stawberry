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

export type PlantSpec = {
	DisplayName: string,
	StemHeight: number,
	StemThickness: number,
	StemColor: Color3,
	LeafSize: Vector3,
	LeafColor: Color3,
	Fruit: FruitSpec?,
}

local Plants: { [string]: PlantSpec } = {
	Strawberry = {
		DisplayName = "Strawberry",
		StemHeight = 3,
		StemThickness = 0.35,
		StemColor = Color3.fromRGB(58, 110, 48),
		LeafSize = Vector3.new(1.9, 0.6, 1.9),
		LeafColor = Color3.fromRGB(86, 156, 62),
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
	},

	Seller = {
		PartName = "Seller",
		PromptRange = 14,

		-- Server re-checks this when a sale is submitted.
		MaxSellDistance = 30,
	},

	Plants = Plants,
}

return Config
