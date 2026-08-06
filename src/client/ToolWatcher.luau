--!strict

--[[
	One answer to "the player activated a Tool called X" — or, for a family of
	Tools that share a job rather than a name, "a Tool tagged with X".

	Seeds are the second case: eighteen species mean eighteen Tool names, but
	they all plant when clicked and they all carry one attribute, so registering
	against the attribute is the only way to bind them once.

	PlantingController and FactoryController both need this, and the two awkward
	parts are worth having exactly one copy of:

	  * Equipping moves a Tool to the character and unequipping moves it back, so
	    ChildAdded fires repeatedly for the same Tool. Without the `watched` set
	    each cycle would add another Activated connection and one click would act
	    twice.

	  * Respawning replaces the Backpack. Binding to whichever one exists at
	    startup breaks permanently after the first death: tools land in a
	    container nobody is watching and clicks do nothing, with no error. This
	    cost hours to find once already — it presents exactly as "it worked, then
	    stopped".

	Registration order does not matter: `onActivated` starts the watcher on first
	use and re-scans containers, so a handler added after the Backpack arrived
	still picks up tools already sitting in it.
]]

local Players = game:GetService("Players")

local ToolWatcher = {}

local player = Players.LocalPlayer

local handlers: { [string]: (Tool) -> () } = {}
local attributeHandlers: { [string]: (Tool) -> () } = {}
local watched: { [Tool]: true } = {}
local containers: { Instance } = {}
local started = false

-- Which handler a tool should fire: its name first, then any attribute it
-- carries. Name wins, so a Tool that somehow matched both is handled by the
-- more specific rule.
local function handlerFor(tool: Tool): ((Tool) -> ())?
	local byName = handlers[tool.Name]
	if byName then
		return byName
	end

	for attribute, handler in pairs(attributeHandlers) do
		if tool:GetAttribute(attribute) ~= nil then
			return handler
		end
	end
	return nil
end

local function watchTool(tool: Tool)
	if watched[tool] or not handlerFor(tool) then
		return
	end
	watched[tool] = true

	tool.Activated:Connect(function()
		-- Resolved again rather than captured, so re-registering a name or an
		-- attribute takes effect on tools already being watched.
		local current = handlerFor(tool)
		if current then
			current(tool)
		end
	end)

	tool.Destroying:Connect(function()
		watched[tool] = nil
	end)
end

local function scanAll()
	-- Every respawn adds a Backpack and a character, so drop the ones that have
	-- since been detached rather than re-scanning them for the rest of the
	-- session.
	for index = #containers, 1, -1 do
		local container = containers[index]
		if container.Parent == nil then
			table.remove(containers, index)
		else
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") then
					watchTool(child)
				end
			end
		end
	end
end

local function watchContainer(container: Instance)
	table.insert(containers, container)
	container.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Tool") then
			watchTool(child)
		end
	end)
	scanAll()
end

local function ensureStarted()
	if started then
		return
	end
	started = true

	player.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Backpack") then
			watchContainer(child)
		end
	end)
	-- The character is watched for the same reason: an equipped tool lives
	-- there, not in the Backpack.
	player.CharacterAdded:Connect(watchContainer)

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		watchContainer(backpack)
	end

	local character = player.Character
	if character then
		watchContainer(character)
	end
end

-- Calls `handler` whenever the player activates a Tool with this name.
function ToolWatcher.onActivated(toolName: string, handler: (Tool) -> ())
	handlers[toolName] = handler
	ensureStarted()
	scanAll()
end

-- Calls `handler` whenever the player activates a Tool carrying this attribute,
-- whatever the Tool is called. For families that share a job but not a name:
-- every seed, of any species, plants.
function ToolWatcher.onActivatedAttribute(attributeName: string, handler: (Tool) -> ())
	attributeHandlers[attributeName] = handler
	ensureStarted()
	scanAll()
end

return ToolWatcher
