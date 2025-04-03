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

local locFileContents = {}

if filesystem.exists('/etc/sar/loc.cfg') then
    local file = io.open('/etc/sar/loc.cfg', 'r')
    locFileContents = serialization.unserialize(file:read('*a'))
    file:close()

    if locFileContents == nil then
        locFileContents = {}
    end
end

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

        if relatedPurchaseOrder ~= nil and relatedPurchaseOrder.LocationIDOrigin == locationID then
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

local function getPurchaseOrderLineDisplayString(purchaseOrderLine)
    if purchaseOrderLine == nil then
        return ''
    end

    if purchaseOrderLine.IsService then
        return purchaseOrderLine.ServiceDescription
    end

    local retVal = purchaseOrderLine.Quantity .. 'x '
    if purchaseOrderLine.ItemID ~= nil then
        retVal = retVal .. purchaseOrderLine.Item.Name

        if purchaseOrderLine.ItemDescription ~= nil and purchaseOrderLine.ItemDescription ~= '' then
            retVal = retVal .. ' - '
        end
    end

    if purchaseOrderLine.ItemDescription ~= nil and purchaseOrderLine.ItemDescription ~= '' then
        retVal = retVal .. purchaseOrderLine.ItemDescription
    end

    return retVal
end

local function acceptMultipleBOLs(bols)
    print('Accepting Bills Of Lading...')

    local allSuccessful = true
    for _,bol in ipairs(bols) do
       local success = mesaApi.request('company', 'BillOfLading/AcceptBOL', json.stringify({BillOfLadingID = bol}), {CompanyID=companyID, LocationID=locationID}, 'POST')
       if not success then
           allSuccessful = false
       end
    end

    if not allSuccessful then
        term.write('Could not accept all Bills of Lading')
        nl()
        term.write('Press any key to continue')
        term.pull('key_down')
    end
end

