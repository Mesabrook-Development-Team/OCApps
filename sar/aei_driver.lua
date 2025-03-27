local component = require('component')
local modem = nil
if component.isAvailable('modem') then
    modem = component.modem
end
local term = require('term')
local filesystem = require('filesystem')
local serialization = require('serialization')
local text = require('text')
local event = require('event')

local module = {}

module.scan = function()
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

    term.clear()
    print('AEI Sensor Server is running')
    print()
    print('When car sensing is complete, press any key to select data')
    term.pull('key_down')
    term.clear()

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

    return data
end

return module