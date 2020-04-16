#!/usr/bin/env luajit

local arg = arg

local require = require

local io = require("io")
local os = require("os")
local math = require("math")
local string = require("string")
local table = require("table")

local hacks = require("hacks")
local util = require("util")

local assert = assert
local ipairs = ipairs
local print = print
local tonumber = tonumber
local loadstring = loadstring

local format = string.format

----------

local function printf(fmt, ...)
    print(format(fmt, ...))
end

local function errprintf(fmt, ...)
    io.stderr:write(format(fmt, ...).."\n")
end

-- Are we using mkapp.lua?
-- KEEPINSYNC with 'quiet' short option letter.
local IsMakingApp = (arg[1] == "-Q" and arg[2] == nil)

local function usage(hline)
    if (hline) then
        print(hline)
    end
    print("Usage: extractdecls.lua [our options...] <file.h> [-- [Clang command line args ...]]")
    print("Exits with a non-zero code if there were errors or no match.")
    print " (Our options may also come after the file name.)"
    print "  -e <enumNameFilterPattern> (enums only)"
    print "  -p <filterPattern>"
    print "  -x <excludePattern1> [-x <excludePattern2>] ..."
    print "  -s <stripPattern>"
    print "  -1 <string to print before everything>"
    print "  -2 <string to print after everything>"
    print "  -A <single Clang command line arg> (same as if specified as positional arg)"
    print "  -C: print lines like"
    print "       static const int membname = 123;  (enums/macros only)"
    print "  -R: reverse mapping, only if one-to-one. Print lines like"
    print "       [123] = \"membname\";  (enums/macros only)"
    print "  -f <formatFunc>: user-provided body for formatting function (enums/macros only)"
    print "       Arguments to that function are named"
    print "         * 'k' (enum constant / macro name)"
    print "         * 'v' (its numeric value)"
    print "         * 'enumName' (the name in 'enum <name>', or the empty string)"
    print "         * 'enumIntTypeName' (the name of the underlying integer type of an enum)"
    print "         * 'enumPrefixLength' (the length of the common prefix of all names; enums only)"
    print "       Also, the following is provided:"
    print "         * 'f' as a shorthand for 'string.format'"
    print "       Must return a formatted line."
    print "       Example:"
    print[[         "return f('%s = %s%s,', k, k:find('KEY_') and '65536+' or '', v)"]]
    print "       Incompatible with -C or -R."
    print "  -Q: be quiet"
    print "  -w: extract what? Can be"
    print "       EnumConstantDecl (default), TypedefDecl, FunctionDecl, MacroDefinition"
    -- TODO: allow list in '-w'.

    if (not IsMakingApp) then
        os.exit(1)
    end

    -- Continue to allow mkapp.lua collect the remaining 'require's.
end

local parsecmdline = require("parsecmdline_pk")

-- Meta-information about options, see parsecmdline_pk.
local opt_meta = { e=true, p=true, A=1, x=1, s=true, C=false, R=false, Q=false,
                   ['1']=true, ['2']=true, w=true, f=true }

local opts, args = parsecmdline.getopts(opt_meta, arg, usage)

local additionalArgs = opts.A
local enumNameFilterPattern = opts.e
local filterPattern = opts.p
local excludePatterns = opts.x
local stripPattern = opts.s
local printConstInt = opts.C
local reverse = opts.R
local quiet = opts.Q
local what = opts.w or "EnumConstantDecl"
local fmtfuncCode = opts.f

local extractEnum = (what == "EnumConstantDecl")
local extractMacro = (what:find("^Macro"))

local prefixString = opts['1']
local suffixString = opts['2']