local function clearRailcarLoads(railcarLoads)
    while true do
        term.clear()
        print('Railcar Loads')
        print('-------------')

        if #railcarLoads == 0 then
            print('* No loads *')
        else
            for loadIndex,load in ipairs(railcarLoads) do
                print(loadIndex .. ': ' .. load.Quantity .. 'x ' .. load.Item.Name)
                if type(load.PurchaseOrderLineID) ~= "table" and load.PurchaseOrderLineID ~= nil then
                    local _, row = term.getCursor()
                    term.setCursor(#tostring(loadIndex) + 3, row)
                    print('PO: ' .. load.PurchaseOrderLine.PurchaseOrderID .. ' (' .. getPurchaseOrderLineDisplayString(load.PurchaseOrderLine) .. ')')
                end
            end
        end
        print('-------------')
        print() 
        term.write("Enter load to clear, 'a' for all, or blank to return:")

        local opt = text.trim(term.read())
        if opt == nil or opt == '' then
            return
        end

        if opt == 'a' then
            local clearAllSuccess = true
            for loadIndex,load in ipairs(railcarLoads) do
                local success = mesaApi.request('company', 'Railcar/DeleteRailcarLoad/' .. load.RailcarLoadID, nil, {CompanyID=companyID, LocationID=locationID}, 'DELETE')
                if not success then
                    clearAllSuccess = false
                else
                    railcarLoads[loadIndex] = nil
                end
            end

            if not clearAllSuccess then
                term.write('Could not clear all loads')
                nl()
                term.write('Press any key to continue')
                term.pull('key_down')
            end
        end

        local optNum = tonumber(opt)
        if optNum ~= nil and optNum > 0 and optNum <= #railcarLoads then
            local success = mesaApi.request('company', 'Railcar/DeleteRailcarLoad/' .. railcarLoads[optNum].RailcarLoadID, nil, {CompanyID=companyID, LocationID=locationID}, 'DELETE')
            if not success then
                term.write('Could not clear load')
                nl()
                term.write('Press any key to continue')
                term.pull('key_down')
            else
                railcarLoads[optNum] = nil
            end
        end
    end
end

local function completeReceivingProcess(railcarID)
    local success = mesaApi.request('company', 'Railcar/CompleteReceivingProcess', json.stringify({RailcarID=railcarID}), {CompanyID=companyID, LocationID=locationID}, 'POST')
    if not success then
        term.write('Could not complete receiving process')
        nl()
        term.write('Press any key to continue')
        term.pull('key_down')
    end
end

local function releaseCar(reportingMark, railcarID, releaseableInformation)
    local payload = {
        RailcarID=railcarID,
        CompanyIDReleaseTo=releaseableInformation.CompanyIDTo,
        GovernmentIDReleaseTo=releaseableInformation.GovernmentIDTo
    }

    local success = mesaApi.request('company', 'Railcar/Release', json.stringify(payload), {CompanyID=companyID, LocationID=locationID}, 'POST')
    if not success then
        term.write('Could not release railcar')
        nl()
        term.write('Press any key to continue')
        term.pull('key_down')
    else
        selectedCars[reportingMark] = nil
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

        local railcar
        local billsOfLading
        local releaseableInformation
        local notCompleted
        local hasFulfillmentPlan
        local reloadData = function()
            railcar = nil
            billsOfLading = nil
            releaseableInformation = nil
            notCompleted = false
            hasFulfillmentPlan = false

            term.clear()
            print('Setting up data for ' .. reportingMark .. '...')
            railcar = getFromMesa('Railcar/Get/' .. railcarID)
            if railcar == nil then
                selectedCars[reportingMark] = nil  
                return
            end

            local bols = getFromMesa('BillOfLading/GetByRailcar/' .. railcarID)
            if bols ~= nil then
                billsOfLading = {}
                for _,bol in ipairs(bols) do
                    if bol.CompanyIDConsignee == companyID then
                        table.insert(billsOfLading, bol.BillOfLadingID)
                    end
                end
            end

            local fulfillmentPlan = getFromMesa('FulfillmentPlan/GetByRailcar/' .. railcarID)
            hasFulfillmentPlan = fulfillmentPlan ~= nil
            if fulfillmentPlan ~= nil and #fulfillmentPlan.FulfillmentPlanRoutes > 0 then
                releaseableInformation = {}

                table.sort(fulfillmentPlan.FulfillmentPlanRoutes, function (a, b)
                    return a.SortOrder > b.SortOrder
                end)

                local lastRoute = fulfillmentPlan.FulfillmentPlanRoutes[1]
                if type(lastRoute.GovernmentIDTo) ~= "table" and lastRoute.GovernmentIDTo ~= nil then
                    releaseableInformation.GovernmentIDTo = lastRoute.GovernmentIDTo
                    releaseableInformation.To = lastRoute.GovernmentTo.Name
                elseif type(lastRoute.CompanyIDTo) ~= "table" and lastRoute.CompanyIDTo ~= nil then
                    releaseableInformation.CompanyIDTo = lastRoute.CompanyIDTo
                    releaseableInformation.To = lastRoute.CompanyTo.Name
                end
            end

            local railcarLoads = railcar.RailcarLoads
            if railcarLoads == nil then
                railcarLoads = {}
            end

            for _,railcarLoad in ipairs(railcarLoads) do
                if type(railcarLoad.PurchaseOrderLineID) ~= "table" and railcarLoad.PurchaseOrderLineID ~= nil then
                    notCompleted = true
                    break
                end
            end

            if not notCompleted then
                notCompleted = railcar.TrackDestination.CompanyIDOwner == companyID
            end
        end

        reloadData()

        if railcar == nil then
            goto continue
        end

        term.clear()
        print(reportingMark)
        if type(railcar.RailcarLocation.Track.Name) ~= "table" then
            term.write('Track: ' .. railcar.RailLocation.Track.Name)
        elseif type(railcar.RailLocation.Train.TrainSymbol.Name) ~= "table" then
            term.write('Train: ' .. railcar.RailLocation.Train.TrainSymbol.Name)
        end
        print('Position: ' .. railcar.RailLocation.Position)
        print()
        print('Current Loads:')
        print('---------------')
        if #railcar.RailcarLoads == 0 then
            print('* No loads *')
        else
            for loadIndex,load in ipairs(railcar.RailcarLoads) do
                print(loadIndex .. ': ' .. load.Quantity .. 'x ' .. load.Item.Name)
                if type(load.PurchaseOrderLineID) ~= "table" and load.PurchaseOrderLineID ~= nil then
                    local _, row = term.getCursor()
                    term.setCursor(#tostring(loadIndex) + 3, row)
                    print('PO: ' .. load.PurchaseOrderLine.PurchaseOrderID .. ' (' .. getPurchaseOrderLineDisplayString(load.PurchaseOrderLine) .. ')')
                end
            end
        end
        print('---------------')
        print()
        local opts = {}

        if not hasFulfillmentPlan then
            print('** Marking car unloaded will send it to final destination')
        end

        print()
        if billsOfLading ~= nil and #billsOfLading > 0 then
            print('1 - Accept Bills Of Lading')
            print('2 - Next Railcar')
            print('3 - Exit')

            table.insert(opts, function() acceptMultipleBOLs(billsOfLading); return false end)
            table.insert(opts, function() selectedCars[reportingMark] = nil; return false end)
            table.insert(opts, function() return true end)
        else
            local currentOptionIndex = 1

            if notCompleted then
                print(currentOptionIndex .. ' - Clear Railcar Load(s)')
                table.insert(opts, function() 
                    clearRailcarLoads(railcar.RailcarLoads);
                    if #railcar.RailcarLoads <= 0 and not hasFulfillmentPlan then
                        selectedCars[reportingMark] = nil
                    end
                    return false
                end)
                currentOptionIndex = currentOptionIndex + 1

                print(currentOptionIndex .. ' - Complete Receiving Process')
                table.insert(opts, function() completeReceivingProcess(railcarID); return false end)
                currentOptionIndex = currentOptionIndex + 1
            end

            if releaseableInformation ~= nil then
                print(currentOptionIndex .. ' - Release to ' .. releaseableInformation.To)
                table.insert(opts, function() releaseCar(reportingMark, railcarID, releaseableInformation); return false end)
                currentOptionIndex = currentOptionIndex + 1
            end

            print(currentOptionIndex .. ' - Next Railcar')
            table.insert(opts, function() selectedCars[reportingMark] = nil; return false end)
            currentOptionIndex = currentOptionIndex + 1

            print(currentOptionIndex .. ' - Exit')
            table.insert(opts, function() return true end)
        end
        print()
        term.write('Enter an option:')
        local opt = tonumber(text.trim(term.read()))

        if opt ~= nil then
            local optFunc = opts[opt]
            if optFunc ~= nil then
                local result = optFunc()
                if result == true then
                    return
                end
            end
        end
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