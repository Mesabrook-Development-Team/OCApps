local fs = require("filesystem")
fs.makeDirectory("/etc/mesasuite")
if not fs.exists("/etc/mesasuite/authURL") then
    local authFile = io.open('/etc/mesasuite/authURL', 'w')
    authFile:write('https://auth.mesabrook.com')
    authFile:close()
end

local authFile = io.open('/etc/mesasuite/authURL', 'r')
local baseOAuthUrl = authFile:read('*a')
authFile:close()

local web = require("internet")
local term = require("term")
local comp = require("component")
local cereal = require("serialization")
local json = require("json")
local event = require("event")

local function retrieveClientID()
    local file = io.open("/etc/mesasuite/clientid", "r")
    if not file then
        term.clear()
        term.setCursor(1,1)
        term.write("No MesaSuite Client ID Found!")
        term.setCursor(1,2)
        term.write("Enter Client ID:")
        local clientID = io.read()
        term.setCursor(1,3)
        if string.len(clientID) == 0 then
            return false, "Client ID required for login"
        end

        file = io.open("/etc/mesasuite/clientid", "w")
        if not file then
            return false, "Could not store Client ID"
        end

        file:write(clientID)
        file:flush()
        file:close()

        file = io.open("/etc/mesasuite/clientid", "r")
        if not file then
            return false, "Could not open Client ID"
        end
    end

    local clientID = file:read()
    file:close()

    return true, clientID
end



local function doDeviceCodeChecking(data, clientID)
    term.clear()
    term.setCursor(1,1)
    term.write('Please login to ' .. data.verification_uri .. ' and enter code ' .. data.user_code, true)
    local _,screenHeight = term.getViewport()
    term.setCursor(1, screenHeight)
    term.write("Press any key to cancel...")

    local cancelToken = false

    local keyDownEventID = event.listen('key_down', function()
        term.setCursor(1, clearHeight)
        term.clearLine()
        term.write('Cancelling...')
        cancelToken = true
    end)

    local payload = {
        grant_type="device_code",
        client_id=clientID,
        code=data.device_code
    }

    while cancelToken == false do
        os.sleep(tonumber(data.interval))
        local success, handle = pcall(web.request, baseOAuthUrl .. '/Token', payload, { ["X-OK-Only"]="true" }, "POST")
        if success == true then
            local response = ""
            for chunk in handle do response = response..chunk end
            response = json.parse(response)

            if response.error ~= nil then
                if response.error == "not_found" or response.error == "access_denied" or response.error == "server_error" then
                    term.setCursor(1, 2)
                    term.clearLine()
                    term.write(response.error_description)
                    return false, response.error_description
                end
            else
                if not fs.exists("/etc/mesasuite") then
                    fs.makeDirectory("/etc/mesasuite")
                end
            
                local file = io.open("/etc/mesasuite/token", "w")
                if not file then
                    return false, "File could not be opened"
                end
            
                file:write(cereal.serialize({token=response.access_token,refresh_token=response.refresh_token}))
                file:flush()
                file:close()

                return true
            end
        end
    end
end

local funcs = {}

funcs["login"] = function (errorMessage)
    local clientFetchSuccess, clientIDOrMessage = retrieveClientID()
    if not clientFetchSuccess then
        term.clear()
        term.setCursor(1,1)
        term.write(clientIDOrMessage)
        return
    end

    term.clear()

    local payload = {
        client_id=clientIDOrMessage,
        response_type="device_code"
    }

    local success, handle = pcall(web.request, baseOAuthUrl .. "/Authorize", payload, {}, "POST")
    if not success or handle == nil then
        return success, handle
    end

    local response = ""
    for chunk in handle do response = response..chunk end

    response = json.parse(response)

    if response.error ~= nil then
        return false, response.error .. ': ' .. response.error_description
    elseif response.verification_uri ~= nil and response.user_code ~= nil and response.device_code ~= nil and response.interval ~= nil then
        return doDeviceCodeChecking(response, clientIDOrMessage)
    else
        return false, 'An unexpected response was received during authorization'
    end
end

funcs["refresh_token"] = function()
    if not fs.exists("/etc/mesasuite/token") then
        return
      end
    
      local file = io.open("/etc/mesasuite/token", "r")
      local tokenString = file:read()
      file:close()
    
      local tokenData = cereal.unserialize(tokenString)
      local refreshToken = tokenData.refresh_token
    
      local payload = {grant_type="refresh_token", refresh_token=refreshToken}
      local success, handle = pcall(web.request, baseOAuthUrl .. "/Token", payload, {}, "POST")
      if not success then
        return
      end

      local tokenResponseString = ''
      for chunk in handle do
        tokenResponseString = tokenResponseString .. chunk
      end
    
      local tokenResponseObject = json.parse(tokenResponseString)

      local accessToken = tokenResponseObject["access_token"]
      refreshToken = tokenResponseObject["refresh_token"]
    
      tokenData.token = accessToken
      tokenData.refresh_token=refreshToken
    
      file = io.open("/etc/mesasuite/token", "w")
      file:write(cereal.serialize(tokenData))
      file:flush()
      file:close()
end

return funcs