if (#args == 0) then
    usage()
end

-- Late load to allow printing the help text with a plain invocation.
local cl = require("ljclang")

if (IsMakingApp) then
    -- KEEPINSYNC: make sure that there are no require() calls below us!
    os.exit(0)
end

if (not extractEnum and enumNameFilterPattern ~= nil) then
    usage("Option -e only available for enum extraction")
end

if (not (extractEnum or extractMacro) and (printConstInt or reverse)) then
    usage("Options -C and -R only available for enum or macro extraction")
end

local fmtfunc
if (fmtfuncCode) then
    if (not (extractEnum or extractMacro)) then
        usage("Option -f only available for enum or macro extraction")
    end

    if (printConstInt or reverse) then
        usage("Option -f is incompatible with -C or -R")
    end

    local func, errmsg = loadstring([[
local f=string.format
return function(k, v, enumName, enumIntTypeName, enumPrefixLength)
]]..fmtfuncCode..[[
end
]])
    if (func == nil) then
        io.stderr:write("Error loading '-f' string: "..errmsg.."\n")
        os.exit(1)
    end

    fmtfunc = func()
end

local tuOptions = extractMacro and {"DetailedPreprocessingRecord"} or nil

local filename = args[1]
do
    local f, msg = io.open(filename)
    if (f == nil) then
        errprintf("ERROR: Failed opening %s", msg)
        os.exit(1)
    end
    f:close()
end

for _, additionalArg in ipairs(additionalArgs) do
    args[#args + 1] = additionalArg
end

hacks.addSystemInclude(args, "c")

local index = cl.createIndex(true, false)
local tu, errorCode = index:parse("", args, tuOptions)

if (tu == nil) then
    errprintf("ERROR: Failed parsing %s (%s)", filename, errorCode)
    os.exit(1)
end

local haveErrors = false

if (not quiet) then
    local diags = tu:diagnosticSet()

    for i=1,#diags do
        local d = diags[i]
        local severity = d:severity()
        haveErrors = haveErrors or (severity == "error" or severity == "fatal")

        io.stderr:write(d:format().."\n")
    end
end

-- Mapping of enum value to its name for -R.
local enumname = {}
-- Mapping of running index to enum value for -R.
local enumseq = {}

local function checkexclude(name)
    for i=1,#excludePatterns do
        if (name:find(excludePatterns[i])) then
            return true
        end
    end
end

-- Get definition string of #define macro definition cursor.
local function getDefStr(cur)
    local tokens = cur:_tokens()
    -- TOKENIZE_WORKAROUND
--    print("tokens: ["..table.concat(tokens, "|", 2, #tokens).."]")
    if (#tokens >= 3) then
        tokens[#tokens] = nil
    end
    return table.concat(tokens, " ", 2, #tokens)
end

local function getCommonPrefixLengthOfEnums(enumDeclCur)
    local commonPrefix = util.getCommonPrefix(
        function(_, cur) return cur:displayName() end,
        nil, ipairs(enumDeclCur:children()))

    if (commonPrefix ~= nil) then
        return #commonPrefix
    end
end

local matchCount = 0

local function printfMatch(fmt, ...)
    printf(fmt, ...)
    matchCount = matchCount + 1
end

-- The <name> in 'enum <name>' if available, or the empty string:
local currentEnumName

local currentEnumIntTypeName
local currentEnumPrefixLength

-- NOTE: cl.ChildVisitResult is not available when run from 'make bootstrap', so
-- use string enum constant names.

local visitor = cl.regCursorVisitor(
function(cur, parent)
    if (extractEnum) then
        if (cur:haskind("EnumDecl")) then
            if (enumNameFilterPattern ~= nil and not cur:name():find(enumNameFilterPattern)) then
                return 'CXChildVisit_Continue'
            else
                currentEnumName = cur:name()
                currentEnumIntTypeName = cur:enumIntegerType():name()
                currentEnumPrefixLength = getCommonPrefixLengthOfEnums(cur)
                return 'CXChildVisit_Recurse'
            end
        end
    end

    if (cur:haskind(what)) then
        local name = cur:displayName()

        if (filterPattern == nil or name:find(filterPattern)) then
            if (not checkexclude(name)) then
                local ourname = stripPattern and name:gsub(stripPattern, "") or name

                if (extractEnum or extractMacro) then
                    -- Enumeration constants
                    local val = extractEnum and cur:enumval() or getDefStr(cur)

                    -- Notes:
                    --  - tonumber(val) == nil can only happen with #defines that are not
                    --    like a literal number.
                    --  - We only use tonumber() for the check here. To convert, we output
                    --    the token as it appears in the source code. This way, numbers
                    --    written in octal are correctly preserved.
                    if (not extractMacro or tonumber(val) ~= nil) then
                        if (fmtfunc) then
                            local str = fmtfunc(ourname, val,
                                                currentEnumName,
                                                currentEnumIntTypeName,
                                                currentEnumPrefixLength)
                            printfMatch("%s", str)
                        elseif (reverse) then
                            if (enumname[val]) then
                                printf("Error: enumeration value %d not unique: %s and %s",
                                       val, enumname[val], ourname)
                                os.exit(2)
                            end
                            enumname[val] = ourname
                            enumseq[#enumseq+1] = val
                        elseif (printConstInt) then
                            printfMatch("static const int %s = %s;", ourname, val)
                        else
                            printfMatch("%s = %s,", ourname, val)
                        end
                    end
                elseif (what=="FunctionDecl") then
                    -- Function declaration
                    local rettype = cur:resultType()
                    if (not checkexclude(rettype:name())) then
                        printfMatch("%s %s;", rettype, ourname)
                    end
                elseif (what=="TypedefDecl") then
                    -- Type definition
                    local utype = cur:typedefType()
                    if (not checkexclude(utype:name())) then
                        printfMatch("typedef %s %s;", utype, ourname)
                    end
--[[
                elseif (extractMacro) then
                    local fn, linebeg, lineend = cur:location(true)
                    local defstr = getDefStr(cur)

                    printfMatch("%s @ %s:%d%s :: %s", ourname, fn, linebeg,
                           (lineend~=linebeg) and "--"..lineend or "", defstr)
--]]
                else
                    -- Anything else
                    printfMatch("%s", ourname)
                end
            end
        end
    end

    return 'CXChildVisit_Continue'
end)

if (prefixString) then
    print(prefixString)
end

tu:cursor():children(visitor)

if (reverse) then
    for i=1,#enumseq do
        local val = enumseq[i]
        local name = enumname[val]
        printfMatch("[%d] = %q;", val, name)
    end
end

if (suffixString) then
    print(suffixString)
end

if (haveErrors or matchCount == 0) then
    os.exit(1)
end
