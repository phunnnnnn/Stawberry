--!strict

local InventoryService = require(script.InventoryService)
local ConveyorService = require(script.ConveyorService)
local PlantingService = require(script.PlantingService)
local SellService = require(script.SellService)

-- Inventory first: the other services award into it.
InventoryService.start()
ConveyorService.start()
PlantingService.start()
SellService.start()
