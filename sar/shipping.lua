local term = require('term')
local serialization = require('serialization')
local mesaApi = require('mesasuite_api')
local json = require('json')
local text = require('text')
local colors = require('colors')
local modem = require('component').modem
local event = require('event')
local filesystem = require('filesystem')

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

-- Process from AEI
local function processFromAEI()
    if modem == nil then
        print('No modem found')
        print()
        term.write('Press any key to continue')
        term.pull('key_down')
        return
    end

    term.clear()
    print('Looking up sensor server...')

    local config = {}

    if filesystem.exists('/etc/sar/aei.cfg') then
        local file = io.open('/etc/sar/aei.cfg', 'r')
        config = serialization.unserialize(file:read('*a'))
        file:close()
    end

    if config == nil or config.address == nil or config.address == '' or config.port == nil or tonumber(config.port) == nil then
        print('Sensor server configuration not found or corrupted')
        print()
        local opt = nil

        repeat
            term.clearLine()
            term.write('Do you want to configure now? (y/n)')
            local opt = text.trim(term.read())
            if opt == 'y' then
                break
            elseif opt == 'n' then 
                return
            end
        until false

        term.clear()
        local address = nil
        repeat
            term.write('Enter sensor server address:')
            address = text.trim(term.read())
        until address ~= nil and address ~= ''

        local port = nil
        repeat
            term.write('Enter sensor server port:')
            port = text.trim(term.read())
        until port ~= nil and tonumber(port) ~= nil

        port = tonumber(port)
        config = {address=address, port=port}

        local file = io.open('/etc/sar/aei.cfg', 'w')
        file:write(serialization.serialize(config))
        file:close()
    end

    term.clear()
    print('Opening port...')
    if not modem.open(config.port) then
        print('Could not open port ' .. config.port)
        print()
        term.write('Press any key to return')
        term.pull('key_down')
        return
    end

    print('Waking sensor server...')
    modem.send(config.address, config.port, 'wake')
    local _, _, from = event.pull(15, 'modem_message')

    if from == nil then
        modem.close(config.port)

        print('Sensor server did not respond in time')
        print()
        term.write('Press any key to return')
        term.pull('key_down')
        return
    end

    print('Getting data from server...')
    modem.send(config.address, config.port, 'list')
    local _, _, from, port, _, data = event.pull('modem_message')
    if from == nil then
        modem.close(config.port)
        print('Sensor server did not respond in time')
        print()
        term.write('Press any key to return')
        term.pull('key_down')
        return
    end

    print('Shutting server down...')
    modem.send(config.address, config.port, 'bye')
    modem.close(config.port)

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
            local timeAgo = os.time() - time
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
        print('Looking up ' .. railcar '...')
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

-- Perform loading
local function selectPurchaseOrderLine(selectablePurchaseOrderLines)
    while true do
        term.clear()
        term.write('Select a Purchase Order Line:')
        nl()
        term.write('---------------------------')
        nl()
        for i,purchaseOrderLine in ipairs(selectablePurchaseOrderLines) do
            term.write(i .. ' - PO: ' .. purchaseOrderLine.PurchaseOrderID .. ' (' .. purchaseOrderLine.PurchaseOrderLineID .. ')')
            nl()
        end
        term.write('---------------------------')
        nl()
        term.write('Enter a number, or blank for none:')
        local opt = text.trim(term.read())
        if opt == '' then
            return nil
        else
            local optNum = tonumber(opt)
            if optNum ~= nil and optNum > 0 and optNum <= #selectablePurchaseOrderLines then
                return selectablePurchaseOrderLines[optNum]
            end
        end
    end
end

