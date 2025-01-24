local term = require('term')
local serialization = require('serialization')
local mesaApi = require('mesasuite_api')
local json = require('json')

local module = {}

local function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

local selectedCars = {} -- Key: Reporting Mark, Value: Railcar ID

-- Process from MesaSuite
local function processFromMesaSuite()
    term.write('Selecting from MesaSuite...')

    local locationFile = io.open('/etc/sar/loc.cfg', 'r')
    local fileContents = serialization.unserialize(locationFile:read('*a'))
    locationFile:close()

    local getFromMesa = function(resource)
        local success, jsonStr = mesaApi.request('company', resource, {CompanyID=fileContents.CompanyID, LocationID=fileContents.LocationID})
        if success == false then
            return nil
        else
            return json.parse(jsonStr)
        end
    end

    local railcars = getFromMesa('Railcar/GetForShippingReceiving')
    local purchaseOrders = getFromMesa('PurchaseOrder/GetAllRelatedToLocation')
    if railcars == nil or purchaseOrders == nil then
        term.clearLine()
        term.write('Could not get required information from MesaSuite')
        nl()
        term.write('Press enter to continue')
        term.read()
        return
    end

    for _,railcar in ipairs(railcars) do
        local relatedPurchaseOrder = {}

        for _,purchaseOrder in ipairs(purchaseOrders) do
            for _,purchaseOrderLine in ipairs(purchaseOrder.PurchaseOrderLines) do
                for _,FulfillmentPlanPurchaseOrderLine in ipairs(purchaseOrderLine.FulfillmentPlanPurchaseOrderLines) do
                    if FulfillmentPlanPurchaseOrderLine.FulfillmentPlan.RailcarID == railcar.RailcarID then
                        relatedPurchaseOrder = purchaseOrder
                        break
                    end
                end

                if relatedPurchaseOrder ~= nil then break end
            end

            if relatedPurchaseOrder == nil then
                for _,railcarLoad in ipairs(railcar.RailcarLoads) do
                    if railcarLoad.PurchaseOrderLine.PurchaseOrderID == purchaseOrder.PurchaseOrderID then
                        relatedPurchaseOrder = purchaseOrder
                        break
                    end
                end
            end
        end

        if relatedPurchaseOrder ~= nil and relatedPurchaseOrder.LocationIDDestination == fileContents.LocationID then
            selectedCars[railcar.ReportingMark .. railcar.ReportingNumber] = railcar.RailcarID
        end
    end
end

-- Menu
module.menu = function()
    while true do
        term.clear()

        term.write('Cars to Ship:')
        nl()
        term.write('---------------')
        nl()
        if #selectedCars == 0 then
            term.write('* No cars selected *')
            nl()
        else
            for reportingMark,_ in pairs(selectedCars) do
                term.write(reportingMark)
                nl()
            end
        end
        term.write('---------------')
        nl()
        term.write('1 - Select from Sensor(s)')
        nl()
        term.write('2 - Select from MesaSuite')
        nl()
        term.write('3 - Manual Entry')
        nl()
        term.write('4 - Exit')
        nl()
        term.write('Enter an option:')
        local opt = term.read()
        local optNum = tonumber(opt)

        if optNum == 1 then -- Select from sensors
            -- Process cars from sensors
        elseif optNum == 2 then -- Select from MesaSuite
            processFromMesaSuite()
        elseif optNum == 3 then -- Manual Entry
            -- Process manual entry
        elseif optNum == 4 then -- Exit
            break
        end
    end
end

return module