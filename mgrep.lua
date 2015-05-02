#!/usr/bin/env luajit
-- mgrep.lua -- Search for named member accesses.

local io = require("io")
local os = require("os")
local string = require("string")
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
        print("ERROR: "..hline)
        print("")
    end
    local progname = arg[0]:match("([^/]+)$")
    print("Usage: "..progname.." -t <typedefName> -m <memberName> -O '<clang_options...>' [options...] <file.{c,h}> ...")
    print("       "..progname.." -t <typedefName> -m <memberName> [-O '<clang_option>'] [options...] /path/to/compile_commands.json")
    print("")
    print("  For the compilation DB invocation, -O can be used for e.g. -I./clang-include (-> /usr/local/lib/clang/3.7.0/include)")
    print("  (Workaround for -isystem and -I/usr/local/lib/clang/3.7.0/include not working)")
    print("\nOptions:")
    print("  -n: only parse and potentially print diagnostics")
    print("  -q: be quiet (don't print diagnostics)")
    os.exit(1)
end

if (arg[1] == nil) then
    usage()
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

-- Visitor for finding the named structure declaration.
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

-- Visitor for looking for the wanted member accesses.
local visitor = cl.regCursorVisitor(
function(cur, parent)
    if (cur:haskind("MemberRefExpr")) then
        local membname = cur:name()
        if (membname==memberName) then
            local def = cur:definition():parent()
            if (def:haskind("StructDecl") and def == g_structDecl) then
                local fn, line = cur:location()
--                local str = table.concat(cur:_tokens(tu), "")
                printf("%s:%d: %s", g_curFileName, line, getline(fn,line))
            end
        end
    end

    return V.Recurse
end)

local function getAllSourceFiles(db)
    local cmds = db:getAllCompileCommands()

    local haveSrc = {}
    local srcFiles = {}

    for ci=1,#cmds do
        local fns = cmds[ci]:getSourcePaths()
        for j=1,#fns do
            local fn = fns[j]
            if (not haveSrc[fn]) then
                haveSrc[fn] = true
                srcFiles[#srcFiles+1] = fn
            end
        end
    end

    return srcFiles
end

-- Make "-Irelative/subdir" -> "-I/path/to/relative/subdir",
-- <opts> is modified in-place.
local function absifyIncOpts(opts, prefixDir)
    if (prefixDir:sub(1,1) ~= "/") then
        -- XXX: Windows.
        errprintf('mgrep.lua: prefixDir "%s" does not start with "/".', prefixDir)
        os.exit(1)
    end

    for i=1,#opts do
        local opt = opts[i]
        if (opt:sub(1,2)=="-I" and opt:sub(3,3)~="/") then
            opts[i] = "-I" .. prefixDir .. "/" .. opt:sub(3)
        end
    end

    return opts
end

if (#files == 0) then
    os.exit(0)
end

-- Use a compilation database?
local compDbPos = files[#files]:find("[\\/]compile_commands.json$")
local useCompDb = (compDbPos ~= nil)
local compArgs = {}  -- if using compDB, will have #compArgs == #files, each a table

if (not useCompDb and clangOpts == nil) then
    usage("When not using compilation database, must pass -O")
end

if (useCompDb) then
    if (#files ~= 1) then
        usage("When using compilation database, must pass no additional file names")
    end

    local compDbDir = files[1]:sub(1, compDbPos)
    local db = cl.CompilationDatabase(compDbDir)

    if (db == nil) then
        errprintf('Fatal: Could not load compilation database')
        os.exit(1)
    end

    -- Get all source files, uniq'd.
    files = getAllSourceFiles(db)

    if (#files == 0) then
        -- NOTE: We may get a CompilationDatabase even if
        -- clang_CompilationDatabase_fromDirectory() failed (as evidenced by
        -- error output from "LIBCLANG TOOLING").
        errprintf('Fatal: Compilation database contains no entries, or an error occurred')
        os.exit(1)
    end

    for fi=1,#files do
        local cmds = db:getCompileCommands(files[fi])
        -- NOTE: Only use the first CompileCommand for a given file name:
        local cmd = cmds[1]

        -- NOTE: Strip "-c" and "-o" options from args. (else: "crash detected" for me)
        local args = cl.stripArgs(cmd:getArgs(false), "^-[co]$", 2)
        absifyIncOpts(args, cmd:getDirectory())

        -- Regarding "fatal error: 'stddef.h' file not found": for me,
        --  * -isystem didn't work ("crash detected").
        --  * -I/usr/local/lib/clang/3.7.0/include didn't work either
        --    (no effect)
        --  * -I<symlink to /usr/local/lib/clang/3.7.0/include> did work...

        if (clangOpts ~= nil) then
            -- NOTE: Assuming that -O got passed only one option.
            args[#args+1] = clangOpts
        end
        compArgs[fi] = args
--[[
        if (fi == 1) then
            print('----------')
            for i=1,#args do
                print(args[i])
            end
            print('----------')
        end
--]]
    end
end

for fi=1,#files do
    local fn = files[fi]
    g_curFileName = fn

    local index = cl.createIndex(true, false)
    local opts = useCompDb and compArgs[fi] or clangOpts
    local tu = index:parse(fn, opts)
    if (tu == nil) then
        errprintf("Fatal: Failed parsing '%s'", fn)
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
            if (not quiet and not useCompDb) then
                -- XXX: This is kind of noisy even in non-DB
                -- mode. E.g. "mgrep.lua *.c": some C files may not include a
                -- particular header.
                errprintf("%s: Didn't find declaration for '%s'", fn, typedefName)
            end
        else
            tuCursor:children(visitor)
            g_structDecl = nil
        end
    end
end
