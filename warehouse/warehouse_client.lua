local component = require('component')
local tunnel = component.tunnel
local event = require('event')
local serialization = require('serialization')
local term = require('term')
local text = require('text')
local filesystem = require('filesystem')

local function nl()
    local _, row = term.getCursor()
    term.setCursor(1, row + 1)
end

local function getResponse()
    while true do
        local eType,_,_,_,_,to,data = event.pull(10, 'modem_message')
        if eType == nil then
            term.write('Server did not respond in time')
            return nil
        end

        if to == tunnel.address then
            return data
        end
    end
end

local function connectToServer()
    term.clear()
    term.write('Waking and connecting to server...')
    tunnel.send('wake')
    
    while true do
        local eType,_,_,_,_,to,data = event.pull(30, 'modem_message')
        if eType == nil then
            nl()
            term.write('The server did not respond in time')
            nl()
            term.write('Press any key to return')
            event.pull('key_down')
            return false
        elseif (to == nil or to == tunnel.address) and data == 'woken' then
            return true
        end
    end
end

local function analyzeReceiving()
    if not component.isAvailable('inventory_controller') then
        term.clear()
        term.write('No inventory controller found')
        nl()
        term.write('Press any key to return')
        event.pull('key_down')
        return
    end

    term.write('Getting all backorders...')
    nl()
    tunnel.send('allbackorders')
    local response = getResponse()
    local backorders = {}
    if response ~= nil then
        backorders = serialization.unserialize(response)
    end

    local hasBackorders = false
    for _,_ in pairs(backorders) do
        hasBackorders = true
        break
    end

    if not hasBackorders then
        term.write('No backorders, no need to analyze')
        nl()
        return
    end

    term.write('Getting all existing orders...')
    nl()
    tunnel.send('allorders')
    response = getResponse()
    local orders = {}

    if response ~= nil then
        orders = serialization.unserialize(response)
    end

    term.write('Consolidating backorder item list...')
    nl()
    local itemList = {}
    for _,backOrderList in pairs(backorders) do
        for _,backOrder in ipairs(backOrderList) do
            table.insert(itemList, backOrder.label)
        end
    end

    local inventory = component.inventory_controller

    term.write('Locating computer inventory...')
    nl()
    local side = -1
    for i=0,5 do
        if inventory.getInventorySize(i) ~= nil then
            side = i
            break
        end
    end

    if side == -1 then
        term.clear()
        term.write('No inventory found')
        nl()
        term.write('Press any key to return')
        event.pull('key_down')
        return
    end

    local inventorySize = inventory.getInventorySize(side)
    for i=1,inventorySize do
        term.clear()
        term.write('Analyzing slot ' .. i .. ' of ' .. inventorySize)
        nl()
        local item = inventory.getStackInSlot(side, i)
        if item ~= nil then
            local isBackorderedItem = false

            for _,itemInItemList in ipairs(itemList) do
                if itemInItemList == item.label then
                    isBackorderedItem = true
                    break
                end
            end

            local backorderItemKnownAs = item.label
            if not isBackorderedItem then
                local page = 0
                while true do
                    term.clear()
                    term.write('Item ' .. item.label .. ' does not match a backorder')
                    nl()
                    term.write('Backordered items:')
                    nl()
                    local _,height = term.getViewport()
                    height = height - 3
                    if #itemList > 0 then
                        local skip = height * page
                        for i=1,height do
                            if #itemList >= skip + i then
                                term.write(itemList[skip + i])
                                nl()
                            else
                                break
                            end
                        end
                    else
                        term.write('None')
                        nl()
                    end

                    term.write('Enter proper item name, prev, next, or blank if no match:')
                    local command = text.trim(term.read({hint=itemList}))
                    if command == 'prev' and page > 0 then
                        page = page - 1
                    elseif command == 'next' and (page + 1) * height <= #itemList then
                        page = page + 1
                    elseif command == '' or command == nil then
                        backorderItemKnownAs = nil
                        break
                    else
                        for _,itemInItemList in ipairs(itemList) do
                            if itemInItemList == command then
                                backorderItemKnownAs = command
                                break
                            end
                        end
                    end
                end
            end

            if backorderItemKnownAs ~= nil then
                local receivedSize = item.size
                for storeName,backorderList in pairs(backorders) do
                    for backOrderItemIndex,backorderItem in ipairs(backorderList) do
                        if backorderItem.label == backorderItemKnownAs then
                            local amountToOrder = backorderItem.amount
                            if amountToOrder > receivedSize then
                                amountToOrder = receivedSize
                            end

                            local existingOrder = orders[storeName]
                            local existingOrderItem = nil
                            if existingOrder ~= nil then
                                for _,orderItem in ipairs(existingOrder) do
                                    if orderItem.name == item.name then
                                        amountToOrder = orderItem.amount + amountToOrder
                                        existingOrderItem = orderItem
                                        break
                                    end
                                end
                            end

                            tunnel.send('order', serialization.serialize({storeName=storeName, name=item.name, amount=amountToOrder, ignoreItemOnHand=true}))
                            response = getResponse()
                            if response ~= nil then
                                local dataTable = serialization.unserialize(response)
                                if dataTable.success then
                                    receivedSize = receivedSize - amountToOrder
                                    tunnel.send('backorder', serialization.serialize({storeName=storeName, label=item.label, amount=backorderItem.amount - amountToOrder}))
                                    getResponse()
                                    backorderItem.amount = backorderItem.amount - amountToOrder
                                    if backorderItem.amount <= 0 then
                                        table.remove(backorderList, backOrderItemIndex)
                                    end

                                    if existingOrderItem ~= nil then
                                        existingOrderItem.amount = existingOrderItem.amount + amountToOrder
                                    end
                                else
                                    term.write('Failed to order ' .. item.name .. ' for ' .. storeName)
                                    nl()
                                    term.write(dataTable.errorMessage)
                                    nl()
                                    nl()
                                    term.write('Press any key to continue...')
                                    event.pull('key_down')
                                end
                            else
                                term.write('nil response from server during order')
                                nl()
                                nl()
                                term.write('Press any key to continue...')
                                event.pull('key_down')
                            end

                            if receivedSize <= 0 then
                                break
                            end
                        end
                    end

                    if receivedSize <= 0 then
                        break
                    end
                end
            end
        end
    end

    term.clear()
    term.write('Receiving analysis complete.')
    nl()
    nl()
    term.write('Press any key to return')
    event.pull('key_down')
