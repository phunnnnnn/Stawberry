--!strict

--[[
	One index of everything a player can carry and sell: harvested fruit and
	factory products alike.

	Shared for the same reason FarmSurface is — the server pays out against
	these prices and three client modules quote them, and a second copy of the
	table would eventually quote a number the seller does not honour. Pure and
	stateless; nothing here decides anything.

	`spec` deliberately returns the same shape for a strawberry and a
	Masterpiece, which is what lets InventoryService hold both in one tally with
	one Tool each. A product is only distinguishable from a fruit by having a
	recipe, and from another product by its `Tier`.

	**Refining is a ladder.** Every item has exactly one recipe or none, and that
	recipe names the tier of machine that runs it: a raw fruit feeds a tier-1
	factory, whose output feeds a tier-2, up to the top of `Config.Tiers`. So
	`recipeFor` answers "what does this become", and the recipe's own `Tier`
	answers "which machine does it" — one lookup for both, which is what stops a
	machine and a worker disagreeing about where an item belongs.

	**Machines have levels, so two Strawberry Pies can be worth different
	amounts.** That is the one thing the catalogue above cannot express: a level-4
	tier-1 factory makes a Pie worth three times what a level-1 makes, and the
	catalogue holds a single price per name.

	So an *item id* is a name plus a grade — the multiplier its price carries:

	    "Strawberry Pie"      grade 1, out of a level-1 machine
	    "Strawberry Pie#3"    grade 3, out of a level-4 one

	Grade 1 has no suffix, which is the point of the design: every id that existed
	before levels is still exactly itself, so nothing that was passing item names
	around had to learn a second parameter. `spec`, `recipeFor` and `acceptedBy`
	resolve the base name and answer as they always did; only `price` and
	`displayName` care about the grade.

	**`gradeAfter` is the one place the ladder's compounding is expressed.** A
	product is priced off what went into it, so a levelled machine fed by another
	levelled machine multiplies twice, and nothing has to trace a Masterpiece back
	down five rungs to work out what it is worth.
]]

local Config = require(script.Parent.Config)

export type ItemSpec = {
	Name: string,
	Size: Vector3,
	Color: Color3,
	SellPrice: number,
	-- Fruit is round and products are not. Carried here so the Tool's handle
	-- and the factory's display slot render an item the same way.
	Shape: Enum.PartType,
	-- How far up the ladder this item already is: 0 for raw fruit, 1 for a Pie,
	-- up to the top tier. Not the same as the tier that *accepts* it — that is
	-- one higher, and comes from `recipeFor(name).Tier`.
	Tier: number,
	-- Which rarity band the species it came from sits in, 0..5. Unchanged by
	-- refining, so a Watermelon Masterpiece is as Mythic as the melon was —
	-- baking a thing makes it dearer, never scarcer. Read the name and colour
	-- for it out of the Rarity module.
	Rarity: number,
}

local Produce = {}

local specs: { [string]: ItemSpec } = {}

-- Input item name -> what a factory turns it into. One entry per item, so a
-- chain is just repeated lookups.
local recipes: { [string]: Config.ProductSpec } = {}

-- Every item some factory accepts, and the same again split by the tier of
-- machine that accepts it. Sorted so "the first thing this machine will take"
-- is reproducible; `pairs` order is not stable and would make a factory pick
-- differently run to run.
local sources: { string } = {}
local sourcesByTier: { [number]: { string } } = {}

local maxTier = #Config.Tiers

for _, plant in pairs(Config.Plants) do
	local fruit = plant.Fruit
	if fruit then
		specs[fruit.Name] = {
			Name = fruit.Name,
			Size = fruit.Size,
			Color = fruit.Color,
			SellPrice = fruit.SellPrice,
			Shape = Enum.PartType.Ball,
			Tier = 0,
			Rarity = plant.Rarity,
		}
	end
end

for _, product in pairs(Config.Products) do
	specs[product.Name] = {
		Name = product.Name,
		Size = product.Size,
		Color = product.Color,
		SellPrice = product.SellPrice,
		-- Not Cylinder: a cylinder's circular faces are on its X axis, so a pie
		-- would stand on edge unless every caller also rotated it. A flattened
		-- block reads the same lying flat with no rotation at all.
		Shape = Enum.PartType.Block,
		Tier = product.Tier,
		Rarity = product.Rarity,
	}

	recipes[product.Source] = product
	table.insert(sources, product.Source)

	local tierList = sourcesByTier[product.Tier]
	if not tierList then
		tierList = {}
		sourcesByTier[product.Tier] = tierList
	end
	table.insert(tierList, product.Source)
end

table.sort(sources)
for _, tierList in pairs(sourcesByTier) do
	table.sort(tierList)
end

--[[ Grades ]]

-- Separates a name from its grade in an item id. Not a character any species or
-- tier suffix contains, and matched with plain finds rather than patterns so it
-- would not matter if it were a magic one.
local GRADE_SEPARATOR = "#"

