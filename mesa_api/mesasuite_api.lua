local fs = require("filesystem")
fs.makeDirectory("/etc/mesasuite")
if not fs.exists("/etc/mesasuite/apiURL") then
    local authFile = io.open('/etc/mesasuite/apiURL', 'w')
    authFile:write('https://api.mesabrook.com')
    authFile:close()
end

local authFile = io.open('/etc/mesasuite/apiURL', 'r')
local baseApiUrl = authFile:read('*a')
authFile:close()

local function getAPIUrl(api)
  return baseApiUrl .. "/" .. api .. "/"
end

local web = require("internet")
local fs = require("filesystem")
local cereal = require("serialization")
local loginAPI = require("mesasuite_login")
local func = {}

local function getToken()
  if not fs.exists("/etc/mesasuite/token") then
    return ''
  end

  local file = io.open("/etc/mesasuite/token", "r")
  local tokenString = file:read()
  file:close()

  local tokenData = cereal.unserialize(tokenString)
  return tokenData.token
end

local function executeRequest(url, payload, headers, method)
    local handle = web.request(url, payload, headers, method)

    local response = ""
    for chunk in handle do response = response .. chunk end

    return response
end

func.request = function(api, action, payload, additionalHeaders, method, isRetry)

    local headers = {["content-type"]="application/json", Authorization = "Bearer " .. getToken()}

    if additionalHeaders ~= nil then
        for k,v in pairs(additionalHeaders) do
            headers[k] = v
        end
    end

    local success, handle = pcall(executeRequest, getAPIUrl(api) .. action, payload, headers, method)

    if not success and not isRetry and handle:match("401") then
      loginAPI.refresh_token()
      return func.request(api, action, payload, additionalHeaders, method, true)
    end

    return success, handle
end

return func