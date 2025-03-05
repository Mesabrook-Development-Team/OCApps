local component = require('component')
local tunnel = component.tunnel
local event = require('event')
local serialization = require('serialization')
local filesystem = require('filesystem')
local term = require('term')
local text = require('text')

local function nl()
    local _, row = term.getCursor()
    term.setCursor(1, row + 1)
end

local function connectToServer()
    term.clear()
    term.write('Waking and connecting to server...')
    tunnel.send('wake')
    
    while true do
        local _,_,_,_,_,to,data = event.pull(30, 'modem_message')
        if to == nil and data == nil then
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

local function performOrdering(storeName)
    local page = 1
    local hasMore = false

    while true do
        term.clear()
        term.write('Fetching items from server...')
        tunnel.send('list')
        local response = getResponse()

        local items = {}
        if response ~= nil then
            items = serialization.unserialize(response)
        end

        local suggestions = {}
        if #items > 0 then
            local _,height = term.getViewport()
            local skip = (#items + 1 - height) * (page - 1)

            if skip < 0 then
                skip = 0
            end

            hasMore = #items > skip + height

            for i = skip + 1, #items do
                term.write(items[i].size .. 'x ' .. items[i].label)
                nl()
            end

            for _,item in ipairs(items) do
                table.insert(suggestions, item.name)
            end
        else
            term.write('* No Items *')
            nl()
        end

        term.write('Enter command (next, prev, item name, back):')
        local command = text.trim(term.read({hint=suggestions}))
        if command == 'next' and hasMore then
            page = page + 1
        elseif command == 'prev' and page > 1 then
            page = page - 1
        elseif command == 'back' then
            return
        else
            local selectedItem = nil
            for _,item in ipairs(items) do
                if item.label == command then
                    selectedItem = item
                    break
                end
            end

            if selectedItem ~= nil then
                term.write('Enter quantity (max ' .. selectedItem.size .. ', blank to cancel):')
                local quantity = tonumber(text.trim(term.read()))
                if quantity ~= nil then
                    tunnel.send('order', serialization.serialize({storeName = storeName, name=selectedItem.name, amount=quantity}))
                    local response = getResponse()
                    if response ~= nil then
                        local dataTable = serialization.unserialize(response)
                        if not dataTable.success then
                            term.write('Failed to order: ' .. dataTable.errorMessage)
                            nl()
                            term.write('Press enter to continue...')
                            term.read()
                        end
                    end
                end
            end
        end
    end
end

local function orderFromWarehouse(storeName)

    while true do
        term.clear()
        term.write('Getting order data from server...')
        tunnel.send('vieworder', serialization.serialize({storeName = storeName}))
        local response = getResponse()

        local order = {}
        local retrieveFailMessage = nil
        if response ~= nil then
            local dataTable = serialization.unserialize(response)
            if dataTable.success then
                order = dataTable.data
            else
                retrieveFailMessage = dataTable.data
            end
        end

        term.clear()
        if retrieveFailMessage ~= nil then
            term.write('Failed to get order: ' .. retrieveFailMessage)
        end

        if #order > 0 then
            local _,height = term.getViewport()
            local skip = #order + 1 - height
            if skip < 0 then
                skip = 0
            end
        
            for i = skip + 1, #order do
                term.write(order[i].amount .. 'x ' .. order[i].name)
                nl()
            end
        else
            term.write('* No Items *')
            nl()
        end

        term.write('Type command (modify, back):')
        local command = text.trim(term.read())
        if command == 'modify' then
            performOrdering(storeName)
        elseif command == 'back' then
            return
        end
    end
end

local function backorderFromWarehouse(storeName)

    while true do
        term.clear()
        term.write('Getting backorder data from server...')
        tunnel.send('viewbackorder', serialization.serialize({storeName = storeName}))
        local response = getResponse()

        local backorder = {}
        local retrieveFailMessage = nil
        if response ~= nil then
            local dataTable = serialization.unserialize(response)
            if dataTable.success then
                backorder = dataTable.data
            else
                retrieveFailMessage = dataTable.data
            end
        end

        term.clear()
        if retrieveFailMessage ~= nil then
            term.write('Failed to get backorder: ' .. retrieveFailMessage)
        end

        if #backorder > 0 then
            local _,height = term.getViewport()
            local skip = #backorder + 1 - height
            if skip < 0 then
                skip = 0
            end
        
            for i = skip + 1, #backorder do
                term.write(backorder[i].amount .. 'x ' .. backorder[i].label)
                nl()
            end
        else
            term.write('* No Items *')
            nl()
        end

        term.write('Enter item name, or blank to cancel:')
        local command = text.trim(term.read())
        if command == nil or command == '' then
            return
        end

        term.write('Enter quantity, or blank to cancel:')
        local quantity = tonumber(text.trim(term.read()))
        if quantity ~= nil then
            tunnel.send('backorder', serialization.serialize({storeName = storeName, label=command, amount=quantity}))
            local response = getResponse()
            if response ~= nil then
                local dataTable = serialization.unserialize(response)
                if not dataTable.success then
                    term.write('Failed to backorder: ' .. dataTable.errorMessage)
                    nl()
                    term.write('Press enter to continue...')
                    term.read()
                end
            end
        end
    end
end

local function systemMenu()
    term.clear()

    -- Get store name, if it exists
    local storeName = nil
    if filesystem.exists('/etc/warehouse/storename') then
        local file = io.open('/etc/warehouse/storename', 'r')
        storeName = file:read('*a')
        file:close()
    end

    -- Prompt for store name
    while true do
        if storeName ~= nil and storeName ~= '' then
            term.write('Previous store name: ' .. storeName)
            nl()
            term.write('Press enter to use')
            nl()
            nl()
        end

        term.write('Enter store name:')
        local name = text.trim(term.read())
        if name == nil or name == '' then
            if storeName ~= nil and storeName ~= '' then
                break
            end
        else
            storeName = name
            break
        end
    end

    filesystem.makeDirectory('/etc/warehouse')
    local file = io.open('/etc/warehouse/storename', 'w')
    file:write(storeName)
    file:close()

    -- Main menu options
    while true do
        term.clear()
        term.write('Getting data from server...')
        local hasOrders = false
        tunnel.send('vieworder', {storeName = storeName})
        local response = getResponse()
        if response ~= nil then
            local dataTable = serialization.unserialize(response)
            if dataTable.success then
                hasOrders = #dataTable.data > 0
            end
        end

        local hasBackorders = false
        tunnel.send('viewbackorder', {storeName = storeName})
        response = getResponse()
        if response ~= nil then
            local dataTable = serialization.unserialize(response)
            if dataTable.success then
                hasBackorders = #dataTable.data > 0
            end
        end

        term.clear()
        term.write('= WAREHOUSE REQUEST =')
        term.write(storeName)
        nl()
        term.write('NOTE: Server shutsdown after 10 minutes of inactivity')
        nl()
        term.write('Existing order? ')
        if hasOrders then
            term.write('Yes')
        else
            term.write('No')
        end
        nl()
        term.write('Existing backorder? ')
        if hasBackorders then
            term.write('Yes')
        else
            term.write('No')
        end
        nl()
        nl()

        term.write('1 - Create/modify order')
        nl()
        term.write('2 - Create/modify backorder')
        nl()
        term.write('3 - Disconnect from server')
        nl()
        nl()
        term.write('Enter an option:')
        local opt = tonumber(term.read())
        if opt == 1 then -- Create/modify order
            orderFromWarehouse(storeName)
        elseif opt == 2 then -- Create/modify backorder
            backorderFromWarehouse(storeName)
        elseif opt == 3 then -- Disconnect from server
            tunnel.send('bye')
            return
        end
    end
end

term.clear()
while true do
    term.write('= WAREHOUSE REQUEST =')
    nl()
    nl()
    term.write('1 - Connect to server')
    nl()
    term.write('2 - Close Warehouse Request')
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