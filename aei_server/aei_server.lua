local component = require('component')
local modem = component.modem
local filesystem = require('filesystem')
local serialization = require('serialization')
local term = require('term')
local event = require('event')
term.clear()

print('Loading config...')

filesystem.makeDirectory('/etc/aei_server')

local config = {
    port=1923
}

local file = io.open('/etc/aei_server/config.cfg', 'r')
local configData = serialization.unserialize(file:read('*a'))
file:close()

if configData ~= nil then
    file = io.open('/etc/aei_server/config.cfg', 'w')
    file:write(serialization.serialize(config))
    file:close()
end

for k,v in pairs(configData) do
    config[k] = v
end

print('Loading AEI...')
local aei, loadFailReason = require('aei')
if aei == nil then
    print('AEI failed to load')
    print(loadFailReason)
    print()
    print('Aborting start')
    return
end

term.clear()
print('Starting AEI...')
aei.start()

print('Opening server on port ' .. config.port)
print('Note: This port can be changed in /etc/aei_server/config.cfg')
print()

if not modem.open(config.port) then
    print('Failed to open port ' .. config.port)
    print()
    print('Aborting start')
    return
end

modem.broadcast(config.port, 'woken')

while true do
    local _, _, from, port, _, message = event.pull('modem_message')
    print(message .. ' from ' .. from .. ':' .. port)
    if message == 'wake' then
        modem.send(from, port, 'woken')
    elseif message == 'bye' then
        aei.stop()
        modem.close(config.port)
        component.computer.stop()
        return
    elseif message == 'list' then
        modem.send(from, port, serialization.serialize(aei.list()))
    end
end