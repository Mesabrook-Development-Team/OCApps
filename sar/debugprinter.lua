local term = require('term')

local module = {}

local function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

module.isPrinterAvailable = function()
    return true
end

module.readBOL = function()
    nl()
    term.write('Enter BOL #:')
    local bol = term.read()
    return bol
end

return module