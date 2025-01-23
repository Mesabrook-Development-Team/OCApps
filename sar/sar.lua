local fs = require("filesystem")
local term = require("term")
local serialization = require("serialization")
local receiving = require("sar/receiving")
local mesaApi = require('mesasuite_api')
local json = require('json')

local function nl()
    local col, row = term.getCursor()
    term.setCursor(1, row + 1)
end

local function mainMenu()
    while true do
        term.clear();

        term.write('* SHIPPING & RECEIVING *')
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
            -- Call shipping
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
    local companiesRemoved = 0
    for companyIndex,company in ipairs(companyArray) do
        local locationsRemoved = 0
        local companyWasRemoved = false
        for locationIndex,location in ipairs(company.Locations) do
            success, jsonStr = mesaApi.request('company', 'GetForCurrentUser/' .. location.LocationID)
            if success == false then
                table.remove(companyArray, companyIndex - companiesRemoved)
                companiesRemoved = companiesRemoved + 1
                companyWasRemoved = true
                break
            end

            local locationEmployee = json.parse(jsonStr)
            if not companyWasRemoved and locationEmployee.ManagePurchaseOrders == false then
                table.remove(company.Locations, locationIndex - locationsRemoved)
                locationsRemoved = locationsRemoved + 1
            end
        end

        if #company.Locations == 0 then
            table.remove(companyArray, companyIndex - companiesRemoved)
            companiesRemoved = companiesRemoved + 1
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
end

local function verifySetup()
    term.clear()
    term.write("Application is loading...")

    local isLoggedIn = mesaApi.request('company', 'Company/GetAll')
    if isLoggedIn == false then
        term.clear()
        term.write("You're not logged into MesaSuite")
        nl()
        term.write("Run mesalogin and try again")
        nl()
        return false
    end

    fs.makeDirectory('/etc/sar')

    if not fs.exists('/etc/sar/loc.cfg') then
        while true do
            term.clear()
            term.write('Required Company and Location information is missing.')
            nl()
            nl()
            term.write('Configure now (y/n)?')
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

    local configFile = io.open('/etc/sar/loc.cfg', 'r')
    local fileContentsStr = configFile:read("*a")
    local fileContents = serialization.unserialize(fileContentsStr)

    if tonumber(fileContents.CompanyID) == nil or tonumber(fileContents.LocationID) == nil then
        while true do
            term.clear()
            term.write('Required Company and Location information is corrupted.')
            nl()
            nl()
            term.write('Reconfigure now (y/n)?')
            local opt = term.read()
            if string.lower(opt) == "y" then -- Do configuration
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

    return true
end

if verifySetup() == false then
    return
end

mainMenu()