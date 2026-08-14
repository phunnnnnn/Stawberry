--!strict

local InventoryService = require(script.InventoryService)
local SeedRngService = require(script.SeedRngService)
local ConveyorService = require(script.ConveyorService)
local PlantingService = require(script.PlantingService)
local FactoryService = require(script.FactoryService)
local FactoryRngService = require(script.FactoryRngService)
local UpgradeService = require(script.UpgradeService)
local SellService = require(script.SellService)
local WorkerService = require(script.WorkerService)

-- Inventory first: the other services award into it.
InventoryService.start()
-- Before the conveyor, which asks it whose seed is next on every spawn.
SeedRngService.start()
ConveyorService.start()
PlantingService.start()
FactoryService.start()
-- After the factory service, which owns the list a won machine lands in.
FactoryRngService.start()
-- After both generators, whose levels it sells.
UpgradeService.start()
SellService.start()
-- Workers last: they query the farm, the factory zone and the seller, so all
-- three have to have found their fixtures before one starts looking for work.
WorkerService.start()