end

local function getPickListData()
    term.clear()
    term.write('Getting pick list data...')
    nl()
    tunnel.send('allorders')
    local response = getResponse()
    local picklistData = {}
    if response ~= nil then
        local dataTable = serialization.unserialize(response)
        for storeName,orderList in pairs(dataTable) do
            for _,order in ipairs(orderList) do
                if picklistData[order.name] == nil then
                    picklistData[order.name] = {}
                end

                table.insert(picklistData[order.name], {storeName=storeName, amount=order.amount})
            end
        end
    end

    return picklistData
end

local function printPickList()
    term.clear()
    if not component.isAvailable('openprinter') then
        term.write('No printer found')
        nl()
        term.write('Press any key to return')
        event.pull('key_down')
        return
    end

    local printer = component.openprinter
    if printer.getPaperLevel() <= 0 then
        term.write('Printer out of paper')
        nl()
        term.write('Press any key to return')
        event.pull('key_down')
        return
    end

    local picklistData = getPickListData()
    term.write('Printing...')
    printer.setTitle('Pick List')
    printer.writeln('PICK LIST', 0, 'center')
    printer.writeln()
    
    for itemName,storeDatum in pairs(picklistData) do
        printer.writeln('§l' .. itemName)
        for _,storeData in ipairs(storeDatum) do
            printer.writeln('- ' .. storeData.amount .. ' @ ' .. storeData.storeName)
        end
        printer.writeln()
    end

    printer.print()

    term.write('Print complete!')
    nl()
    term.write('Press any key to return')
    event.pull('key_down')
end

local function completePickList()
    term.clear()
    local picklistData = getPickListData()
    term.clear()

    for item,storeDatum in pairs(picklistData) do
        for _,storeData in ipairs(storeDatum) do
            term.write('Item: ' .. item)
            nl()
            term.write('Store: ' .. storeData.storeName)
            nl()
            term.write('Requested Amount: ' .. storeData.amount)
            nl()
            nl()
            term.write('Enter picked amount:')
            local pickedAmount = tonumber(text.trim(term.read()))
            if pickedAmount ~= nil and pickedAmount > 0 then
                term.write('Completing order...')
                tunnel.send('order', serialization.serialize({storeName=storeData.storeName, name=item, amount=storeData.amount - pickedAmount}))
                getResponse()
            end
        end
    end

    term.clear()
    term.write('Pick list complete!')
    nl()
    term.write('Press any key to return')
    event.pull('key_down')
