--!strict

--[[
	One index of everything a player can carry and sell: harvested fruit and
	factory products alike.

	Shared for the same reason FarmSurface is — the server pays out against
	these prices and three client modules quote them, and a second copy of the
	table would eventually quote a number the seller does not honour. Pure and
	stateless; nothing here decides anything.

	`spec` deliberately returns the same shape for a strawberry and a pie, which
	is what lets InventoryService hold both in one tally with one stack Tool
	each. A product is only distinguishable from a fruit by having a recipe.
]]

local Config = require(script.Parent.Config)

export type ItemSpec = {
	Name: string,
	Size: Vector3,
	Color: Color3,
	SellPrice: number,
	-- Fruit is round and products are not. Carried here so the stack Tool's
	-- handle and the factory's display slot render an item the same way.
	Shape: Enum.PartType,
}

local Produce = {}

local specs: { [string]: ItemSpec } = {}

-- Source fruit name -> what a factory turns it into.
local recipes: { [string]: Config.ProductSpec } = {}

-- Sorted so "the first fruit this machine will accept" is reproducible; `pairs`
-- order is not stable and would make the factory pick differently run to run.
local sources: { string } = {}

for _, plant in pairs(Config.Plants) do
	local fruit = plant.Fruit
	if fruit then
		specs[fruit.Name] = {
			Name = fruit.Name,
			Size = fruit.Size,
			Color = fruit.Color,
			SellPrice = fruit.SellPrice,
			Shape = Enum.PartType.Ball,
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
	}
	recipes[product.Source] = product
	table.insert(sources, product.Source)
end

table.sort(sources)

function Produce.spec(itemName: string): ItemSpec?
	return specs[itemName]
end

-- Zero for anything unknown, so an unpriced item is worthless rather than free
-- money.
function Produce.price(itemName: string): number
	local spec = specs[itemName]
	return if spec then spec.SellPrice else 0
end

-- What a factory would turn `fruitName` into, or nil if nothing accepts it.
function Produce.recipeFor(fruitName: string): Config.ProductSpec?
	return recipes[fruitName]
end

-- Every fruit some factory accepts, in a fixed order.
function Produce.sources(): { string }
	return table.clone(sources)
end

return Produce