local function selectItem()
    local itemResults = {}
    local firstRun = true
    while true do
        term.clear()
        if not firstRun then
            if #itemResults == 0 then
                term.write('No items found')
            else
                for i,item in ipairs(itemResults) do
                    term.write(i .. ' - ' .. item.Name)
                    nl()
                end
            end
        end
        firstRun = false

        term.write('Enter selection, query for item, or blank to cancel:')
        local query = text.trim(term.read())
        if query == '' then
            return nil
        elseif tonumber(query) ~= nil then
            local selection = tonumber(query)
            if selection > 0 and selection <= #itemResults then
                return itemResults[selection]
            end
        else
            local function urlEncode(str)
                return (str:gsub("[^%w%-._~]", function(c)
                    return string.format("%%%02X", string.byte(c))
                end))
            end

            local _,height = term.getViewport()
            local success, jsonStr = mesaApi.request('company', 'Item/GetByQuery?q=' .. urlEncode(query) .. '&t=' .. height - 2, nil, {CompanyID=companyID, LocationID=locationID})
            if success == false or jsonStr == 'null' then
                itemResults = {}
            else
                itemResults = json.parse(jsonStr)
            end
        end
    end
end

local function selectQuantity()
    while true do
        term.clear()
        term.write('Enter quantity, or blank to cancel:')
        local quantity = text.trim(term.read())
        if quantity == '' then
            return nil
        elseif tonumber(quantity) ~= nil then
            return quantity
        end
    end
end

local function addLoadToRailcar(railcarID, purchaseOrderLine, item, quantity)
    if railcarID == nil or item == nil or item.ItemID == nil or quantity == nil or tonumber(quantity) == nil then
        term.write('An Item and Quantity must be selected')
        nl()
        term.write('Press enter to continue')
        nl()
        term.read()
        return false
    end

    local purchaseOrderLineID = nil
    if purchaseOrderLine ~= nil and purchaseOrderLine.PurchaseOrderLineID ~= nil then
        purchaseOrderLineID = purchaseOrderLine.PurchaseOrderLineID
    end

    local railcarLoad = {
        RailcarID = railcarID,
        ItemID = item.ItemID,
        Quantity = quantity,
        PurchaseOrderLineID = purchaseOrderLineID
    }

    local success, jsonStr = mesaApi.request('company', 'Railcar/Load', json.serialize(railcarLoad), {CompanyID=companyID, LocationID=locationID}, 'POST')
    if success == false or jsonStr == 'null' then
        term.write('Failed to add load to Railcar')
        nl()
        term.write('Press enter to continue')
        nl()
        term.read()
        return false
    end

    return true
end

local function finalizeLoading(railcar)
    -- Get current time
    local internet = require('internet')
    local handle = internet.request('http://worldtimeapi.org/api/timezone/America/Chicago')

    local response = ''
    for chunk in handle do response = response .. chunk end

    local timeInfo = json.parse(response)

    local fulfillmentIDs = {}

    for _,load in ipairs(railcar.RailcarLoads) do
        if load.PurchaseOrderLineID == nil or load.Quantity == nil or load.Quantity <= 0 then
            goto continue
        end

        local fulfillment = {
            RailcarID = railcar.RailcarID,
            PurchaseOrderLineID = load.PurchaseOrderLineID,
            Quantity = load.Quantity,
            FulfillmentTime = timeInfo.datetime
        }

        local success, jsonStr = mesaApi.request('company', 'Fulfillment/Post', json.serialize(fulfillment), {CompanyID=companyID, LocationID=locationID}, 'POST')
        if success and jsonStr ~= 'null' then
            local savedFulfillment = json.parse(jsonStr)
            table.insert(fulfillmentIDs, savedFulfillment.FulfillmentID)
        end

        ::continue::
    end

    if #fulfillmentIDs > 0 then
       mesaApi.request('company', 'Fulfillment/IssueBillsOfLading', json.serialize(fulfillmentIDs), {CompanyID=companyID, LocationID=locationID}, 'POST')
    else
        term.write('Finalizing is not possible without at least one load issued to a Purchase Order')
        nl()
        term.write('Press enter to continue')
        nl()
        term.read()
    end
end