end

local function viewBackorders()
    local function getOriginalBackorders()
        term.clear()
        term.write('Getting backorders...')

        tunnel.send('allbackorders')
        local response = getResponse()
        local backorders = {}
        if response ~= nil then
            backorders = serialization.unserialize(response)
        end

        local itemAmounts = {}
        for _,backorderList in pairs(backorders) do
            for _,backorder in ipairs(backorderList) do
                if itemAmounts[backorder.label] == nil then
                    itemAmounts[backorder.label] = 0
                end

                itemAmounts[backorder.label] = itemAmounts[backorder.label] + backorder.amount
            end
        end

        return itemAmounts
    end
    local itemAmounts = getOriginalBackorders()

    local function compareBackorders(existingItems)
        if not filesystem.exists('/etc/warehouse/saved_backorders.dat') then
            return existingItems
        end

        local file = io.open('/etc/warehouse/saved_backorders.dat', 'r')
        local savedBackorders = serialization.unserialize(file:read('*a'))
        file:close()

        if savedBackorders == nil then
            return existingItems
        end

        local newItems = {}
        for item,amount in pairs(existingItems) do
            newItems[item] = amount
        end

        for item,amount in pairs(savedBackorders) do
            if newItems[item] ~= nil then
                newItems[item] = newItems[item] - amount
                if newItems[item] <= 0 then
                    newItems[item] = nil
                end
            end
        end

        return newItems
    end

    local function saveBackorders(existingItems)
        filesystem.makeDirectory('/etc/warehouse')
        local file = io.open('/etc/warehouse/saved_backorders.dat', 'w')
        file:write(serialization.serialize(existingItems))
        file:close()
    end

    while true do
        term.clear()

        local hasItems = false
        for item,amount in pairs(itemAmounts) do
            hasItems = true
            term.write(item .. 'x ' .. amount)
            nl()
        end

        if not hasItems then
            term.write('* No Backorders *')
            nl()
        end

        term.write('Enter command (compare, save, back):')
        local command = text.trim(term.read())
        if command == 'compare' then
            itemAmounts = compareBackorders(itemAmounts)
        elseif command == 'save' then
            saveBackorders(getOriginalBackorders())
        elseif command == 'back' then
            return
        end
    end
end

local function pickList()
    while true do
        term.clear()
        term.write('= PICK LIST =')
        nl()
        nl()
        term.write('1 - Print current pick list')
        nl()
        term.write('2 - Complete pick list')
        nl()
        term.write('3 - Return to main menu')
        nl()
        term.write('Enter an option:')
        local opt = tonumber(text.trim(term.read()))
        if opt == 1 then -- Print current pick list
            printPickList()
        elseif opt == 2 then -- Complete pick list
            completePickList()
        elseif opt == 3 then -- Return to main menu
            return
        end
    end
end

local function systemMenu()
    while true do
        term.clear()
        term.write('= WAREHOUSE OPERATIONS =')
        nl()
        nl()
        term.write('NOTE: Server shuts down after 10 minutes of inactivity')
        nl()
        nl()
        term.write('1 - Analyze Receiving')
        nl()
        term.write('2 - Pick List')
        nl()
        term.write('3 - View backorders')
        nl()
        term.write('4 - Disconnect from server')
        nl()
        nl()
        term.write('Enter an option:')
        local opt = tonumber(term.read())
        if opt == 1 then -- Analyze Receiving
            analyzeReceiving()
        elseif opt == 2 then -- Pick List
            pickList()
        elseif opt == 3 then -- View backorders
            viewBackorders()
        elseif opt == 4 then -- Disconnect from server
            tunnel.send('bye')
            return
        end
    end
end

while true do
    term.clear()
    term.write('= WAREHOUSE OPERATIONS =')
    nl()
    nl()
    term.write('1 - Connect to server')
    nl()
    term.write('2 - Close Warehouse Operations')
    nl()
    term.write('3 - Shutdown Computer')
    nl()
    term.write('Enter an option:')
    local opt = tonumber(term.read())
    if opt == 1 then -- Connect to server
        if connectToServer() then
            systemMenu()
        end
    elseif opt == 2 then -- Close system
        return
    elseif opt == 3 then -- Shutdown computer
        component.computer.stop()
        return
    end
end