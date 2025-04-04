local VERSION = '1.0'

local fs = require("filesystem")
local term = require("term")
local serialization = require("serialization")
local receiving = require("sar/receiving")
local shipping = require("sar/shipping")
local mesaApi = require('mesasuite_api')
local json = require('json')

local entityName = ''

local function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

local function mainMenu()
    while true do
        term.clear();

        term.write('* SHIPPING & RECEIVING *')
        nl()
        print('v' .. VERSION)
        print()
        term.write(entityName)
        nl()
        nl()
        term.write('1 - Perform Shipping')
        nl()
        term.write('2 - Perform Receiving')
        nl()
        term.write('3 - Exit')
        nl()
        nl()
        term.write('Enter an option:')
        local opt = term.read()
        local optNum = tonumber(opt)
        if optNum == 1 then -- Shipping
            shipping.menu()
        elseif optNum == 2 then -- Receiving
            receiving.menu()
        elseif optNum == 3 then -- Exit
            return
        end
    end
end

local function configureLocation()
    term.clear()
    term.write("Loading your companies...")
    nl()

    local success, jsonStr = mesaApi.request('company', 'Company/GetForEmployee')
    if success == false then
        term.write('Unable to fetch your current companies')
        nl()
        return false
    end

    local companyArray = json.parse(jsonStr)
    local i = 1
    while i <= #companyArray do
        if companyArray[i].Locations == nil then
            table.remove(companyArray, i)
        else
            local j = 1
            while j <= #companyArray[i].Locations do
                success, jsonStr = mesaApi.request('company', 'LocationEmployee/GetForCurrentUser?locationid=' .. companyArray[i].Locations[j].LocationID, nil, {CompanyID=companyArray[i].CompanyID})
                if success == false then
                    table.remove(companyArray[i].Locations, j)
                else
                    local locationEmployee = json.parse(jsonStr)
                    if locationEmployee == nil or locationEmployee.ManagePurchaseOrders == nil or locationEmployee.ManagePurchaseOrders == false then
                        table.remove(companyArray[i].Locations, j)
                    else
                        j = j + 1
                    end
                end
            end

            if #companyArray[i].Locations == 0 then
                table.remove(companyArray, i)
            else
                i = i + 1
            end
        end
    end

    if #companyArray == 0 then
        term.clear()
        term.write('You do not have permission to manage Purchase Orders in any Company', true)
        nl()
        return false
    end

    local selectedCompanyIndex = 0
    while true do
        term.clear()
        term.write('Your companies:')
        nl()
        nl()
        for i,company in ipairs(companyArray) do
            term.write(i .. ' - ' .. company.Name)
            nl()
        end
        nl()
        term.write('Select a company:')
        local opt = term.read()
        local optNum = tonumber(opt)

        if optNum ~= nil and optNum > 0 and optNum <= #companyArray then
            selectedCompanyIndex = optNum
            break
        end
    end

    local selectedCompany = companyArray[selectedCompanyIndex]
    local selectedLocationIndex = 0
    while true do
        term.clear()
        term.write('Your locations:')
        nl()
        nl()
        for i,location in ipairs(selectedCompany.Locations) do
            term.write(i .. ' - ' .. location.Name)
            nl()
        end
        nl()
        term.write('Select a location:')
        local opt = term.read()
        local optNum = tonumber(opt)

        if optNum ~= nil and optNum > 0 and optNum <= #selectedCompany.Locations then
            selectedLocationIndex = optNum
            break
        end
    end

    local selectedLocation = selectedCompany.Locations[selectedLocationIndex]
    local fileContents = {CompanyID=selectedCompany.CompanyID, LocationID=selectedLocation.LocationID}

    local file = io.open('/etc/sar/loc.cfg', 'w')
    file:write(serialization.serialize(fileContents))
    file:close()

    file = io.open('/etc/rc.d/sar_reboot.lua', 'w')
    file:write("function start()")
    file:write("require('filesystem').remove('/etc/rc.d/sar_reboot.lua')")
    file:write("require('shell').execute('sar')")
    file:write("end")
    file:close()

    require('shell').execute('rc sar_reboot enable')

    require('computer').shutdown(true)

    return true
end

local function verifySetup()
    term.clear()
    term.write("Application is loading...")

    local success, jsonStr = mesaApi.request('company', 'Company/GetAll')
    if success == false then
        term.clear()
        term.write("You're not logged into MesaSuite")
        nl()
        term.write("Run mesalogin and try again")
        nl()
        return false
    end

    fs.makeDirectory('/etc/sar')

    local promptForConfiguration = function(reason, cta)
        while true do
            term.clear()
            term.write('Required Company and Location information is ' .. reason .. '.', true)
            nl()
            nl()
            term.write(cta .. ' now (y/n)?')
            local opt = term.read()
            if opt:gsub("%s+", "") == "y" then -- Do configuration
                if configureLocation() == false then
                    return false
                end
                break
            else
                nl()
                return false
            end
        end
    end

    if not fs.exists('/etc/sar/loc.cfg') and not promptForConfiguration('missing', 'Configure') then
        return false
    end

    local configFile = io.open('/etc/sar/loc.cfg', 'r')
    local fileContentsStr = configFile:read("*a")
    local fileContents = serialization.unserialize(fileContentsStr)

    if (fileContents == nil or tonumber(fileContents.CompanyID) == nil or tonumber(fileContents.LocationID) == nil) and not promptForConfiguration('corrupted', 'Reconfigure') then
        return false
    end

    success, jsonStr = mesaApi.request('company', 'LocationEmployee/GetForCurrentUser?locationid=' .. fileContents.LocationID, nil, {CompanyID=fileContents.CompanyID})
    if not success then
       term.write('Could not verify your location permissions')
       nl()
       return false
    end

    local locationEmployee = json.parse(jsonStr)

    if (locationEmployee == nil or locationEmployee.ManagePurchaseOrders == nil or locationEmployee.ManagePurchaseOrders == false) and not promptForConfiguration('no longer authorized', 'Reconfigure') then
        return false
    end

    success, jsonStr = mesaApi.request('company', 'Location/Get/' .. fileContents.LocationID, nil, {CompanyID=fileContents.CompanyID,LocationID=fileContents.LocationID})
    if success then
        local location = json.parse(jsonStr)

        entityName = location.Company.Name .. ' (' .. location.Name .. ')'
    else
        entityName = '[Company Name Unavailable]'
    end

    return true
end

if verifySetup() == false then
    return
end

require('computer').beep(1000, 0.1)
require('computer').beep(1000, 0.1)

mainMenu()