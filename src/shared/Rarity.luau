--!strict

--[[
	What a rarity band means, and which species sit in it.

	Six bands, 0 (Common) to 5 (Mythic), authored in `Config.Rarities`. A band is
	a species' *scarcity* and nothing else — price, grow time and yield are all
	set per species in the catalogue, and the bands were drawn along that same
	price order so the two can never disagree.

	Shared for the reason Produce is: the belt deals by band, the prompt on a seed
	names the band, and the price card colours by it.

	Every lookup here **falls back rather than returning nil**, because a band is
	almost always on its way into a string or a Color3. A species that names no
	band, or one outside the table, reads as Common — which is the honest answer
	for something nothing has said is rare.

	**How often a band comes past is no longer decided here.** It was, when the
	belt was one shared stream rolling over the whole catalogue at once; now every
	player has their own belt level and `Config.SeedRng.Pool` is the one place a
	band's frequency is expressed. What is left here is the question that pool
	cannot answer — *which* of a band's species — and `rollIn` is the whole of it.
	A band's three species are equally likely, because a band is by definition a
	set of species that are equally hard to come by.
]]

local Config = require(script.Parent.Config)

export type RaritySpec = Config.RaritySpec

local Rarity = {}

-- The lowest band always exists — everything falls back to it — so it is
-- resolved once here rather than re-indexed on every miss.
local BASE: RaritySpec = Config.Rarities[0]

-- Highest band there is. Counted upward from the bottom rather than written
-- down, so a seventh entry in Config.Rarities needs no edit here.
local maxTier = 0
while Config.Rarities[maxTier + 1] do
	maxTier += 1
end

Rarity.MAX = maxTier

-- Catalogue order within each band, so a roll is one draw against a count.
local speciesByTier: { [number]: { string } } = {}

--[[ Reading a band ]]

-- The band's own entry, or Common's for anything out of range.
function Rarity.of(tier: number): RaritySpec
	local spec = Config.Rarities[tier]
	if spec then
		return spec
	end
	return BASE
end

function Rarity.name(tier: number): string
	return Rarity.of(tier).Name
end

function Rarity.color(tier: number): Color3
	return Rarity.of(tier).Color
end

--[[ Reading a species ]]

-- Which band a species sits in. Zero for a name that is not in the catalogue,
-- so a stale seed still resolves to something printable.
function Rarity.ofSpecies(speciesName: string): number
	local plant = Config.Plants[speciesName]
	if not plant then
		return 0
	end
	return plant.Rarity
end

-- Every species in a band, in catalogue order — so, cheapest first. Empty for a
-- band nothing was authored into.
function Rarity.speciesIn(tier: number): { string }
	local bucket = speciesByTier[tier]
	return if bucket then table.clone(bucket) else {}
end

--[[ The belt's second draw ]]

-- One species out of a band, uniformly. The belt's pool has already decided
-- *which* band; this is the only part of that decision left, and keeping it here
-- is what stops the conveyor from needing to know the catalogue's shape.
--
-- Nil rather than a fallback species for a band nothing was authored into: that
-- is a Config fault, and quietly dealing a Strawberry for it would hide a pool
-- row pointing at a band that does not exist.
function Rarity.rollIn(tier: number): string?
	local bucket = speciesByTier[tier]
	if not bucket or #bucket == 0 then
		return nil
	end
	return bucket[math.random(#bucket)]
end

for _, speciesName in ipairs(Config.SpeciesOrder) do
	local tier = Rarity.ofSpecies(speciesName)

	local bucket = speciesByTier[tier]
	if not bucket then
		bucket = {}
		speciesByTier[tier] = bucket
	end
	table.insert(bucket, speciesName)
end

return Rarity
