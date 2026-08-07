--!strict

--[[
	Places factory machines on the factory zone and runs them.

	Placement mirrors PlantingService: the client reports *where* it clicked and
	nothing else, and every other decision — is that cell on the zone, is it
	free, is the player close enough, which tier are they holding, do they have
	one of that tier left to place — is made here.

	A machine has three states, and which of its two cycle prompts is showing is
	the whole interface:

	  empty       InputPrompt   "Insert Strawberry" -> eats an item, starts the timer
	  processing  neither       it sits in the slot for ProcessTime seconds
	  ready       OutputPrompt  "Collect ..."       -> the product goes to the inventory

	`refreshPrompts` is the only thing that touches either prompt's `Enabled`, so
	the three states cannot drift apart. A machine is built with the output prompt
	already hidden — empty is the state it starts in.

	**Machines are tiered, and a tier only eats the rung below it.** A tier-1
	factory takes raw fruit and makes a Pie; the tier-2 next to it takes that Pie
	and makes a Cake, up to the top of `Config.Tiers`. That is the only new rule:
	every state transition, every prompt and every worker query is the same code
	as before with `record.tier` threaded through it, and the tier an item belongs
	to is asked of `Produce.acceptedBy` rather than worked out here — so a machine
	and a worker cannot disagree about where something goes.

	**Machines also have a level, and level is what a machine is worth.** Tier
	decides *what* it eats; level multiplies the value of what it makes. The two
	are independent — a level-4 tier-1 and a level-1 tier-4 are both real machines
	and neither is the other's upgrade — so both are carried on the Tool, both are
	written to the placed model, and both are read back off attributes rather than
	inferred. `Produce.gradeAfter` turns the level into the output's grade, and
	because a product is priced off its input, a levelled chain compounds.

	A third prompt on its own key takes an empty machine back into stock. It is on
	now: machines come off a generator whose own level rises, so a player has to
	be able to replace an early bad one or their first six cells would be the
	whole game.

	**One Tool is exactly one placeable machine** — the same shape produce has,
	and no longer the stacked count-per-tier this replaced. Two level-2 tier-3s
	are two Tools. The authoritative list still lives here and the Tools mirror
	it, because the Backpack is replaced on respawn and rebuilding from a
	server-side list is what stops death from wiping the pile.

	Nothing here decides what a player *gets* — `FactoryRngService` calls
	`grantFactory`, and `Config.Factory.StartingFactories` is empty.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local FactoryGrid = require(ReplicatedStorage.Shared.FactoryGrid)
local FactoryModel = require(ReplicatedStorage.Shared.FactoryModel)
local Produce = require(ReplicatedStorage.Shared.Produce)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local InventoryService = require(script.Parent.InventoryService)

type FactoryRecord = {
	model: Model,
	owner: Player,
	cell: Vector3,
	-- Which rung of the ladder this machine runs. Fixed at placement, from the
	-- Tool that placed it.
	tier: number,
	-- How well it runs that rung: the multiplier it puts on what it makes. Fixed
	-- at placement from the same Tool, and never changes — there is no upgrade
	-- path for a placed machine, only picking it up and placing a better one.
	level: number,
	inputPrompt: ProximityPrompt,
	outputPrompt: ProximityPrompt,
	-- Exactly one of these is set at a time, or neither when the machine is
	-- empty: `input` while the timer runs, `output` once it has finished.
	input: string?,
	output: string?,
}

local FactoryService = {}

local zone: BasePart? = nil
local factoryFolder: Folder? = nil

local records: { FactoryRecord } = {}
local lastPlaceAt: { [Player]: number } = {}

-- Unplaced factories, one entry per machine. Authoritative; the Tools only
-- mirror it. A list rather than a count table because a machine is now a pair —
-- two entries with the same tier and different levels are two different things
-- and must not collapse into one number.
local unplaced: { [Player]: { Config.FactoryOffer } } = {}

local maxTier = #Config.Tiers
local maxLevel = Config.Factory.MaxLevel

local function unplacedList(player: Player): { Config.FactoryOffer }
	local existing = unplaced[player]
	if existing then
		return existing
	end

	local created: { Config.FactoryOffer } = {}
	unplaced[player] = created
	return created
end

-- One string per distinct machine, so Tools can be reconciled against the list
-- by identity rather than by position. Tier and level together *are* the
-- identity: nothing else about an unplaced machine varies.
local function offerKey(tier: number, level: number): string
	return ("%d:%d"):format(tier, level)
end

-- Placement, inserting and collecting all refuse by simply returning, which
-- makes a failed click or prompt impossible to diagnose from inside the game.
-- Config.Factory.LogRequests silences this.
local function refuse(player: Player, reason: string, ...: any)
	if not Config.Factory.LogRequests then
		return
	end
	warn(("[FactoryService] %s: %s"):format(player.Name, reason:format(...)))
end

local function log(message: string, ...: any)
	if Config.Factory.LogRequests then
		print(("[FactoryService] " .. message):format(...))
	end
end

--[[ Unplaced stock ]]

local function containers(player: Player): { Instance }
	local found: { Instance } = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(found, backpack)
	end
	if player.Character then
		table.insert(found, player.Character)
	end
	return found
end

-- Which machine a Tool places, or nil if it is not a factory Tool at all. This
-- is the one test for "is this a factory" — the name is a label, the attributes
-- are the contract, exactly as with a seed.
--
-- Both numbers must be present. A Tool carrying only a tier is one left over
-- from before levels existed, and reading it as level 1 would quietly hand a
-- player a machine the generator never dealt them.
local function offerOfTool(tool: Tool): Config.FactoryOffer?
	local tier = tool:GetAttribute(Config.Factory.TierAttribute)
	local level = tool:GetAttribute(Config.Factory.LevelAttribute)
	if typeof(tier) ~= "number" or typeof(level) ~= "number" then
		return nil
	end
	return { Tier = tier :: number, Level = level :: number }
end

local function createFactoryTool(offer: Config.FactoryOffer): Tool
	local tool = Instance.new("Tool")
	tool.Name = FactoryModel.describe(offer.Tier, offer.Level)
	tool.ToolTip = ("Click the factory zone to place. Level %d — everything it makes is worth ×%s.")
		:format(offer.Level, ("%g"):format(Produce.levelMultiplier(offer.Level)))
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool:SetAttribute(Config.Factory.TierAttribute, offer.Tier)
	tool:SetAttribute(Config.Factory.LevelAttribute, offer.Level)

	-- Must be named "Handle" for RequiresHandle to find it. Coloured like the
	-- machine it places, so the thing in your hand matches the thing that
	-- appears — the hotbar and the pad use one code, not two.
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1.6, 1.6, 1.6)
	handle.Color = Config.Factory.TierColors[offer.Tier] or Config.Factory.BodyColor
	handle.Material = Enum.Material.WoodPlanks
	handle.Massless = true
	handle.CanCollide = false
	handle.CanTouch = false
	handle.Parent = tool

	return tool
end

-- Brings the Tools in line with the unplaced list: exactly one Tool per machine,
-- no stacking. Same reconciliation as a produce stack — both directions, safe to
-- call repeatedly, and again after a respawn has replaced the Backpack.
--
-- Tools are matched by their tier *and level* attributes rather than by name, so
-- a Tool left over from the stacked scheme — which had no level on it — is
-- recognised as not matching anything and cleaned up, instead of lingering
-- beside the new ones claiming to be a machine the player does not own.
local function syncFactoryTools(player: Player)
	local wanted: { [string]: number } = {}
	for _, offer in ipairs(unplacedList(player)) do
		local key = offerKey(offer.Tier, offer.Level)
		wanted[key] = (wanted[key] or 0) + 1
	end

	-- Count down as Tools are kept, so the survivors are exactly as many as the
	-- list says and every extra is destroyed.
	for _, container in ipairs(containers(player)) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				local offer = offerOfTool(child)
				if offer then
					local key = offerKey(offer.Tier, offer.Level)
					local remaining = wanted[key] or 0
					if remaining > 0 then
						wanted[key] = remaining - 1
					else
						child:Destroy()
					end
				end
			end
		end
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	-- Whatever the pass above did not account for is missing, and is built from
	-- the list rather than from the Tool it is replacing.
	for _, offer in ipairs(unplacedList(player)) do
		local key = offerKey(offer.Tier, offer.Level)
		local missing = wanted[key] or 0
		if missing > 0 then
			wanted[key] = missing - 1
			createFactoryTool(offer).Parent = backpack
		end
	end
end

-- Unplaced machines the player is holding, of any tier or level. This is what
-- Config.Factory.MaxCarried caps, and what the generator checks before handing
-- another one over.
function FactoryService.carriedCount(player: Player): number
	return #unplacedList(player)
end

-- Hands a machine over, free. The generator's commit — and the only way into the
-- unplaced list other than picking a placed machine back up.
--
-- Refuses at MaxCarried rather than silently dropping it, so the caller can
-- leave the offer standing on the pad instead of destroying something the player
-- never received. Same contract as InventoryService.addItem.
function FactoryService.grantFactory(player: Player, tier: number, level: number): boolean
	if tier < 1 or tier > maxTier or level < 1 or level > maxLevel then
		warn(("[FactoryService] refusing a tier %d level %d factory — the ladder goes to %d and levels to %d.")
			:format(tier, level, maxTier, maxLevel))
		return false
	end

	if FactoryService.carriedCount(player) >= Config.Factory.MaxCarried then
		return false
	end

	table.insert(unplacedList(player), { Tier = tier, Level = level })
	syncFactoryTools(player)
	return true
end

-- Drops the first unplaced machine matching `tier`/`level`, or false when the
-- player has none. All-or-nothing, so placement cannot consume half a machine.
local function takeUnplaced(player: Player, tier: number, level: number): boolean
	local list = unplacedList(player)
	for index, offer in ipairs(list) do
		if offer.Tier == tier and offer.Level == level then
			table.remove(list, index)
			return true
		end
	end
	return false
end

local function placedCount(player: Player): number
	local count = 0
	for _, record in ipairs(records) do
		if record.owner == player then
			count += 1
		end
	end
	return count
end

--[[ Running a machine ]]

-- What a tier-`tier` machine should eat next out of this player's inventory.
-- The item in their hand wins, so "put it in" means the one they are holding;
-- falling back to the tally keeps the prompt usable with nothing equipped, and
-- Produce.sourcesForTier is sorted so that fallback picks the same item every
-- time.
--
-- Both paths are filtered to this machine's own tier. A tier-2 factory offers
-- to eat a Pie and never a strawberry, which is what makes a five-machine row
-- readable: each one advertises exactly the rung it is on.
local function chooseInput(player: Player, tier: number): string?
	local held = InventoryService.heldItemName(player)
	if held and Produce.acceptedBy(held) == tier and InventoryService.itemCount(player, held) > 0 then
		return held
	end

	-- Scanned out of what the player actually holds rather than down
	-- Produce.sourcesForTier, which lists *base* names only. A Pie out of a
	-- levelled machine is "Strawberry Pie#3" and a base-name check would walk
	-- straight past it — the machine would sit there claiming to have nothing to
	-- eat while the player stood in front of it holding three.
	--
	-- InventoryService.itemIds is sorted, so which one a machine reaches for with
	-- nothing equipped is the same every run.
	for _, itemId in ipairs(InventoryService.itemIds(player)) do
		if Produce.acceptedBy(itemId) == tier then
			return itemId
		end
	end
	return nil
end

-- Shows the one prompt that matches the machine's state and hides the other.
-- The single place either `Enabled` is written, so no path can leave a machine
-- offering both or neither by accident.
--
-- The idle text names the fruit the player would insert next, so the prompt
-- advertises what pressing E will actually do rather than a generic "Insert
-- Fruit". Only the owner can trigger it, so owner-specific text is safe.
local function refreshPrompts(record: FactoryRecord)
	local product = record.output
	if product then
		-- Done: the only thing left to do is take the product out. Named for
		-- display, so a levelled machine's prompt reads "Collect Strawberry Pie ×3"
		-- rather than showing the raw id.
		record.inputPrompt.Enabled = false
		record.outputPrompt.ActionText = ("Collect %s"):format(Produce.displayName(product))
		record.outputPrompt.Enabled = true
		return
	end

	if record.input then
		-- Working. Nothing can be put in or taken out, so offer neither: an
		-- unpressable prompt reads as a bug, and its absence reads as "wait".
		record.inputPrompt.Enabled = false
		record.outputPrompt.Enabled = false
		return
	end

	-- Nothing of this tier's input in the inventory still shows the prompt, but
	-- says what the machine is waiting for rather than naming an item the player
	-- does not have.
	local candidate = chooseInput(record.owner, record.tier)
	record.inputPrompt.ActionText = if candidate
		then ("Insert %s"):format(Produce.displayName(candidate))
		else ("Insert tier %d input"):format(record.tier)
	record.inputPrompt.Enabled = true
	record.outputPrompt.Enabled = false
end

-- Every machine a player owns. Their stock changes whenever they harvest,
-- insert, collect or sell, and the idle text has to keep up or it advertises a
-- fruit they no longer have.
local function refreshPromptsFor(player: Player)
	for _, record in ipairs(records) do
		if record.owner == player then
			refreshPrompts(record)
		end
	end
end

-- The one state transition that starts a machine. A player's prompt and a worker
-- both come through here, so a cycle cannot be started two different ways and the
-- finish timer can only ever be armed once per load.
local function beginCycle(record: FactoryRecord, source: string, recipe: Config.ProductSpec)
	-- **Where a machine's level becomes money.** Settled here, at the moment the
	-- input is eaten, rather than at collection: the machine could in principle be
	-- picked up and replaced by a different one while the timer runs, and what
	-- comes out must be what the machine that started the cycle promised.
	--
	-- The input's own grade goes in, so a chain of levelled machines compounds
	-- without anything having to walk back down it.
	local product = Produce.idFor(recipe.Name, Produce.gradeAfter(Produce.gradeOf(source), record.level))

	record.input = source
	FactoryModel.showItem(record.model, source)
	refreshPrompts(record)

	task.delay(recipe.ProcessTime, function()
		-- The machine can be removed, or its contents replaced, while the timer
		-- runs — the same guard scheduleFruit needs.
		if record.model.Parent == nil or record.input ~= source then
			return
		end

		record.input = nil
		record.output = product
		FactoryModel.showItem(record.model, product)
		refreshPrompts(record)

		log("a factory at %s finished a %s worth %d coins",
			tostring(record.cell), Produce.displayName(product), Produce.price(product))
	end)
end

-- The one state transition that empties a finished machine, handing back what came
-- out. The caller decides where it goes: a player's prompt has already found
-- Backpack room for it, a worker takes it in its hands.
local function endCycle(record: FactoryRecord): string?
	local product = record.output
	if not product then
		return nil
	end

	record.output = nil
	FactoryModel.showItem(record.model, nil)
	refreshPrompts(record)
	return product
end

local function insert(record: FactoryRecord, player: Player)
	local source = chooseInput(player, record.tier)
	if not source then
		refuse(player, "has nothing a tier %d factory accepts", record.tier)
		return
	end

	local recipe = Produce.recipeFor(source)
	if not recipe then
		refuse(player, "nothing turns %s into anything", source)
		return
	end

	-- chooseInput already filtered by tier, so this can only fire if the two
	-- disagree. Checked anyway: it is the gate that keeps a strawberry out of a
	-- tier-5 machine, and it costs one comparison.
	if recipe.Tier ~= record.tier then
		refuse(player, "%s belongs in a tier %d factory, not the tier %d at %s",
			source, recipe.Tier, record.tier, tostring(record.cell))
		return
	end

	-- Consume only once the recipe is known to exist and to match, so a bad
	-- config cannot eat an item and hand back nothing.
	if not InventoryService.takeItem(player, source, 1) then
		refuse(player, "does not have a %s to insert", source)
		return
	end

	beginCycle(record, source, recipe)

	log("%s inserted %s into the tier %d level %d factory at %s (%.1fs -> %s)",
		player.Name, Produce.displayName(source), record.tier, record.level,
		tostring(record.cell), recipe.ProcessTime, recipe.Name)
end

local function collect(record: FactoryRecord, player: Player, product: string)
	-- Produce no longer stacks, so the pie needs a free Backpack slot. Leave it
	-- in the machine when there is none: the alternative is destroying something
	-- the player spent a fruit and three seconds on.
	if InventoryService.addItem(player, product, 1) < 1 then
		refuse(player, "backpack is full — the %s stays in the factory at %s",
			Produce.displayName(product), tostring(record.cell))
		return
	end

	endCycle(record)

	log("%s collected a %s worth %d coins",
		player.Name, Produce.displayName(product), Produce.price(product))
end

-- The player placed this machine, so it is theirs. Plants have no such check,
-- but there is no reason to inherit that gap here.
local function owns(record: FactoryRecord, player: Player): boolean
	if player == record.owner then
		return true
	end
	refuse(player, "does not own the factory at %s", tostring(record.cell))
	return false
end

-- Both handlers re-check the machine's state rather than trusting that the
-- right prompt was showing: a trigger can already be in flight when the state
-- changes under it.
local function onInputPrompt(record: FactoryRecord, player: Player)
	if not owns(record, player) then
		return
	end

	if record.output then
		refuse(player, "the factory at %s has a %s waiting to be collected",
			tostring(record.cell), record.output)
		return
	end

	if record.input then
		refuse(player, "the factory at %s is still working", tostring(record.cell))
		return
	end

	insert(record, player)
end

local function onOutputPrompt(record: FactoryRecord, player: Player)
	if not owns(record, player) then
		return
	end

	local product = record.output
	if not product then
		refuse(player, "the factory at %s has nothing to collect", tostring(record.cell))
		return
	end

	collect(record, player, product)
end

-- Takes a machine back into the player's stock, freeing its cell.
--
-- Only when it is empty: refusing mid-cycle means there is never a question of
-- what happens to a fruit that was already eaten, and the player only has to
-- collect first.
local function onRemove(record: FactoryRecord, player: Player)
	-- Re-checked here and not just left to the hidden prompt, for the same
	-- reason every other gate is server-side: a disabled prompt is a client-side
	-- fact, and this hands a machine back into stock.
	if not Config.Factory.CanRemove then
		refuse(player, "factory pick-up is switched off")
		return
	end

	if not owns(record, player) then
		return
	end

	if record.output then
		refuse(player, "the factory at %s still has a %s to collect", tostring(record.cell), record.output)
		return
	end

	if record.input then
		refuse(player, "the factory at %s is still working", tostring(record.cell))
		return
	end

	for index, candidate in ipairs(records) do
		if candidate == record then
			table.remove(records, index)
			break
		end
	end

	record.model:Destroy()

	-- Straight back onto the list rather than through grantFactory: picking a
	-- machine up must never be refused for want of carrying room, or the machine
	-- would be destroyed and the cell freed with nothing to show for it. Placing
	-- it took a slot in the first place, so this cannot overshoot MaxCarried by
	-- more than the machines already standing on the pad.
	table.insert(unplacedList(player), { Tier = record.tier, Level = record.level })
	syncFactoryTools(player)

	log("%s picked up the tier %d level %d factory at %s (carrying %d)",
		player.Name, record.tier, record.level, tostring(record.cell),
		FactoryService.carriedCount(player))
end

--[[ Placement ]]

local function occupiedCells(): { Vector3 }
	local cells: { Vector3 } = table.create(#records)
	for _, record in ipairs(records) do
		table.insert(cells, record.cell)
	end
	return cells
end

local function onPlaceRequest(player: Player, requested: unknown)
	local pad = zone
	if not pad then
		refuse(player, "the factory zone is missing")
		return
	end

	if typeof(requested) ~= "Vector3" then
		refuse(player, "payload was %s, not a Vector3", typeof(requested))
		return
	end
	local position = requested :: Vector3

	local now = os.clock()
	if now - (lastPlaceAt[player] or 0) < Config.Factory.PlaceCooldown then
		refuse(player, "still on cooldown (%.2fs)", Config.Factory.PlaceCooldown)
		return
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if not root then
		refuse(player, "no character or no PrimaryPart")
		return
	end

	-- Which tier *and level* gets placed is the Tool's to say, not the client's —
	-- the same rule that decides which species a seed plants. Sending the level
	-- from the client would be a way to place a level-4 machine having picked up
	-- a level-1.
	local held = character:FindFirstChildOfClass("Tool")
	local offer = if held then offerOfTool(held) else nil
	if not offer then
		refuse(player, "no factory Tool equipped — one must be held, not just carried")
		return
	end

	local tier, level = offer.Tier, offer.Level
	if tier < 1 or tier > maxTier then
		refuse(player, "the held factory claims tier %d, and the ladder only goes to %d", tier, maxTier)
		return
	end

	if level < 1 or level > maxLevel then
		refuse(player, "the held factory claims level %d, and levels only go to %d", level, maxLevel)
		return
	end

	if placedCount(player) >= Config.Factory.MaxPlaced then
		refuse(player, "at the %d factory limit", Config.Factory.MaxPlaced)
		return
	end

	local cell = FactoryGrid.project(pad, position)
	if not cell then
		refuse(player, "%s is not on a placeable cell of Workspace.%s (or is inside the %d stud edge margin)",
			tostring(position), Config.Factory.ZoneName, Config.Factory.EdgeMargin)
		return
	end

	if (root.Position - cell).Magnitude > Config.Factory.MaxPlaceDistance then
		refuse(player, "%.1f studs away, limit is %d",
			(root.Position - cell).Magnitude, Config.Factory.MaxPlaceDistance)
		return
	end

	if FactoryGrid.occupied(cell, occupiedCells()) then
		refuse(player, "the cell at %s is already taken", tostring(cell))
		return
	end

	-- Consume stock only once every check has passed. The Tools mirror the list,
	-- so holding one normally proves it is there — this is the gate for the case
	-- where they have drifted apart, and it consumes and checks in one step so
	-- they cannot drift here.
	if not takeUnplaced(player, tier, level) then
		refuse(player, "has no tier %d level %d factory to place", tier, level)
		syncFactoryTools(player)
		return
	end
	lastPlaceAt[player] = now
	syncFactoryTools(player)

	local model = FactoryModel.create(tier, level)
	FactoryModel.place(model, CFrame.new(cell) * FactoryGrid.orientation(pad))
	model:SetAttribute("OwnerUserId", player.UserId)
	model.Parent = factoryFolder

	-- By name, not by class: the machine carries three prompts and picking
	-- whichever one comes back first would wire inserting to Pick Up.
	local inputPrompt = model:FindFirstChild("InputPrompt", true)
	local outputPrompt = model:FindFirstChild("OutputPrompt", true)
	local removePrompt = model:FindFirstChild("RemovePrompt", true)
	if not (inputPrompt and inputPrompt:IsA("ProximityPrompt")
		and outputPrompt and outputPrompt:IsA("ProximityPrompt")
		and removePrompt and removePrompt:IsA("ProximityPrompt")) then
		-- Without its prompts the machine is scenery, so fail loudly rather than
		-- leaving an inert box standing on a cell nobody can reclaim.
		warn("[FactoryService] built a factory without all three prompts — discarding it.")
		model:Destroy()
		table.insert(unplacedList(player), { Tier = tier, Level = level })
		syncFactoryTools(player)
		return
	end

	local record: FactoryRecord = {
		model = model,
		owner = player,
		cell = cell,
		tier = tier,
		level = level,
		inputPrompt = inputPrompt :: ProximityPrompt,
		outputPrompt = outputPrompt :: ProximityPrompt,
		input = nil,
		output = nil,
	}
	table.insert(records, record)

	record.inputPrompt.Triggered:Connect(function(triggeredBy: Player)
		onInputPrompt(record, triggeredBy)
	end)
	record.outputPrompt.Triggered:Connect(function(triggeredBy: Player)
		onOutputPrompt(record, triggeredBy)
	end)
	;(removePrompt :: ProximityPrompt).Triggered:Connect(function(triggeredBy: Player)
		onRemove(record, triggeredBy)
	end)
	refreshPrompts(record)

	log("%s placed a tier %d level %d factory (×%s output) at %s under %s (%d placed, %d still carried)",
		player.Name,
		tier,
		level,
		("%g"):format(Produce.levelMultiplier(level)),
		tostring(cell),
		if model.Parent then model.Parent:GetFullName() else "NOTHING — the model is not in the world",
		placedCount(player),
		FactoryService.carriedCount(player))
end

--[[ Worker-facing view of the factory zone

	A worker is a second actor on the same machines, so it gets *queries* — is
	there one I can load, is there one with something waiting — and *commits* that
	go through the same two transitions the prompts use. It never reaches into
	`records`, and it never touches a prompt's `Enabled`: beginCycle and endCycle
	both end in refreshPrompts, so a machine a worker loaded advertises itself
	exactly like one a player loaded.
]]

export type MachineHandle = {
	model: Model,
	position: Vector3,
}

local function handleFor(record: FactoryRecord): MachineHandle
	return { model = record.model, position = record.cell }
end

local function recordFor(handle: MachineHandle): FactoryRecord?
	for _, record in ipairs(records) do
		if record.model == handle.model then
			return record
		end
	end
	return nil
end

-- Nearest machine of `owner`'s that `accept` likes, skipping any model in `skip`
-- so two workers do not both walk to the same one.
local function nearestMatching(
	owner: Player,
	from: Vector3,
	skip: { [Instance]: boolean }?,
	accept: (FactoryRecord) -> boolean
): MachineHandle?
	local best: FactoryRecord? = nil
	local bestDistance = math.huge

	for _, record in ipairs(records) do
		if record.owner == owner and record.model.Parent ~= nil
			and not (skip and skip[record.model]) and accept(record)
		then
			local distance = (record.cell - from).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = record
			end
		end
	end

	return if best then handleFor(best) else nil
end

-- An empty machine of `owner`'s that would take `itemName` — which now means one
-- of the *right tier*, not just any free machine. A worker holding a Pie walks
-- past the tier-1 that made it and past the tier-3 beyond, to the tier-2 that
-- accepts it.
function FactoryService.idleFactoryFor(
	owner: Player,
	itemName: string,
	from: Vector3,
	skip: { [Instance]: boolean }?
): MachineHandle?
	-- Nothing refines a Masterpiece, so a worker carrying one is told there is no
	-- machine for it rather than being sent to load it into something.
	local tier = Produce.acceptedBy(itemName)
	if not tier then
		return nil
	end
	return nearestMatching(owner, from, skip, function(record)
		return record.tier == tier and record.input == nil and record.output == nil
	end)
end

-- A machine of `owner`'s with a finished product waiting to be taken out.
function FactoryService.readyFactoryFor(
	owner: Player,
	from: Vector3,
	skip: { [Instance]: boolean }?
): MachineHandle?
	return nearestMatching(owner, from, skip, function(record)
		return record.output ~= nil
	end)
end

-- True when one of `owner`'s machines is mid-cycle, any tier. Only used to
-- decide whether an idle worker should walk home: work is about to appear
-- somewhere, and on this map the round trip is longer than a cycle.
function FactoryService.hasWorkingFactory(owner: Player): boolean
	for _, record in ipairs(records) do
		if record.owner == owner and record.input ~= nil then
			return true
		end
	end
	return false
end

-- True when a machine that would accept `itemName` is busy right now. This is
-- what a worker holding something asks before deciding to wait rather than sell
-- it, and it is **tier-specific on purpose**: a worker holding a Pie must not
-- wait out the tier-1 machine that produced it, because that machine finishing
-- will never give the Pie anywhere to go.
function FactoryService.hasWorkingFactoryFor(owner: Player, itemName: string): boolean
	local tier = Produce.acceptedBy(itemName)
	if not tier then
		return false
	end

	for _, record in ipairs(records) do
		if record.owner == owner and record.tier == tier and record.input ~= nil then
			return true
		end
	end
	return false
end

-- Whether `owner` has any machine that could *ever* take `itemName`, busy or
-- not. A worker with nowhere to refine something takes it straight to the stall
-- instead of holding out for a factory that does not exist — and with tiers,
-- owning four machines is no help at all if none of them is the right rung.
function FactoryService.hasFactoryFor(owner: Player, itemName: string): boolean
	local tier = Produce.acceptedBy(itemName)
	if not tier then
		return false
	end

	for _, record in ipairs(records) do
		if record.owner == owner and record.tier == tier then
			return true
		end
	end
	return false
end

-- Loads an item the caller is already holding. Nothing is taken from an
-- inventory: unlike the prompt path, the fruit is in a worker's hands and was
-- never in the tally.
--
-- Re-checked rather than trusted, because a player can load the same machine
-- during the seconds a worker spends walking to it.
function FactoryService.insertItem(handle: MachineHandle, itemName: string): boolean
	local record = recordFor(handle)
	if not record or record.input or record.output then
		return false
	end

	-- The tier is re-checked here and not only where the worker chose the
	-- machine, for the same reason the state is: this is a commit, and the one
	-- gate that keeps a worker from stuffing a Cake into a tier-1.
	local recipe = Produce.recipeFor(itemName)
	if not recipe or recipe.Tier ~= record.tier then
		return false
	end

	beginCycle(record, itemName, recipe)
	return true
end

-- Takes the finished product out for a caller that will carry it away. Nil when
-- the owner already collected it by hand while the worker was walking over.
function FactoryService.collectProduct(handle: MachineHandle): string?
	local record = recordFor(handle)
	if not record then
		return nil
	end
	return endCycle(record)
end

local function removePlayer(player: Player)
	-- Nobody but the owner can ever use these, so leaving them standing would
	-- just block their cells for the rest of the round.
	for index = #records, 1, -1 do
		local record = records[index]
		if record.owner == player then
			record.model:Destroy()
			table.remove(records, index)
		end
	end

	lastPlaceAt[player] = nil
	unplaced[player] = nil
end

function FactoryService.start()
	local pad = workspace:FindFirstChild(Config.Factory.ZoneName)
	if not (pad and pad:IsA("BasePart")) then
		warn(("[FactoryService] Workspace.%s is not a BasePart — factories disabled.")
			:format(Config.Factory.ZoneName))
		return
	end
	zone = pad :: BasePart

	local existing = workspace:FindFirstChild(Config.Factory.FolderName)
	if existing then
		factoryFolder = existing :: Folder
	else
		local folder = Instance.new("Folder")
		folder.Name = Config.Factory.FolderName
		folder.Parent = workspace
		factoryFolder = folder
	end

	Remotes.event(Remotes.PLACE_FACTORY).OnServerEvent:Connect(onPlaceRequest)

	local function setupPlayer(player: Player)
		-- Copied entry by entry rather than referenced: StartingFactories is shared
		-- config, and handing every player the same tables would make one player's
		-- placement spend everybody's stock. Empty by default — machines come off
		-- the generator now.
		local list = unplacedList(player)
		for _, offer in ipairs(Config.Factory.StartingFactories) do
			table.insert(list, { Tier = offer.Tier, Level = offer.Level })
		end

		player.CharacterAdded:Connect(function()
			-- Respawning replaces the Backpack, taking the factory Tools with
			-- it. Rebuild them from the unplaced list once the new one arrives.
			task.defer(function()
				player:WaitForChild("Backpack", 10)
				syncFactoryTools(player)
			end)
		end)

		task.defer(function()
			player:WaitForChild("Backpack", 10)
			syncFactoryTools(player)
		end)

		-- InventoryService moves this on every harvest, insert, collect and
		-- sale, which makes it the one signal that covers all of them.
		task.spawn(function()
			local stats = player:WaitForChild("leaderstats", 30)
			local produce = stats and stats:WaitForChild("Fruit", 30)
			if produce and produce:IsA("IntValue") then
				produce.Changed:Connect(function()
					refreshPromptsFor(player)
				end)
			end
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	local counts: { string } = {}
	for tier = 1, maxTier do
		table.insert(counts, ("T%d:%d"):format(tier, #Produce.sourcesForTier(tier)))
	end

	local multipliers: { string } = {}
	for level = 1, maxLevel do
		table.insert(multipliers, ("%g"):format(Produce.levelMultiplier(level)))
	end

	print(("[FactoryService] Ready on Workspace.%s — %d stud grid, %d tiers, %d recipe(s) (%s).")
		:format(
			Config.Factory.ZoneName,
			Config.Factory.GridSize,
			maxTier,
			#Produce.sources(),
			table.concat(counts, " ")
		))

	-- The level curve, spelled out for the same reason the belt prints its rarity
	-- spread: it is the one number a machine's whole worth hangs off, and a config
	-- edit is otherwise only visible by selling something.
	print(("[FactoryService] %d levels, output ×{%s}; pick-up is %s, carrying up to %d, placing up to %d.")
		:format(
			maxLevel,
			table.concat(multipliers, ", "),
			if Config.Factory.CanRemove then "on" else "OFF",
			Config.Factory.MaxCarried,
			Config.Factory.MaxPlaced
		))
end

return FactoryService
