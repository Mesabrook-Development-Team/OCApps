local api = require("mesasuite_api")
local cmp = require("component")
local json = require("json")
local term = require("term")
local keyboard = require("keyboard")

term.clear()

print("Loading network printers...")

local netPrinters = {}
local printerCount = 0
for k in pairs(cmp.list("openprinter")) do
    local success, result = api.request("system", "Printer/CheckPrinterExists?printerID=" .. k, {}, nil, "GET")
    if success and result=="true" then
        netPrinters[k] = cmp.proxy(k)
        printerCount = printerCount + 1
    elseif not success then
        print("Failed to check printer " .. k .. " - it will not available")
        print(result)
    end
end

print("Found " .. printerCount .. " printers")
print("")

local function printJob(data, printer)
    local printJobData = json.parse(data)

    local anyJobs = false
    for _,job in ipairs(printJobData) do
        anyJobs = true
        print("Print Job received")
        local pageTotal = 0
        for _,page in ipairs(job.PrintPages) do
            pageTotal = pageTotal + 1
            local pageName = job.DocumentName
            if pageTotal > 1 then
                pageName = pageName .. " (" .. pageTotal .. ")"
            end

            printer.setTitle(pageName)

            for _,line in ipairs(page.PrintLines) do
                local alignment = "left"
                if line.Alignment == 2 then
                    alignment = "center"
                end

                printer.writeln(line.Text, 0, alignment)
            end

            local didPrint = printer.print()
            while didPrint == nil do
                print("Please clear the output slots and then press enter")
                io.read()
                didPrint = printer.print()
            end
        end
        print("Job finished. Printed Pages: " .. pageTotal)
        api.request("system", "PrintJob/Delete/" .. job.PrintJobID, {}, nil, "DELETE")
    end

    if anyJobs == false then
        print("No jobs to print for " .. printer.address)
    end
end

local function register(_,_,_,key)
    term.write("Enter address of printer:")
    local address = io.read()

    local printer = cmp.proxy(address)
    if printer == nil then
        print("Address did not resolve to a component")
        return
    elseif printer.type ~= "openprinter" then
        print("Address did not resolve to a printer. Type: ", printer.type)
        return
    end

    term.write("Enter friendly name of printer:")
    local name = io.read()

    local payload = {Address=address,Name=name}
    local success, result = api.request("system", "Printer/Post", json.stringify(payload), nil, "POST")
    if success then
        netPrinters[printer.address] = printer
        print("Printer successfully added!")
    else
        print("Failed to add printer")
        print(result)
    end
end

local function displayOptions()
    print("")
    print("P - Print all pending jobs")
    print("R - Register a printer")
    print("Q - Quit network printing")
    term.write("Enter an option:")
end

local function checkForPrintJobs()
    for k,v in pairs(netPrinters) do
        local success, result = api.request("system", "PrintJob/GetForPrinter?printerID=" .. k, {}, nil, "GET")
        if success then
            local printSuccess, printResult = pcall(printJob, result, v)
            if not printSuccess then
                print("Print job failed")
                print(printResult)
            end
        else
            print("Failed to check for print jobs for printer " .. k)
            print(result)
        end
    end
end

displayOptions()

repeat
    local option = io.read()
    option = option:lower()
    if option == "p" then checkForPrintJobs()
    elseif option == "r" then register()
    elseif option == "q" then break end

    displayOptions()
until false

print("Network printing canceled")