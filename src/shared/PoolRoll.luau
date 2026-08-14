--!strict

--[[
	One draw out of a levelled pool table: which row, then which box of it.

	This is the mechanic the factory generator was written with, lifted out so the
	seed belt can use the same one. **It is the only place the two-draw shape is
	expressed** — a second copy would let the belt's odds and the generator's drift
	apart, and the whole reason a player can read one after learning the other is
	that they are the same arithmetic over a different pool.

	A pool is rows of boxes. The row is chosen from the roller's own *level*:

	  1. **Which row.** Mostly the level itself (`Current`), sometimes the row
	     below it (`Below`), very rarely the row above (`Above`). At the bottom
	     there is no row below and at the top no row above; whichever is missing
	     folds its weight back into `Current` rather than being re-rolled, so the
	     odds stay honest at the ends instead of quietly looping.

	  2. **Which box of that row.** Against `boxRates` normally, so the last box
	     is the rare one — **except on a row that stepped down**, which uses
	     `belowBoxRates`. Handing a worse row better box odds is what stops the
	     step-down case from reading as a plain loss, and it is why `steppedDown`
	     is returned rather than kept private.

	Nothing here knows a weight of its own: every number arrives from the caller's
	own `Config` block. It is generic over what a box holds, because the generator
	deals machines and the belt deals rarity bands and neither has to care.
]]

local PoolRoll = {}

-- Weights out of anything — only the ratios matter — for how far a roll strays
-- from the roller's own level.
export type RowWeights = {
	Current: number,
	Below: number,
	Above: number,
}

--[[ The two draws ]]

-- Which row a roll deals from, and whether it stepped down to get there.
-- Stepping down is the one thing the caller needs back, because it changes the
-- box weights.
function PoolRoll.row(level: number, rows: number, weights: RowWeights): (number, boolean)
	-- Whichever neighbour does not exist contributes nothing and its weight goes
	-- to the current row. Re-rolling instead would be the same outcome with a loop
	-- in it; clamping would silently make the end rows likelier than the table
	-- says without anything recording that it happened.
	local below = if level > 1 then weights.Below else 0
	local above = if level < rows then weights.Above else 0
	local current = weights.Current + (weights.Below - below) + (weights.Above - above)

	local pick = math.random() * (current + below + above)

	if pick < below then
		return level - 1, true
	end
	pick -= below

	if pick < above then
		return level + 1, false
	end

	return level, false
end

-- Which box of a row, against a weight list. Falls back to the last box if the
-- weights and the row disagree about how many there are, rather than indexing
-- past the end of the table.
function PoolRoll.box(rates: { number }, boxes: number): number
	local span = math.min(#rates, boxes)

	local total = 0
	for index = 1, span do
		total += rates[index]
	end

	local pick = math.random() * total
	for index = 1, span do
		if pick < rates[index] then
			return index
		end
		pick -= rates[index]
	end

	return boxes
end

--[[ Both at once ]]

-- One complete draw for a roller at `level`: what came out, and the row and box
-- it came from so a log can say where. Nil only when the row it landed on is
-- missing or empty, which is a Config fault worth reporting rather than
-- papering over — the caller has the name of the pool and can say which.
function PoolRoll.roll<T>(
	pool: { { T } },
	level: number,
	weights: RowWeights,
	boxRates: { number },
	belowBoxRates: { number }
): (T?, number, number, boolean)
	local row, steppedDown = PoolRoll.row(level, #pool, weights)

	local boxes = pool[row]
	if not boxes or #boxes == 0 then
		return nil, row, 0, steppedDown
	end

	local rates = if steppedDown then belowBoxRates else boxRates
	local box = PoolRoll.box(rates, #boxes)

	return boxes[box], row, box, steppedDown
end

--[[ Reading the odds without rolling ]]

-- How likely each row is for a roller at `level`, as fractions summing to 1.
-- Worth having because the end-of-table fold-back means the answer is not simply
-- the three weights: at level 1 the `Below` weight is part of `Current`, and
-- printing what a level *actually* deals is the only way to see that a Config
-- edit did what was intended.
function PoolRoll.rowOdds(level: number, rows: number, weights: RowWeights): { [number]: number }
	local below = if level > 1 then weights.Below else 0
	local above = if level < rows then weights.Above else 0
	local current = weights.Current + (weights.Below - below) + (weights.Above - above)

	local total = current + below + above
	if total <= 0 then
		return { [level] = 1 }
	end

	local odds: { [number]: number } = { [level] = current / total }
	if below > 0 then
		odds[level - 1] = below / total
	end
	if above > 0 then
		odds[level + 1] = above / total
	end
	return odds
end

-- What each box of a row is worth, as fractions summing to 1. The same
-- normalisation `box` rolls against, so the two can never disagree about what
-- the weights meant.
function PoolRoll.boxOdds(rates: { number }, boxes: number): { number }
	local span = math.min(#rates, boxes)

	local total = 0
	for index = 1, span do
		total += rates[index]
	end

	local odds: { number } = {}
	for index = 1, span do
		odds[index] = if total > 0 then rates[index] / total else 0
	end
	return odds
end

return PoolRoll
