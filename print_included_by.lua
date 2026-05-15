#!/usr/bin/env luajit
-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 Philipp Kutin

local bit = require("bit")
local io = require("io")
local os = require("os")
local math = require("math")
local table = require("table")

local assert = assert
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local type = type

local arg = arg

----------

local function printf(fmt, ...)
    print(fmt:format(...))
end

local function errprint(str)
    io.stderr:write(str, '\n')
end

local function errprintf(fmt, ...)
    errprint(fmt:format(...))
    return true
end

local function abort(fmt, ...)
    errprintf("ERROR: "..fmt, ...)
    os.exit(1)
end

local inFileName = arg[1]
local formatOpt = arg[2]

if not inFileName then
    io.stderr:write("Usage: "..arg[0]..[[ <inclusions-file> [--format=...]

  <inclusions-file> should be in a format as produced by 'print_inclusions.sh'.

  Permissible characters to '--format' are:
   - d: output number of hops N as number instead of '.' repeated N times
]])
    os.exit(1)
end

local FormatFlag = {
    NumericHopCount = 1,
}

local g_formatFlags = 0

if formatOpt ~= nil then
    if (formatOpt:sub(1,9) ~= "--format=") then
        abort("the second argument, when passed, must start with '--format='")
    end

    local chars = formatOpt:sub(10)
    for i = 1, #chars do
        local char = chars:sub(i, i)
        if (char == 'd') then
            g_formatFlags = bit.bor(g_formatFlags, FormatFlag.NumericHopCount)
        else
            abort("unrecognized character '%s' to '--format'", char)
        end
    end
end

local inFile, errMsg = io.open(inFileName)
if not inFile then
    abort("Failed opening <inclusions-file>: %s", errMsg)
end

----------

local function _UpdateIncludedBy(stack, result)
    local stackLen = #stack
    assert(stackLen >= 2)

    local includedFile = stack[stackLen]
    result[includedFile] = result[includedFile] or {}
    local hopsToIncluder = result[includedFile]

    for d = stackLen - 1, 1, -1 do
        local includer = stack[d]
        local hops = (stackLen - d)
        hopsToIncluder[includer] = math.min(hops, hopsToIncluder[includer] or math.huge)
    end
end

local function _collectKeys(tab)
    local keys = {}
    for k, _ in pairs(tab) do
        keys[#keys + 1] = k
    end
    return keys
end

local function PrintResult(result, tuNums)
    assert(type(result) == "table")
    assert(type(tuNums) == "table")

    local numericHops = bit.band(g_formatFlags, FormatFlag.NumericHopCount) ~= 0
    local includees = _collectKeys(result)
    table.sort(includees)

    for i, includee in ipairs(includees) do
        local hopsToIncluder = result[includee]
        local includerLess = function(lhs, rhs)
            local lhsHops = hopsToIncluder[lhs]
            local rhsHops = hopsToIncluder[rhs]
            return
                lhsHops < rhsHops or
                (lhsHops == rhsHops and
                 lhs < rhs)
        end

        local includers = _collectKeys(hopsToIncluder)
        table.sort(includers, includerLess)

        printf("* %s", includee)

        for _, includer in ipairs(includers) do
            local hops = hopsToIncluder[includer]
            local tuIdx = tuNums[includer]
            local hopsStr = numericHops and tonumber(hops) or ('.'):rep(hops)
            printf("%s %s%s", hopsStr, includer, tuIdx and (" [TU_%d]"):format(tuIdx) or "")
        end

        if (i ~= #includees) then
            print()
        end
    end
end

local function New_State()
    local s = {
        lineNum = 0,
        -- [filename of includee] -> (table [filename of includer] -> number-of-hops)
        result = {},
        -- [<index>] = filename, [filename] = <index>
        tuNums = {},
        -- [depth] = filename; depth one is TU
        stack = {},
    }

    local _abort = function(...)
        abort("line %d: %s", s.lineNum, ...)
    end

    local _handleInclusion = function(incomingDepth, fileName)
        local stack = s.stack
        -- NOTE: remember, the first element on the stack is the TU...
        assert(#stack >= 1)
        if (#stack < incomingDepth) then
            _abort("stack depth %d < incomingDepth %d", #stack, incomingDepth)
        end
        -- ... thus a depth of 1 means an inclusion of a file from the TU, and we want to
        -- trim the stack to only one element.
        while (#stack > incomingDepth) do
            stack[#stack] = nil
        end

        assert(#stack == incomingDepth)
        stack[incomingDepth + 1] = fileName
        _UpdateIncludedBy(stack, s.result)
    end

    local handleLine = function(_, line)
        assert(type(line) == "string")
        s.lineNum = s.lineNum + 1

        if (line:sub(1,2) == "= ") then
            -- New translation unit
            local tuFileName = line:sub(3)
            if #tuFileName == 0 then
                _abort("empty translation unit name")
            end
            s.stack = {tuFileName}
            local tuCount = #s.tuNums
            s.tuNums[tuCount + 1] = tuFileName
            s.tuNums[tuFileName] = tuCount + 1
        elseif (line:sub(1,1) == '.') then
            local dots, fileName = line:match("^(%.+) (.+)$")
            if (dots == nil) then
                _abort("malformed inclusion line")
            elseif (#s.stack == 0) then
                _abort("inclusion line before any translation unit")
            end
            _handleInclusion(#dots, fileName)
        elseif (#line > 0) then
            _abort("malformed line: unexpected prefix")
        end
    end

    local printResult = function(_)
        PrintResult(s.result, s.tuNums)
    end

    return {
        handleLine = handleLine,
        printResult = printResult,
    }
end

----------

local state = New_State()

for line in inFile:lines() do
    state:handleLine(line)
end

state:printResult()
