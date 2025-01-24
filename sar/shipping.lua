local term = require('term')
local serialization = require('serialization')
local mesaApi = require('mesasuite_api')
local json = require('json')
local text = require('text')
local colors = require('colors')

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
        term.clear()
        term.write('Setting up data for ' .. reportingMark .. '...')
        nl()

        local railcar = getFromMesa('Railcar/Get/' .. railcarID)
        if railcar == nil then
            selectedCars[reportingMark] = nil  
            goto continue
        end

        local loadedQuantity = 0
        for _,load in ipairs(railcar.RailcarLoads) do
            loadedQuantity = loadedQuantity + load.Quantity
        end

        local releasebleInformation = {mustRelease = false}
        local selectablePurchaseOrderLines = {}
        local selectedPurchaseOrderLine = nil
        local selectedItem = nil
        local selectedQuantity = 0

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
                        for _,fulfillment in purchaseOrderLine.Fulfillments do
                            if not fulfillment.IsComplete then
                                incompleteFulfillmentQuantity = incompleteFulfillmentQuantity + fulfillment.Quantity
                            end
                        end

                        local railcarLoadQuantity = 0
                        for _,railcarLoad in purchaseOrderLine.RailcarLoads do
                            railcarLoadQuantity = railcarLoadQuantity + railcarLoad.Quantity
                        end

                        local loadQuantityWithoutFulfillment = math.max(railcarLoadQuantity - incompleteFulfillmentQuantity, 0)

                        local poLineHasFulfillmentPlanForRailcar = false
                        for _,fulfillmentPlanPurchaseOrderLine in purchaseOrderLine.FulfillmentPlanPurchaseOrderLines do
                            poLineHasFulfillmentPlanForRailcar = fulfillmentPlanPurchaseOrderLine.FulfillmentPlan.RailcarID == railcarID
                            if poLineHasFulfillmentPlanForRailcar then break end
                        end

                        if suggestedPurchaseOrderLine == nil and
                                purchaseOrderLine.UnfulfilledQuantity - loadQuantityWithoutFulfillment > 0 and
                                poLineHasFulfillmentPlanForRailcar then
                            suggestedPurchaseOrderLine = purchaseOrderLine
                        end
                    end
                end

                if suggestedPurchaseOrderLine ~= nil then
                    local incompleteFulfillmentQuantity = 0
                    for _,fulfillment in suggestedPurchaseOrderLine.Fulfillments do
                        if not fulfillment.IsComplete then
                            incompleteFulfillmentQuantity = incompleteFulfillmentQuantity + fulfillment.Quantity
                        end
                    end

                    local railcarLoadQuantity = 0
                    for _,railcarLoad in suggestedPurchaseOrderLine.RailcarLoads do
                        railcarLoadQuantity = railcarLoadQuantity + railcarLoad.Quantity
                    end

                    local alreadyFulfilledAmount = math.max(railcarLoadQuantity - incompleteFulfillmentQuantity, 0)
                    
                    selectedPurchaseOrderLine = suggestedPurchaseOrderLine
                    selectedItem = suggestedPurchaseOrderLine.Item

                    local suggestedQuantity = suggestedPurchaseOrderLine.UnfulfilledQuantity - alreadyFulfilledAmount
                    if suggestedQuantity > railcar.RailcarModel.CargoCapcity - loadedQuantity then
                        suggestedQuantity = railcar.RailcarModel.CargoCapcity - loadedQuantity
                    end

                    suggestedQuantity = math.max(suggestedQuantity, 0)

                    selectedQuantity = suggestedQuantity
                end
            end
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
            for loadIndex,load in ipairs(railcar.RailcarLoads) do
                term.write(loadIndex .. ': ' .. load.Quantity .. 'x ' .. load.Item.Name)
                nl()
                if load.PurchaseOrderLineID ~= nil then
                    local _, row = term.getCursor()
                    term.setCursor(#tostring(loadIndex) + 2, row)
                    term.write('PO: ' .. load.PurchaseOrderLine.PurchaseOrderID .. ' (' .. getPurchaseOrderLineDisplayString(load.PurchaseOrderLine) .. ')')
                end
            end
            term.write('---------------')
            nl()
            if releasebleInformation.mustRelease then
                
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

                term.write('1 - Change Purchase Order Line')
                nl()
                term.write('2 - Change Item')
                nl()
                term.write('3 - Change Quantity')
                nl()
                term.write('4 - Add Load To Railcar')
                nl()
                term.write('5 - Finalize Loading')
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
                    -- todo: add load
                elseif optNum == 5 then -- Finalize Loading
                    -- todo: finalize loading
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
            -- Process cars from sensors
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