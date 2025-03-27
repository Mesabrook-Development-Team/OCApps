local term = require('term')
local keyboard = require('keyboard')
local event = require('event')
local filesystem = require('filesystem')
local mesaApi = require('mesasuite_api')
local serialization = require('serialization')

local printerAvailable = false
local printerAPI = {}

local module = {}

local function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

-- BOL Stuff
local function performScan()
    local bol = printerAPI.readBOL()

    if bol == nil then
        return
    end

    local locationFile = io.open('/etc/sar/loc.cfg', 'r')
    local fileContents = serialization.unserialize(locationFile:read('*a'))
    locationFile:close()

    local success = mesaApi.request('company', 'BillOfLading/AcceptBOL', {BillOfLadingID=bol}, {CompanyID=fileContents.CompanyID,LocationID=fileContents.LocationID}, 'POST')

    nl()
    if success then
        term.write('Bill of Lading Accepted')
        os.sleep(2)
    else
        term.write('Bill of Lading Not Accepted')
        nl()
        term.write('Try using MesaSuite instead')
        nl()
        nl()
        term.write('Press any key to acknowledge')
        term.read()
    end
end

local function acceptBOL()
    local currentOption = 1

    while true do
        term.clear()
        term.write("By scanning a Bill of Lading, you are contractually accepting this railcar as received as described.", true)
        nl()
        nl()
        term.write("Select an option below and press enter")
        nl()
        term.write("[")
        if currentOption == 1 then
            term.write("x")
        else
            term.write(" ")
        end
        term.write("] - Scan page from scanner")
        nl()
        
        term.write("[")
        if currentOption == 2 then
            term.write("x")
        else
            term.write(" ")
        end
        term.write("] - Finish scanning")

        local _,_,_,keyCode = event.pull('key_down')
        if keyCode == keyboard.keys.up and currentOption > 1 then
            currentOption = currentOption - 1
        elseif keyCode == keyboard.keys.down and currentOption < 2 then
            currentOption = currentOption + 1
        elseif keyCode == keyboard.keys.enter then
            if currentOption == 1 then -- Do scan
                performScan()
            elseif currentOption == 2 then -- exit
                return
            end
        end
    end
end

-- Process cars on track

-- Main Menu
module.menu = function()
    while true do
        term.clear()

        term.write('* RECEIVING MENU *')
        nl()
        nl()
        term.write('1 - Accept Bills Of Lading')
        if not printerAvailable then
           term.write(' (Printer Unavailable)')
        end
        nl()
        term.write('2 - Start AEI Sensor Server')
        nl()
        term.write('3 - Process Cars on Track')
        nl()
        term.write('4 - Return to Main Menu')
        nl()
        nl()
        term.write('Enter an option:')
        local opt = term.read()
        local optNum = tonumber(opt)

        if optNum == 1 and printerAvailable then -- Accept BOL
            acceptBOL()
        elseif optNum == 2 then -- Cars from sensors
            -- Process cars from sensors
        elseif optNum == 3 then -- Cars on track
            -- Process cars on track
        elseif optNum == 4 then -- Exit
            return
        end
    end
end

filesystem.makeDirectory('/etc/sar')
if not filesystem.exists('/etc/sar/printer.cfg') then
   local file = io.open('/etc/sar/printer.cfg', 'w')
   file:write('sar/openprinter')
   file:close()
end

local file = io.open('/etc/sar/printer.cfg', 'r')
printerAPI = require(file:read('*a'))
file:close()

printerAvailable = printerAPI.isPrinterAvailable()

return module