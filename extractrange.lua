#!/usr/bin/env luajit

local io = require("io")
local os = require("os")

local fileName = arg[1]
local startPattern = arg[2]
local stopPattern = arg[3]

if (fileName == nil or startPattern == nil or stopPattern == nil) then
    print("Usage: "..arg[0].." <fileName> <startPattern> <stopPattern>")
    print("")
    print("Extracts all lines from the first one matching <startPattern>")
    print("up to and including the first one matching <stopPattern>.")
    print("")
    print("Exit codes:")
    print(" 0: at least one line was extracted")
    print(" 1: no lines were extracted")
    print(" 2: failed opening file")
    os.exit(1)
end

local function main()
    local f, errMsg = io.open(fileName)
    if (f == nil) then
        print("Error opening file: "..errMsg)
        os.exit(1)
    end

    local extracting = false

    while (true) do
        local line = f:read("*l")
        if (line == nil) then
            break
        end

        if (not extracting and line:match(startPattern)) then
            extracting = true
        end

        if (extracting) then
            print(line)

            if (line:match(stopPattern)) then
                return 0
            end
        end
    end

    return 1
end

return main()