local function releaseRailcar(railcar, releaseableInformation)
    local releaseInfo = {
        RailcarID = railcar.RailcarID,
        CompanyIDReleaseTo = releaseableInformation.CompanyIDTo,
        GovernmentIDReleaseTo = releaseableInformation.GovernmentIDTo
    }

    local success = mesaApi.request('company', 'Railcar/Release', json.serialize(releaseInfo), {CompanyID=companyID, LocationID=locationID}, 'POST')
    if success == false then
        term.write('Failed to release railcar')
        nl()
        term.write('Press enter to continue')
        nl()
        term.read()
    end
    return success
end

local function performLoading()
    local function getFromMesa(resource)
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
        local loadedQuantity = 0
        local releasebleInformation = {mustRelease = false}
        local selectablePurchaseOrderLines = {}
        local selectedPurchaseOrderLine = nil
        local selectedItem = nil
        local selectedQuantity = 0

        local function reloadData()
            term.clear()
            term.write('Setting up data for ' .. reportingMark .. '...')
            nl()

            railcar = getFromMesa('Railcar/Get/' .. railcarID)
            if railcar == nil then
                selectedCars[reportingMark] = nil  
                return
            end

            for _,load in ipairs(railcar.RailcarLoads) do
                loadedQuantity = loadedQuantity + load.Quantity
            end


            local fulfillments = getFromMesa('Fulfillment/GetCurrentByRailcar/' .. railcarID)
            if fulfillments ~= nil and #fulfillments > 0 then
                releasebleInformation.mustRelease = true
                if #railcar.RailcarRoutes > 0 then
                    table.sort(railcar.RailcarRoutes, function (a, b)
                    return a.SortOrder < b.SortOrder
                    end)

                    local firstRoute = railcar.RailcarRoutes[1]
                    if firstRoute.GovernmentIDTo ~= nil then
                        releasebleInformation.To = firstRoute.GovernmentTo.Name
                    elseif firstRoute.CompanyIDTo ~= nil then
                        releasebleInformation.To = firstRoute.CompanyTo.Name
                    end
                    releasebleInformation.CompanyIDTo = firstRoute.CompanyIDTo
                    releasebleInformation.GovernmentIDTo = firstRoute.GovernmentIDTo
                else
                    local fulfillmentPlan = getFromMesa('FulfillmentPlan/GetByRailcar/' .. railcarID)
                    if fulfillmentPlan ~= nil and #fulfillmentPlan.FulfillmentPlanRoutes > 0 then
                        table.sort(fulfillmentPlan.FulfillmentPlanRoutes, function (a, b)
                            return a.SortOrder < b.SortOrder
                        end)

                        local firstRoute = fulfillmentPlan.FulfillmentPlanRoutes[1]
                        if firstRoute.GovernmentIDTo ~= nil then
                            releasebleInformation.To = firstRoute.GovernmentTo.Name
                        elseif firstRoute.CompanyIDTo ~= nil then
                            releasebleInformation.To = firstRoute.CompanyTo.Name
                        end
                        releasebleInformation.CompanyIDTo = firstRoute.CompanyIDTo
                        releasebleInformation.GovernmentIDTo = firstRoute.GovernmentIDTo
                    end
                end
            else
                local purchaseOrders = getFromMesa('PurchaseOrder/GetAllRelatedToLocation')
                local suggestedPurchaseOrderLine = nil
                if purchaseOrders ~= nil and #purchaseOrders > 0 then
                    local i = 1
                    while i <= #purchaseOrders do
                        local purchaseOrder = purchaseOrders[i]
                    
                        if purchaseOrder.LocationIDDestination ~= locationID then
                            table.remove(purchaseOrders, i)
                        else
                            i = i + 1
                        end
                    end

                    table.sort(purchaseOrders, function(a,b)
                        return a.PurchaseOrderDate < b.PurchaseOrderDate
                    end)

                    for _,purchaseOrder in ipairs(purchaseOrders) do
                        for _,purchaseOrderLine in ipairs(purchaseOrder.PurchaseOrderLines) do
                            table.insert(selectablePurchaseOrderLines, purchaseOrderLine)

                            local incompleteFulfillmentQuantity = 0
                            local fulfillmentQuantity = 0
                            for _,fulfillment in ipairs(purchaseOrderLine.Fulfillments) do
                                if not fulfillment.IsComplete then
                                    incompleteFulfillmentQuantity = incompleteFulfillmentQuantity + fulfillment.Quantity
                                end
                                fulfillmentQuantity = fulfillmentQuantity + fulfillment.Quantity
                            end

                            local railcarLoadQuantity = 0
                            for _,railcarLoad in ipairs(purchaseOrderLine.RailcarLoads) do
                                railcarLoadQuantity = railcarLoadQuantity + railcarLoad.Quantity
                            end

                            local loadQuantityWithoutFulfillment = math.max(railcarLoadQuantity - incompleteFulfillmentQuantity, 0)

                            local poLineHasFulfillmentPlanForRailcar = false
                            for _,fulfillmentPlanPurchaseOrderLine in ipairs(purchaseOrderLine.FulfillmentPlanPurchaseOrderLines) do
                                poLineHasFulfillmentPlanForRailcar = fulfillmentPlanPurchaseOrderLine.FulfillmentPlan.RailcarID == railcarID
                                if poLineHasFulfillmentPlanForRailcar then break end
                            end

                            local unfulfilledQuantity = purchaseOrderLine.Quantity - fulfillmentQuantity
                            if suggestedPurchaseOrderLine == nil and
                                    unfulfilledQuantity - loadQuantityWithoutFulfillment > 0 and
                                    poLineHasFulfillmentPlanForRailcar then
                                suggestedPurchaseOrderLine = purchaseOrderLine
                            end
                        end
                    end

                    if suggestedPurchaseOrderLine ~= nil then
                        local incompleteFulfillmentQuantity = 0
                        local fulfillmentQuantity = 0
                        for _,fulfillment in ipairs(suggestedPurchaseOrderLine.Fulfillments) do
                            if not fulfillment.IsComplete then
                                incompleteFulfillmentQuantity = incompleteFulfillmentQuantity + fulfillment.Quantity
                            end

                            fulfillmentQuantity = fulfillmentQuantity + fulfillment.Quantity
                        end

                        local railcarLoadQuantity = 0
                        for _,railcarLoad in ipairs(suggestedPurchaseOrderLine.RailcarLoads) do
                            railcarLoadQuantity = railcarLoadQuantity + railcarLoad.Quantity
                        end

                        local alreadyFulfilledAmount = math.max(railcarLoadQuantity - incompleteFulfillmentQuantity, 0)
                        
                        selectedPurchaseOrderLine = suggestedPurchaseOrderLine
                        selectedItem = suggestedPurchaseOrderLine.Item

                        local unfulfilledQuantity = suggestedPurchaseOrderLine.Quantity - fulfillmentQuantity
                        local suggestedQuantity = unfulfilledQuantity - alreadyFulfilledAmount
                        if suggestedQuantity > railcar.RailcarModel.CargoCapacity - loadedQuantity then
                            suggestedQuantity = railcar.RailcarModel.CargoCapacity - loadedQuantity
                        end

                        suggestedQuantity = math.max(suggestedQuantity, 0)

                        selectedQuantity = suggestedQuantity
                    end
                end
            end
        end

        reloadData()

        if railcar == nil then
            goto continue
        end
        
        while true do
            term.clear()
            term.write(reportingMark)
            nl()
            term.write('Track: ' .. railcar.RailLocation.Track.Name)
            nl()
            term.write('Position: ' .. railcar.RailLocation.Position)
            nl()
            nl()
            term.write('Current Loads:')
            nl()
            term.write('---------------')
            nl()
            if #railcar.RailcarLoads == 0 then
                term.write('* No loads *')
                nl()
            else
                for loadIndex,load in ipairs(railcar.RailcarLoads) do
                    term.write(loadIndex .. ': ' .. load.Quantity .. 'x ' .. load.Item.Name)
                    nl()
                    if load.PurchaseOrderLineID ~= nil then
                        local _, row = term.getCursor()
                        term.setCursor(#tostring(loadIndex) + 2, row)
                        term.write('PO: ' .. load.PurchaseOrderLine.PurchaseOrderID .. ' (' .. getPurchaseOrderLineDisplayString(load.PurchaseOrderLine) .. ')')
                    end
                end
            end
            term.write('---------------')
            nl()
            if releasebleInformation.mustRelease then
                term.write('1 - Relase to ' .. releasebleInformation.To)
                nl()
                term.write('2 - Next Railcar')
                nl()
                term.write('3 - Exit')
                nl()
                nl()
                term.write('Enter an option:')
                local opt = tonumber(text.trim(term.read()))

                if opt == 1 then -- Release
                    if releaseRailcar(railcar, releasebleInformation) then
                        selectedCars[reportingMark] = nil
                        break
                    end
                elseif opt == 2 then -- Next railcar
                    selectedCars[reportingMark] = nil
                    break
                elseif opt == 3 then -- Exit
                    return
                end

            else
                term.write('LOAD DETAILS:')
                nl()
                term.write('For PO: ' )
                if selectedPurchaseOrderLine ~= nil then
                    term.write(selectedPurchaseOrderLine.PurchaseOrderID .. ' (' .. getPurchaseOrderLineDisplayString(selectedPurchaseOrderLine) .. ')')
                else
                    term.write('[None]')
                end
                nl()

                term.write('Item: ')
                if selectedItem ~= nil then
                    term.write(selectedItem.Name)
                else
                    local oldFore = term.gpu().getForeground()
                    term.gpu().setForeground(colors.red)
                    term.write('[None]')
                    term.gpu().setForeground(oldFore)
                end
                nl()

                term.write('Quantity: ' .. selectedQuantity)
                nl()
                nl()

                term.write('1 - Change Purchase Order Line')
                nl()
                term.write('2 - Change Item')
                nl()
                term.write('3 - Change Quantity')
                nl()
                term.write('4 - Add Load To Railcar')
                nl()
                term.write('6 - Finalize Loading')
                nl()
                term.write('6 - Next Railcar')
                nl()
                term.write('7 - Exit')
                nl()
                nl()
                term.write('Enter an option:')
                local opt = term.read()
                local optNum = tonumber(opt)
                if optNum == 1 then -- Change PO Line
                    local newPOLine = selectPurchaseOrderLine(selectablePurchaseOrderLines)
                    if newPOLine ~= nil then
                        selectedPurchaseOrderLine = newPOLine
                    end
                elseif optNum == 2 then -- Change Item
                    local newItem = selectItem()
                    if newItem ~= nil then
                        selectedItem = newItem
                    end
                elseif optNum == 3 then -- Change Quantity
                    local newQuantity = selectQuantity()
                    if newQuantity ~= nil then
                        selectedQuantity = newQuantity
                    end
                elseif optNum == 4 then -- Add Load To Railcar
                    if addLoadToRailcar(railcar.RailcarID, selectedPurchaseOrderLine, selectedItem, selectedQuantity) then
                        reloadData()
                    end
                elseif optNum == 5 then -- Finalize Loading
                    finalizeLoading(railcar)
                    reloadData()
                elseif optNum == 6 then -- Next Railcar
                    selectedCars[reportingMark] = nil
                    break
                elseif optNum == 7 then -- Exit
                    return
                end
            end
        end
        ::continue::
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
            processFromAEI()
        elseif optNum == 2 then -- Select from MesaSuite
            processFromMesaSuite()
        elseif optNum == 3 then -- Manual Entry
            processManualEntry()
        elseif optNum == 4 then -- Perform Loading
            performLoading()
        elseif optNum == 5 then -- Exit
            break
        end
    end

    selectedCars = {}
end

return module