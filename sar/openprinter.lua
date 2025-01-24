local component = require('component')
local filesystem = require('filesystem')
local unicode = require('unicode')
local term = require('term')
local text = require('text')


local module = {}

local function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

module.isPrinterAvailable = function()
    return component.isAvailable('openprinter')
end

local function getPrinter()
    filesystem.makeDirectory('/etc/sar')
    if not filesystem.exists('/etc/sar/openprinter') then
       local file = io.open('/etc/sar/openprinter', 'w')
       file:write('')
       file:close()
    end

    local file = io.open('/etc/sar/openprinter', 'r')
    local printerAddr = file:read('*a')
    file:close()

    local proxy = component.proxy(printerAddr)

    if proxy == nil then
        repeat
            nl()
            term.write('Printer not found')
            nl()
            term.write('Enter printer address:')
            printerAddr = text.trim(term.read())
        until component.get(printerAddr) ~= nil and component.type(component.get(printerAddr)) == 'openprinter'

        local file = io.open('/etc/sar/openprinter', 'w')
        file:write(printerAddr)
        file:close()

        proxy = component.proxy(printerAddr)
    end

    return proxy
end

module.readBOL = function()
    local printerProxy = getPrinter()
    
    local _,pageData = printerProxy.scan()
    if pageData == nil then
        nl()
        term.write('Printer was unable to scan')
        nl()
        term.write('Press enter to continue')
        term.read()
        return nil
    end
    
    local bolLine = pageData[0]
    if bolLine == nil then
        nl()
        term.write('Page is empty')
        nl()
        term.write('Press enter to continue')
        term.read()
        return nil
    end

    bolLine = bolLine:match("([^" .. unicode.char(0x221E) .. "]+)")
    if #bolLine < 7 then
        nl()
        term.write('Unable to find BOL #')
        nl()
        term.write('Press enter to continue')
        term.read()
        return nil
    end

    return bolLine:sub(7)
end

return module