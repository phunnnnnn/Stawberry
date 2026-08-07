--!strict

--[[
	What a rarity band means, and what the belt sends down it next.

	Six bands, 0 (Common) to 5 (Mythic), authored in `Config.Rarities`. A band is
	a species' *scarcity* and nothing else — price, grow time and yield are all
	set per species in the catalogue, and the bands were drawn along that same
	price order so the two can never disagree.

	Shared for the reason Produce is: the belt rolls against these weights, the
	prompt on a seed names the band, and the price card colours by it. A second
	copy of the table would eventually advertise a seed at a rate the belt does
	not actually deal it.

	Every lookup here **falls back rather than returning nil**, because a band is
	almost always on its way into a string or a Color3. A species that names no
	band, or one outside the table, reads as Common — which is the honest answer
	for something nothing has said is rare.

	`roll` is the belt's "what comes past next". Its cumulative weights are built
	once at load rather than summed over eighteen species every spawn.
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

-- Species in catalogue order, each with the running weight total in the same
-- slot. Rolling is then one random draw and a walk up the totals.
local order: { string } = {}
local cumulative: { number } = {}
local speciesByTier: { [number]: { string } } = {}
local totalWeight = 0

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

--[[ The belt ]]

-- What fraction of belt rolls land somewhere in this band, 0..1. The whole
-- point of the weights, so it is worth being able to print it rather than
-- working it out by hand from six numbers and a count.
function Rarity.share(tier: number): number
	if totalWeight <= 0 then
		return 0
	end
	return #Rarity.speciesIn(tier) * Rarity.of(tier).Weight / totalWeight
end

-- What comes past next: one species, weighted by its band. This is the only
-- place the belt's odds are decided.
function Rarity.roll(): string
	if #order == 0 or totalWeight <= 0 then
		return Config.DefaultSpecies
	end

	local draw = math.random() * totalWeight
	for index, ceiling in ipairs(cumulative) do
		if draw < ceiling then
			return order[index]
		end
	end

	-- Only reachable if the draw lands a float's breadth past the last total.
	return order[#order]
end

for _, speciesName in ipairs(Config.SpeciesOrder) do
	local tier = Rarity.ofSpecies(speciesName)

	totalWeight += Rarity.of(tier).Weight
	table.insert(order, speciesName)
	table.insert(cumulative, totalWeight)

	local bucket = speciesByTier[tier]
	if not bucket then
		bucket = {}
		speciesByTier[tier] = bucket
	end
	table.insert(bucket, speciesName)
end

return Rarity
