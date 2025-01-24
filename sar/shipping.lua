local term = require('term')
local serialization = require('serialization')
local mesaApi = require('mesasuite_api')
local json = require('json')
local text = require('text')

local companyID = nil
local locationID = nil
local module = {}

local function nl()
    local _, row = term.getCursor()
    local width,height = term.getViewport()
    if row == height then
       local gpu = term.gpu()
       -- Shift all lines up by one
        gpu.copy(1, 2, width, height - 1, 0, -1)

        -- Clear the last line
        gpu.fill(1, height, width, 1, " ")
        term.setCursor(1, height)
    else
        term.setCursor(1, row + 1)
    end
end

local selectedCars = {} -- Key: Reporting Mark, Value: Railcar ID

-- Process from MesaSuite
local function processFromMesaSuite()
    selectedCars = {}
    term.write('Selecting from MesaSuite...')

    local getFromMesa = function(resource)
        local success, jsonStr = mesaApi.request('company', resource, nil, {CompanyID=companyID, LocationID=locationID})
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

-- Process manual entry
local function processManualEntry()
    while true do
        term.clear()
        term.write('Cars to Ship:')
        nl()
        term.write('---------------')
        nl()
        if next(selectedCars) == nil then
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
        term.write('Enter a Reporting Mark, or blank to exit:')
        local reportingMark = text.trim(term.read())

        if reportingMark == '' then
            return
        else
            local success, jsonStr = mesaApi.request('company', 'Railcar/GetByReportingMark/' .. reportingMark, nil, {CompanyID=companyID, LocationID=locationID})
            if success == false then
                term.write('Could not find railcar with that reporting mark')
                nl()
                term.write('Press enter to continue')
                term.read()
            else
                local railcar = json.parse(jsonStr)
                selectedCars[railcar.ReportingMark .. railcar.ReportingNumber] = railcar.RailcarID
            end
        end
    end
end

-- Menu
module.menu = function()
    local locationFile = io.open('/etc/sar/loc.cfg', 'r')
    local fileContents = serialization.unserialize(locationFile:read('*a'))
    locationFile:close()

    companyID = fileContents.CompanyID
    locationID = fileContents.LocationID

    while true do
        term.clear()

        term.write('Cars to Ship:')
        nl()
        term.write('---------------')
        nl()
        if next(selectedCars) == nil then
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
        term.write('4 - Perform Loading')
        nl()
        term.write('5 - Exit')
        nl()
        term.write('Enter an option:')
        local opt = term.read()
        local optNum = tonumber(opt)

        if optNum == 1 then -- Select from sensors
            -- Process cars from sensors
        elseif optNum == 2 then -- Select from MesaSuite
            processFromMesaSuite()
        elseif optNum == 3 then -- Manual Entry
            processManualEntry()
        elseif optNum == 4 then -- Perform Loading
            -- Perform loading
        elseif optNum == 5 then -- Exit
            break
        end
    end

    selectedCars = {}
end

return module