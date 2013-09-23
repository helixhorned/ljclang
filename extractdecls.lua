#!/usr/bin/env luajit

local arg = arg

local string = require("string")
local io = require("io")
local os = require("os")
local table = require("table")

local cl = require("ljclang")

local print = print

----------

local function printf(fmt, ...)
    print(string.format(fmt, ...))
end

local function usage(hline)
    if (hline) then
        print(hline)
    end
    print("Usage: "..arg[0].." [our_options...] <file.h> [clang_options...]")
    print "  -p <filterPattern>"
    print "  -x <excludePattern1> [-x <excludePattern2>] ..."
    print "  -s <stripPattern>"
    print "  -1 <string to print before everything>"
    print "  -2 <string to print after everything>"
    print "  -C: print lines like"
    print "       static const int membname = 123;  (enums/macros only)"
    print "  -R: reverse mapping, only if one-to-one. Print lines like"
    print "       [123] = \"membname\";  (enums/macros only)"
    print "  -f <formatFunc>: user-provided body for formatting function (enums/macros only)"
    print "       Accepts args `k', `v'; `f' is string.format. Must return a formatted line."
    print[[       Example: "return f('%s = %s%s,', k, k:find('KEY_') and '65536+' or '', v)"]]
    print "       Incompatible with -C or -R."
    print "  -Q: be quiet"
    print "  -w: extract what? Can be"
    print "       EnumConstantDecl (default), TypedefDecl, FunctionDecl, MacroDefinition"
    os.exit(1)
end

local parsecmdline = require("parsecmdline_pk")

-- Meta-information about options, see parsecmdline_pk.
local opt_meta = { p=true, x=1, s=true, C=false, R=false, Q=false,
                   ['1']=true, ['2']=true, w=true, f=true }

local opts, args = parsecmdline.getopts(opt_meta, arg, usage)

local pat = opts.p
local xpats = opts.x
local spat = opts.s
local constint = opts.C
local reverse = opts.R
local quiet = opts.Q
local what = opts.w or "EnumConstantDecl"
local fmtfuncCode = opts.f

local extractEnum = (what == "EnumConstantDecl")
local extractMacro = (what:find("^Macro"))

local printbefore = opts['1']
local printafter = opts['2']

if (#args == 0) then
    usage()
end

if (not (extractEnum or extractMacro) and (constint or reverse)) then
    usage("Options -C and -R only available for enum or macro extraction")
end

local fmtfunc
if (fmtfuncCode) then
    if (not (extractEnum or extractMacro)) then
        usage("Option -f only available for enum or macro extraction")
    end

    if (constint or reverse) then
        usage("Option -f is incompatible with -C or -R")
    end

    local func, errmsg = loadstring([[
local f=string.format
return function(k, v)
]]..fmtfuncCode..[[
end
]])
    if (func == nil) then
        io.stderr:write("Error loading string: "..errmsg.."\n")
        os.exit(1)
    end

    fmtfunc = func()
end

local opts = extractMacro and {"DetailedPreprocessingRecord"} or nil

local index = cl.createIndex(true, false)
local tu = index:parse(args, opts)
if (tu == nil) then
    print('Parsing failed')
    os.exit(1)
end

if (not quiet) then
    local diags = tu:diagnostics()
    for i=1,#diags do
        local d = diags[i]
        io.stderr:write(d.text.."\n")
    end
end

-- Mapping of enum value to its name for -R.
local enumname = {}
-- Mapping of running index to enum value for -R.
local enumseq = {}

local V = cl.ChildVisitResult

local function checkexclude(name)
    for i=1,#xpats do
        if (name:find(xpats[i])) then
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

local visitor = cl.regCursorVisitor(
function(cur, parent)
    if (extractEnum) then
        if (cur:haskind("EnumDecl")) then
            return V.Recurse
        end
    end

    if (cur:haskind(what)) then
        local name = cur:displayName()

        if (pat == nil or name:find(pat)) then
            local exclude = false

            if (not checkexclude(name)) then
                local ourname = spat and name:gsub(spat, "") or name

                if (extractEnum or extractMacro) then
                    -- Enumeration constants
                    local val = extractEnum and cur:enumval() or getDefStr(cur)

                    -- NOTE: tonumber(val) == nil can only happen with #defines that are not
                    -- like a literal number.
                    if (not extractMacro or tonumber(val) ~= nil) then
                        if (fmtfunc) then
                            print(fmtfunc(ourname, val))
                        elseif (reverse) then
                            if (enumname[val]) then
                                printf("Error: enumeration value %d not unique: %s and %s",
                                       val, enumname[val], ourname)
                                os.exit(2)
                            end
                            enumname[val] = ourname
                            enumseq[#enumseq+1] = val
                        elseif (constint) then
                            printf("static const int %s = %s;", ourname, val)
                        else
                            printf("%s = %s,", ourname, val)
                        end
                    end
                elseif (what=="FunctionDecl") then
                    -- Function declaration
                    local rettype = cur:resultType()
                    if (not checkexclude(rettype:name())) then
                        printf("%s %s;", rettype, ourname)
                    end
                elseif (what=="TypedefDecl") then
                    -- Type definition
                    local utype = cur:typedefType()
                    if (not checkexclude(utype:name())) then
                        printf("typedef %s %s;", utype, ourname)
                    end
--[[
                elseif (extractMacro) then
                    local fn, linebeg, lineend = cur:location(true)
                    local defstr = getDefStr(cur)

                    printf("%s @ %s:%d%s :: %s", ourname, fn, linebeg,
                           (lineend~=linebeg) and "--"..lineend or "", defstr)
--]]
                else
                    -- Anything else
                    printf("%s", ourname)
                end
            end
        end
    end

    return V.Continue
end)

if (printbefore) then
    print(printbefore)
end

tu:cursor():children(visitor)

if (reverse) then
    for i=1,#enumseq do
        local val = enumseq[i]
        local name = enumname[val]
        printf("[%d] = %q;", val, name)
    end
end

if (printafter) then
    print(printafter)
end
