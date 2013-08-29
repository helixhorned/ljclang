#!/usr/bin/env luajit

local arg = arg

local string = require("string")
local io = require("io")
local os = require("os")

local cl = require("ljclang")

----------

function printf(fmt, ...)
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
    print "      static const int membname = 123;"
    print "  -R: reverse mapping, only if one-to-one. Print lines like"
    print "      [123] = \"membname\";"
    print "  -Q: be quiet"
    os.exit(1)
end

local opt_hasarg = { p=true, x=true, s=true, C=false, R=false, Q=false,
                     ['1']=true, ['2']=true }
local opts = { x={} }

-- The arguments to be eventually passed to libclang
local args = {}
local filename

do  -- Get options from command line.
    local skipnext = false
    for i=1,#arg do
        if (skipnext) then
            skipnext = false
            goto next
        end

        if (arg[i]:sub(1,1)=="-") then
            local opt = arg[i]:sub(2)
            skipnext = opt_hasarg[opt]
            if (skipnext == nil) then
                usage("Unrecognized option "..arg[i])
            elseif (skipnext) then
                if (arg[i+1] == nil) then
                    usage()
                end
                if (opt=='x') then
                    opts.x[#opts.x+1] = arg[i+1]
                else
                    opts[opt] = arg[i+1]
                end
            else
                opts[opt] = true
            end
        else
            local ii=1
            for j=i,#arg do
                args[ii] = arg[j]
                ii = ii+1
            end
            break
        end
::next::
    end
end

local pat = opts.p
local xpats = opts.x
local spat = opts.s
local constint = opts.C
local reverse = opts.R
local quiet = opts.Q

local printbefore = opts['1']
local printafter = opts['2']

if (#args == 0) then
    usage()
end

local index = cl.createIndex(true, false)
local tu = index:parse(args)
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

-- TODO: implications of
-- local tu = cl.createIndex(true, false):parse(args)
-- collectgarbage()
-- tu:file()

-- Mapping of enum value to its name for -R.
local enumname = {}
-- Mapping of running index to enum value for -R.
local enumseq = {}

local V = cl.ChildVisitResult

local visitor = cl.regCursorVisitor(
function(cur, parent)
    if (cur:haskind("EnumDecl")) then
        return V.Recurse
    end

    if (cur:haskind("EnumConstantDecl")) then
        local name = cur:name()

        if (pat == nil or name:find(pat)) then
            local exclude = false

            for i=1,#xpats do
                if (name:find(xpats[i])) then
                    exclude = true
                    break
                end
            end

            if (not exclude) then
                local ourname = spat and name:gsub(spat, "") or name
                local val = cur:enumval()
                if (reverse) then
                    if (enumname[val]) then
                        printf("Error: enumeration value %d not unique: %s and %s",
                               val, enumname[val], ourname)
                        os.exit(2)
                    end
                    enumname[val] = ourname
                    enumseq[#enumseq+1] = val
                elseif (constint) then
                    printf("static const int %s = %d;", ourname, val)
                else
                    printf("%s = %d,", ourname, val)
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
