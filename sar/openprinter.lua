local component = require('component')
local filesystem = require('filesystem')
local serialization = require('serialization')
local term = require('term')


local module = {}

local function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

module.isPrinterAvailable = function()
    return component.isAvailable('openprinter')
end

module.readBOL = function()
    filesystem.makeDirectory('/etc/sar')
    if not filesystem.exists('/etc/sar/openprinter') then
       local file = io.open('/etc/sar/openprinter', 'w')
       file:write('')
       file:close()
    end

    local file = io.open('/etc/sar/openprinter', 'r')
    local printerAddr = file:read('*a')
    file:close()

    if component.get(printerAddr) == nil then
        repeat
            nl()
            term.write('Printer not found')
            nl()
            term.write('Enter printer address:')
            printerAddr = term.read()
        until component.get(printerAddr) ~= nil

        local file = io.open('/etc/sar/openprinter', 'w')
        file:write(printerAddr)
        file:close()
    end

    -- todo: use printer to scan and return bol #
    return ''
end

return module