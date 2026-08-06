--!strict

local InventoryService = require(script.InventoryService)
local ConveyorService = require(script.ConveyorService)
local PlantingService = require(script.PlantingService)
local FactoryService = require(script.FactoryService)
local SellService = require(script.SellService)
local WorkerService = require(script.WorkerService)

-- Inventory first: the other services award into it.
InventoryService.start()
ConveyorService.start()
PlantingService.start()
FactoryService.start()
SellService.start()
-- Workers last: they query the farm, the factory zone and the seller, so all
-- three have to have found their fixtures before one starts looking for work.
WorkerService.start()
