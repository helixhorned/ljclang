#!/usr/bin/env luajit
-- mgrep.lua -- Search for named member accesses.

local io = require("io")
local os = require("os")
local table = require("table")

local cl = require("ljclang")

local print = print

----------

local function printf(fmt, ...)
    print(string.format(fmt, ...))
end

local function errprintf(fmt, ...)
    io.stderr:write(string.format(fmt, ...).."\n")
end

local function usage(hline)
    if (hline) then
        print(hline)
    end
    print("Usage: "..arg[0].." -t <typedefName> -m <memberName> -O '<clang_options...>' [options...] <file.{c,h}> ...")
    print("  -n: only parse and potentially print diagnostics")
    print("  -q: be quiet (don't print diagnostics)")
    os.exit(1)
end


local parsecmdline = require("parsecmdline_pk")
local opt_meta = { t=true, m=true, O=true, q=false, n=false, }

local opts, files = parsecmdline.getopts(opt_meta, arg, usage)

local typedefName = opts.t
local memberName = opts.m
local clangOpts = opts.O
local quiet = opts.q
local dryrun = opts.n

if (not typedefName or not memberName) then
    usage("Must provide -t and -m options")
end

local V = cl.ChildVisitResult

local g_curFileName
-- The StructDecl of the type we're searching for.
local g_structDecl

local visitorGetType = cl.regCursorVisitor(
function(cur, parent)
    if (cur:haskind("TypedefDecl")) then
        local typ = cur:typedefType()
        local structDecl = typ:declaration()
        if (structDecl:haskind("StructDecl")) then
--            printf("typedef %s %s", structDecl:name(), cur:name())
            if (cur:name() == typedefName) then
                g_structDecl = structDecl
                return V.Break
            end
        end
    end

    return V.Continue
end)

-- Get a line from a source file.
-- XXX: we could coalesce all queries for one file into one io.open() and file
-- traversal, but it seems that parsing is the bottleneck anyway.
local function getline(fn, line)
    local f = io.open(fn)
    if (f == nil) then
        return
    end

    local str
    while (line > 0) do
        str = f:read("*l")
        line = line-1
    end

    f:close()
    return str
end

local visitor = cl.regCursorVisitor(
function(cur, parent)
    if (cur:haskind("MemberRefExpr")) then
        local membname = cur:name()
        if (membname==memberName) then
            local def = cur:definition():parent()
            if (def:haskind("StructDecl") and def == g_structDecl) then
                local fn, line = cur:location()
                local str = table.concat(cur:_tokens(tu), "")
                printf("%s:%d: %s", g_curFileName, line, getline(fn,line) or str)
            end
        end
    end

    return V.Recurse
end)

for fi=1,#files do
    local fn = files[fi]
    g_curFileName = fn

    local index = cl.createIndex(true, false)
    local tu = index:parse(fn, clangOpts)
    if (tu == nil) then
        errprintf("Failed parsing '%s'", fn)
        os.exit(1)
    end

    if (not quiet) then
        local diags = tu:diagnostics()
        for i=1,#diags do
            local d = diags[i]
            errprintf("%s", d.text)
        end
    end

    if (not dryrun) then
        local tuCursor = tu:cursor()
        tuCursor:children(visitorGetType)

        if (g_structDecl == nil) then
            if (not quiet) then
                errprintf("%s: Didn't find declaration for '%s'", fn, typedefName)
            end
        else
            tuCursor:children(visitor)
            g_structDecl = nil
        end
    end
end
