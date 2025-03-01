local filesystem = require('filesystem')
local serialization = require('serialization')

local database = {}
local module = {}

local function saveDatabase()
    local file = io.open('/etc/warehouse/data.db', 'w')
    file:write(serialization.serialize(database))
    file:close()
end

module.reloadDatabase = function()
    filesystem.makeDirectory('/etc/warehouse')
    if not filesystem.exists('/etc/warehouse/data.db') then
        local file = io.open('/etc/warehouse/data.db', 'w')
        file:write(serialization.serialize({}))
        file:close()
    end

    local file = io.open('/etc/warehouse/data.db', 'r')
    database = serialization.unserialize(file:read('*a'))
    file:close()
end

local function readTable(store, table)
    if store == nil or 
        database[store] == nil or 
        database[store][table] == nil then
    return nil
    end

    return database[store][table]
end

local function readTableInAllStores(table)
    local values = {}
    for storeName,storeData in pairs(database) do
        if storeData[table] ~= nil then
            values[storeName] = storeData[table]
        end
    end

    return values
end

local function writeTable(store, table, value)
    if database[store] == nil then
        database[store] = {}
    end
    database[store][table] = value
    saveDatabase()
end

-- ORDER DATA --
module.readOrder = function(storeName)
    return readTable(storeName, 'order')
end

module.writeOrder = function(storeName, order)
    writeTable(storeName, 'order', order)
end

module.deleteOrder = function(storeName)
    writeTable(storeName, 'order', nil)
end

module.readAllOrders = function()
    return readTableInAllStores('order')
end

-- BACKORDER DATA --
module.readBackorder = function(storeName)
    return readTable(storeName, 'backorder')
end

module.writeBackorder = function(storeName, backorder)
    writeTable(storeName, 'backorder', backorder)
end

module.deleteBackorder = function(storeName)
    writeTable(storeName, 'backorder', nil)
end

module.readAllBackorders = function()
    return readTableInAllStores('backorder')
end

module.reloadDatabase()

return module