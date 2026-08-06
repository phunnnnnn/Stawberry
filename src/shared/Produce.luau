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

function Produce.spec(itemName: string): ItemSpec?
	return specs[itemName]
end

-- Zero for anything unknown, so an unpriced item is worthless rather than free
-- money.
function Produce.price(itemName: string): number
	local spec = specs[itemName]
	return if spec then spec.SellPrice else 0
end

-- What a factory would turn `itemName` into, or nil if nothing accepts it —
-- which is true of a raw fruit no machine takes and of anything already at the
-- top of the ladder. The recipe's `Tier` is the machine that runs it.
function Produce.recipeFor(itemName: string): Config.ProductSpec?
	return recipes[itemName]
end

-- Which tier of machine accepts `itemName`, or nil if nothing does. The one
-- place the "a tier-N machine eats the item one rung below" rule is expressed;
-- everything that matches a machine to an item goes through here rather than
-- doing the arithmetic itself.
function Produce.acceptedBy(itemName: string): number?
	local recipe = recipes[itemName]
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