-- Grades are products of level multipliers, so they land on values like 3.375.
-- Rounding them to a fixed precision is what makes an id canonical: two items
-- refined the same way must produce the same string, or they stack as two kinds
-- of the same thing.
local function normalise(grade: number): number
	if grade ~= grade or grade <= 1 then
		-- NaN or nothing gained. Below 1 is not reachable from a multiplier table
		-- that starts at 1, and treating it as plain is safer than pricing an item
		-- below its own catalogue entry.
		return 1
	end
	return math.round(grade * 1000) / 1000
end

-- The id for an item at a given grade. Grade 1 returns the bare name, so raw
-- fruit and anything out of a level-1 machine keep the ids they had before
-- levels existed.
function Produce.idFor(itemName: string, grade: number): string
	local rounded = normalise(grade)
	if rounded <= 1 then
		return itemName
	end
	return ("%s%s%s"):format(itemName, GRADE_SEPARATOR, ("%g"):format(rounded))
end

-- The catalogue name inside an id, which is what every lookup here keys on.
function Produce.baseName(itemId: string): string
	local at = string.find(itemId, GRADE_SEPARATOR, 1, true)
	return if at then string.sub(itemId, 1, at - 1) else itemId
end

-- The price multiplier an id carries, 1 for anything ungraded. A suffix that is
-- not a number reads as 1 rather than erroring: an id is a wire value, and an
-- unpriceable item should be worth its base price, not crash a sale.
function Produce.gradeOf(itemId: string): number
	local at = string.find(itemId, GRADE_SEPARATOR, 1, true)
	if not at then
		return 1
	end
	local parsed = tonumber(string.sub(itemId, at + 1))
	return if parsed then normalise(parsed) else 1
end

-- What a level-`level` machine multiplies its output's value by. Out-of-range
-- levels fall back to 1 rather than nil, for the same reason Rarity falls back
-- to Common: this number is on its way into an arithmetic expression.
function Produce.levelMultiplier(level: number): number
	return Config.Factory.LevelMultipliers[level] or 1
end

-- The grade of what comes out of a level-`level` machine fed something of grade
-- `inputGrade`. **The one place refining's compounding is expressed** — a dear
-- Pie makes a dear Cake because the Cake is priced off the Pie, and the machine
-- that baked it multiplies again on top.
function Produce.gradeAfter(inputGrade: number, level: number): number
	return normalise(inputGrade * Produce.levelMultiplier(level))
end

-- What to write on a Tool or a card. The grade rides along as a multiplier
-- badge, because "Strawberry Cake" twice over at two prices is the one thing a
-- hotbar cannot show.
function Produce.displayName(itemId: string): string
	local grade = Produce.gradeOf(itemId)
	if grade <= 1 then
		return itemId
	end
	return ("%s ×%s"):format(Produce.baseName(itemId), ("%g"):format(grade))
end

--[[ Lookups ]]

-- The catalogue entry behind an id. Its `SellPrice` is the *base* price — use
-- `Produce.price` for what a particular item is actually worth.
function Produce.spec(itemId: string): ItemSpec?
	return specs[Produce.baseName(itemId)]
end

-- Zero for anything unknown, so an unpriced item is worthless rather than free
-- money. Everything that pays out reads this rather than `spec.SellPrice`, which
-- is what makes a graded item worth more everywhere at once.
function Produce.price(itemId: string): number
	local spec = specs[Produce.baseName(itemId)]
	if not spec then
		return 0
	end
	return math.ceil(spec.SellPrice * Produce.gradeOf(itemId))
end

-- What a factory would turn `itemName` into, or nil if nothing accepts it —
-- which is true of a raw fruit no machine takes and of anything already at the
-- top of the ladder. The recipe's `Tier` is the machine that runs it.
function Produce.recipeFor(itemId: string): Config.ProductSpec?
	return recipes[Produce.baseName(itemId)]
end

-- Which tier of machine accepts `itemId`, or nil if nothing does. The one place
-- the "a tier-N machine eats the item one rung below" rule is expressed;
-- everything that matches a machine to an item goes through here rather than
-- doing the arithmetic itself.
--
-- Grade is deliberately ignored: what refines a Pie is a tier-2 machine whatever
-- the Pie is worth, so a dear one is never left with nowhere to go.
function Produce.acceptedBy(itemId: string): number?
	local recipe = recipes[Produce.baseName(itemId)]
	return if recipe then recipe.Tier else nil
end

-- Every item some factory accepts, in a fixed order.
function Produce.sources(): { string }
	return table.clone(sources)
end

-- Every item a tier-N machine accepts, in a fixed order. Empty for a tier with
-- no recipes, which is what an out-of-range tier is.
function Produce.sourcesForTier(tier: number): { string }
	local tierList = sourcesByTier[tier]
	return if tierList then table.clone(tierList) else {}
end

-- The top of the ladder, and so the highest factory tier there is.
function Produce.maxTier(): number
	return maxTier
end

return Produce
