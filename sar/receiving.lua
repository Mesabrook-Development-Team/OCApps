local term = require('term')
local keyboard = require('keyboard')
local event = require('event')
local filesystem = require('filesystem')
local mesaApi = require('mesasuite_api')
local serialization = require('serialization')
local aei_driver = require('sar/aei_driver')
local text = require('text')
local json = require('json')

local printerAvailable = false
local printerAPI = {}

local module = {}

local function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

local selectedCars = {}

local locationFile = io.open('/etc/sar/loc.cfg', 'r')
local locFileContents = serialization.unserialize(locationFile:read('*a'))
locationFile:close()

local companyID = locFileContents.CompanyID
local locationID = locFileContents.LocationID


-- BOL Stuff
local function performScan()
    local bol = printerAPI.readBOL()

    if bol == nil then
        return
    end

    local success = mesaApi.request('company', 'BillOfLading/AcceptBOL', {BillOfLadingID=bol}, {CompanyID=companyID,LocationID=locationID}, 'POST')

    nl()
    if success then
        term.write('Bill of Lading Accepted')
        os.sleep(2)
    else
        term.write('Bill of Lading Not Accepted')
        nl()
        term.write('Try using MesaSuite instead')
        nl()
        nl()
        term.write('Press any key to acknowledge')
        term.read()
    end
end

local function acceptBOL()
    local currentOption = 1

    while true do
        term.clear()
        term.write("By scanning a Bill of Lading, you are contractually accepting this railcar as received as described.", true)
        nl()
        nl()
        term.write("Select an option below and press enter")
        nl()
        term.write("[")
        if currentOption == 1 then
            term.write("x")
        else
            term.write(" ")
        end
        term.write("] - Scan page from scanner")
        nl()
        
        term.write("[")
        if currentOption == 2 then
            term.write("x")
        else
            term.write(" ")
        end
        term.write("] - Finish scanning")

        local _,_,_,keyCode = event.pull('key_down')
        if keyCode == keyboard.keys.up and currentOption > 1 then
            currentOption = currentOption - 1
        elseif keyCode == keyboard.keys.down and currentOption < 2 then
            currentOption = currentOption + 1
        elseif keyCode == keyboard.keys.enter then
            if currentOption == 1 then -- Do scan
                performScan()
            elseif currentOption == 2 then -- exit
                return
            end
        end
    end
end

-- Process from AEI
local function processFromAEI()
    local data = aei_driver.scan()
    if data == nil then
        return
    end

    print('Processing data...')
    local aeiData = serialization.unserialize(data)
    local times = {}
    for k in pairs(aeiData) do
        table.insert(times, k)
    end

    table.sort(times)

    term.clear()
    local selectedTime = nil
    while true do
        print('Select a car set by scan time:')
        for i,time in ipairs(times) do
            local timeAgo = (os.time() - time) * 1000 / 60 / 60 / 20
            print(i .. ': ' .. timeAgo .. ' seconds ago (' .. #aeiData[time] .. ' cars)')
        end
        print()

        term.write('Enter an option, or blank to cancel:')
        local opt = text.trim(term.read())
        if opt == nil or opt == '' then
            return
        elseif tonumber(opt) ~= nil and tonumber(opt) <= #times then
            selectedTime = times[tonumber(opt)]
            break
        end
    end

    term.clear()
    print('Looking up selected cars...')
    selectedCars = {}
    for _,railcar in ipairs(aeiData[selectedTime]) do
        print('Looking up ' .. railcar .. '...')
        local success, jsonStr = mesaApi.request('company', 'Railcar/GetByReportingMark/' .. railcar, nil, {CompanyID=companyID, LocationID=locationID})
        if success and jsonStr ~= 'null' then
            local foundRailcar = json.parse(jsonStr)
            if foundRailcar ~= nil and foundRailcar.RailcarID ~= nil then
                selectedCars[railcar] = foundRailcar.RailcarID
            end
        end
    end
end

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

        if relatedPurchaseOrder ~= nil and relatedPurchaseOrder.LocationIDDestination == locationID then
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
            if success == false or jsonStr == 'null' then
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

-- Perform receiving
local function performReceiving()
    local getFromMesa = function(resource)
        local success, jsonStr = mesaApi.request('company', resource, nil, {CompanyID=companyID, LocationID=locationID})
        if success == false or jsonStr == 'null' then
            return nil
        else
            return json.parse(jsonStr)
        end
    end

    while next(selectedCars) ~= nil do
        local reportingMark, railcarID = next(selectedCars)

        local railcar = nil
        local reloadData = function()
            term.clear()
            print('Setting up data for ' .. reportingMark .. '...')
            railcar = getFromMesa('Railcar/Get/' .. railcarID)
            if railcar == nil then
                selectedCars[reportingMark] = nil  
                return
            end
        end

        reloadData()

        if railcar == nil then
            goto continue
        end

        term.clear()
        print(reportingMark)
        print('Track: ' .. railcar.RailLocation.Track.Name)
        print('Position: ' .. railcar.RailLocation.Position)
        print()
        print('Current Loads:')
        print('---------------')
        if #railcar.RailcarLoads == 0 then
            print('* No loads *')
        else
            for loadIndex,load in ipairs(railcar.RailcarLoads) do
                print(loadIndex .. ': ' .. load.Quantity .. 'x ' .. load.Item.Name)
                if load.PurchaseOrderLineID ~= nil then
                    local _, row = term.getCursor()
                    term.setCursor(#tostring(loadIndex) + 2, row)
                    term.write('PO: ' .. load.PurchaseOrderLine.PurchaseOrderID .. ' (' .. getPurchaseOrderLineDisplayString(load.PurchaseOrderLine) .. ')')
                end
            end
        end
        print('---------------')
        print()
        print('Enter a load index to remove, or blank to continue:')
        ::continue::
    end
end

-- Main Menu
module.menu = function()
    while true do
        term.clear()

        term.write('* RECEIVING MENU *')
        nl()
        nl()
        term.write('Selected Cars:')
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
        term.write('1 - Accept Bills Of Lading')
        if not printerAvailable then
           term.write(' (Printer Unavailable)')
        end
        nl()
        term.write('2 - Start AEI Sensor Server')
        nl()
        term.write('3 - Select from MesaSuite')
        nl()
        term.write('4 - Manual Entry')
        nl()
        term.write('5 - Perform Receiving')
        nl()
        term.write('6 - Return to Main Menu')
        nl()
        nl()
        term.write('Enter an option:')
        local opt = term.read()
        local optNum = tonumber(opt)

        if optNum == 1 and printerAvailable then -- Accept BOL
            acceptBOL()
        elseif optNum == 2 then -- Cars from sensors
            processFromAEI()
        elseif optNum == 3 then -- Cars from mesasuite
            processFromMesaSuite()
        elseif optNum == 4 then -- Manual Entry
            processManualEntry()
        elseif optNum == 5 then -- Perform Receiving
            performReceiving()
        elseif optNum == 6 then -- Exit
            return
        end
    end
end

filesystem.makeDirectory('/etc/sar')
if not filesystem.exists('/etc/sar/printer.cfg') then
   local file = io.open('/etc/sar/printer.cfg', 'w')
   file:write('sar/openprinter')
   file:close()
end

local file = io.open('/etc/sar/printer.cfg', 'r')
printerAPI = require(file:read('*a'))
file:close()

printerAvailable = printerAPI.isPrinterAvailable()

return module