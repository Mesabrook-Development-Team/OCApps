local term = require('term')
local keyboard = require('keyboard')

local module = {}

function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

function performScan()

end

function acceptBOL()
    local currentOption = 1
    term.setCursorBlink(false)

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
        term.write(") - Scan page from scanner")
        nl()
        
        term.write("[")
        if currentOption == 1 then
            term.write("x")
        else
            term.write(" ")
        end
        term.write(") - Finish scanning")

        local _,_,_,keyCode = term.pull('key_down')
        if keyCode == keyboard.keys.up and currentOption > 1 then
            currentOption = currentOption - 1
        elseif keyCode == keyboard.keys.down and currentOption < 2 then
            currentOption = currentOption = 1
        elseif keyCode == keyboard.keys.enter then
            if currentOption == 1 then -- Do scan
                -- scan
            elseif currentOption == 2 then -- exit
                return
            end
        end
    end
end

module.menu = function()
    while true do
        term.clear()

        term.write('* RECEIVING MENU *')
        nl()
        nl()
        term.write('1 - Accept Bills Of Lading')
        nl()
        term.write('2 - Process Cars on Track')
        nl()
        term.write('3 - Return to Main Menu')
        nl()
        nl()
        term.write('Enter an option:')
        local opt = term.read()
        local optNum = tonumber(opt)

        if optNum == 1 then -- Accept BOL
            acceptBOL()
        elseif optNum == 2 then -- Cars on track
            -- Process cars on track
        elseif optNum == 3 then -- Exit
            return
        end
    end
end

return module