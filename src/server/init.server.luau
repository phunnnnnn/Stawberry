--!strict

local InventoryService = require(script.InventoryService)
local ConveyorService = require(script.ConveyorService)
local PlantingService = require(script.PlantingService)
local FactoryService = require(script.FactoryService)
local FactoryRngService = require(script.FactoryRngService)
local SellService = require(script.SellService)
local WorkerService = require(script.WorkerService)

-- Inventory first: the other services award into it.
InventoryService.start()
ConveyorService.start()
PlantingService.start()
FactoryService.start()
-- After the factory service, which owns the list a won machine lands in.
FactoryRngService.start()
SellService.start()
-- Workers last: they query the farm, the factory zone and the seller, so all
-- three have to have found their fixtures before one starts looking for work.
WorkerService.start()
