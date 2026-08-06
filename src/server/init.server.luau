--!strict

local InventoryService = require(script.InventoryService)
local ConveyorService = require(script.ConveyorService)
local PlantingService = require(script.PlantingService)
local FactoryService = require(script.FactoryService)
local SellService = require(script.SellService)

-- Inventory first: the other services award into it.
InventoryService.start()
ConveyorService.start()
PlantingService.start()
FactoryService.start()
SellService.start()
