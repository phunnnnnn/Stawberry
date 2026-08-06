--!strict

local PlantingController = require(script.PlantingController)
local FactoryController = require(script.FactoryController)
local SellDialogue = require(script.SellDialogue)

-- Gameplay first.
PlantingController.start()
FactoryController.start()
SellDialogue.start()

-- Display-only modules go after it, each behind its own pcall: a require error
-- in one of them (a module that has not synced yet, say) would otherwise kill
-- this whole LocalScript and silently disable planting along with it.
local function startDisplay(name: string, begin: () -> ())
	local ok, err = pcall(begin)
	if not ok then
		warn(("[Client] %s did not start; gameplay is unaffected. %s"):format(name, tostring(err)))
	end
end

startDisplay("PlantIndicator", function()
	require(script.PlantIndicator).start()
end)

startDisplay("FactoryIndicator", function()
	require(script.FactoryIndicator).start()
end)

startDisplay("FruitInspector", function()
	require(script.FruitInspector).start()
end)

startDisplay("Leaderboard", function()
	require(script.Leaderboard).start()
end)

print("[Client] Ready — planting and selling are live.")
