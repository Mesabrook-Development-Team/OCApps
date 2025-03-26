local component = require('component')
local event = require('event')
local serialization = require('serialization')
local filesystem = require('filesystem')
local detector = component.ir_augment_detector

if not component.isAvailable('ir_augment_detector') then
    return nil, 'IR Augment Detector is not present'
end

local module = {}

filesystem.makeDirectory('/etc/aei')

local config = {
    timeout=15
}

if not filesystem.exists('/etc/aei/config.cfg') then
    local file = io.open('/etc/aei/config.cfg', 'w')
    file:write(serialization.serialize(config))
    file:close()
end

local file = io.open('/etc/aei/config.cfg', 'r')
local readConfig = serialization.unserialize(file:read('*a'))
file:close()

-- Only set valid values in config
for k,v in pairs(readConfig) do
    if config[k] ~= nil then
        config[k] = v
    end
end

-- Database functions
file = io.open('/etc/aei/data', 'r')
local data = serialization.unserialize(file:read('*a'))
file:close()

if data == nil then
    data = {}
end

local function saveDatabase()
    local file = io.open('/etc/aei/data', 'w')
    file:write(serialization.serialize(data))
    file:close()
end

local workingOSTime = nil
local timeoutTimerId = nil
local function tagReadingTimeout()
    workingOSTime = nil
end

local function getCurrentEntryKey()
    if workingOSTime ~= nil then
        return workingOSTime
    end

    workingOSTime = os.time()

    local existingTimes = {}
    for k in pairs(data) do
        table.insert(existingTimes, k)
    end

    table.sort(existingTimes)

    if #existingTimes >= 5 then
        data[existingTimes[1]] = nil
    end

    table[workingOSTime] = {}
    saveDatabase()
end

local function onStockOverhead()
    local tag = detector.getTag()
    if tag == nil or tag == '' then
        return
    end

    local workingOSTime = getCurrentEntryKey()
    table.insert(data[workingOSTime], tag)
    saveDatabase()
end

module.start = function()
    event.listen('ir_train_overhead', onStockOverhead)

    timeoutTimerId = event.timer(config.timeout, tagReadingTimeout)
end

module.stop = function()
    event.ignore('ir_train_overhead', onStockOverhead)

    event.cancel(timeoutTimerId)
end

module.list = function()
    local list = {}
    for k,v in pairs(data) do
        list[k] = {}

        for _,tag in pairs(v) do
            table.insert(list[k], tag)
        end
    end

    return list
end

return module