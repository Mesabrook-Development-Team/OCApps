local component = require('component')
local tunnel = require('tunnel')
local event = require('event')
local serialization = require('serialization')
local database = require('warehouse/database')

local function notifyWoken(from)
    tunnel.send(from, 'woken')
end

local function getItems()
    local xnets = component.list('xnet')

    local orderedItems = {}
    local allOrders = database.readAllOrders()
    for _,order in pairs(allOrders) do
        for _,item in ipairs(order) do
            local amount = orderedItems[item.name]
            if amount == nil then
                amount = 0
            end

            orderedItems[item.name] = amount + item.amount
        end
    end

    local items = {}
    for k in pairs(xnets) do
        local xnet = component.proxy(k)
        
        local positions = {}
        for _,connector in ipairs(xnet.getConnectedBlocks()) do
            table.insert(positions, {x=connector.pos.x + 0.0, y=connector.pos.y + 0.0, z=connector.pos.z + 0.0})
        end

        for _,position in ipairs(positions) do
            for _,item in ipairs(xnet.getItems(position)) do
                if item.name ~= 'minecraft:air' then
                    local alreadyOrderedAmount = orderedItems[item.name]
                    if alreadyOrderedAmount == nil or alreadyOrderedAmount < item.size then
                        table.insert(items, {size=item.size, name=item.name, label=item.label})
                    end
                end
            end
        end
    end

    table.sort(items, function(a,b)
        return a.name < b.name
    end)

    return items
end

local function sendList(from, data)
    local items = getItems()

    local response = {
        items={},
        hasMore=false
    }

    local skip = 0
    if data.skip ~= nil and tonumber(data.skip) ~= nil then
        skip = tonumber(data.skip)
    end

    if skip >= #items then
        tunnel.send(from, serialization.serialize(response))
        return
    end

    local take = 20
    if data.take ~= nil and tonumber(data.take) ~= nil then
        take = tonumber(data.take)
    end

    if take > #items - skip then
        take = #items - skip
    else
        response.hasMore = true
    end

    for i=1+skip,take+skip do
        table.insert(response.items, items[i])
    end

    tunnel.send(from, serialization.serialize(response))
end

local function order(data)
    if data.storeName == nil then
        return false, 'Store name required'
    end

    if data.name == nil then
        return false, 'Item name required'
    end

    if data.amount == nil or tonumber(data.amount) == nil then
        return false, 'Amount required and must be number'
    end

    local existingOrder = database.readOrder(data.storeName)
    if existingOrder == nil then
        existingOrder = {}
    end

    for i,item in ipairs(existingOrder) do
        if item.name == data.name then
            table.remove(existingOrder, i)
            database.writeOrder(existingOrder)
            break
        end
    end

    if data.amount > 0 then
        local items = getItems()

        local haveItemOnHand = false
        for _,item in ipairs(items) do
            if item.name == data.name then
                haveItemOnHand = true
                break
            end
        end

        if not haveItemOnHand then
            return false, 'Item not found on hand'
        end

        table.insert(existingOrder, {
            name=data.name,
            amount=data.amount
        })
    end

    database.writeOrder(data.storeName, existingOrder)

    return true
end

local function sendOrder(from, data)
    if data.storeName == nil then
        tunnel.send(from, serialization.serialize({success=false, data='Store name required'}))
        return
    end

    local order = database.readOrder(data.storeName)
    if order == nil then
        order = {}
    end

    tunnel.send(from, serialization.serialize({success=true, data=order}))
end

local function backorder(data)
    if data.storeName == nil then
        return false, 'Store name required'
    end

    if data.label == nil then
        return false, 'Label required'
    end

    if data.amount == nil or tonumber(data.amount) == nil then
        return false, 'Amount required and must be number'
    end

    local existingBackorder = database.readBackorder(data.storeName)
    if existingBackorder == nil then
        existingBackorder = {}
    end

    for i,item in ipairs(existingBackorder) do
        if item.label == data.label then
            table.remove(existingBackorder, i)
            break
        end
    end

    if data.amount > 0 then
        table.insert(existingBackorder, {
            label=data.label,
            amount=data.amount
        })
    end

    database.writeBackorder(data.storeName, existingBackorder)

    return true
end

local function sendBackorder(from, data)
    if data.storeName == nil then
        tunnel.send(from, serialization.serialize({success=false, data='Store name required'}))
        return
    end

    local backorder = database.readBackorder(data.storeName)
    if backorder == nil then
        backorder = {}
    end

    tunnel.send(from, serialization.serialize({success=true, data=backorder}))
end

local function handleMessage(from, message, data)
    if message == 'bye' then
        return false
    elseif message == 'wake' then
        notifyWoken(from)
    elseif message == 'list' then
        sendList(from, data)
    elseif message == 'vieworder' then
        sendOrder(from, data)
    elseif message == 'order' then
        local success, errorMessage = order(data)
        tunnel.send(from, serialization.serialize({success=success, errorMessage=errorMessage}))
    elseif message == 'viewbackorder' then
        sendBackorder(from, data)
    elseif message == 'backorder' then
        local success, errorMessage = backorder(data)
        tunnel.send(from, serialization.serialize({success=success, errorMessage=errorMessage}))
    end

    return true
end

notifyWoken()

while true do
    local _, _, from, _, _, message, data = event.pull('modem_message')
    if not handleMessage(from, message, data) then
        return
    end
end

component.computer.shutdown()