#!/usr/bin/env luajit
-- mgrep.lua -- Search for named member accesses.

local io = require("io")
local os = require("os")
local math = require("math")
local string = require("string")
local table = require("table")

local jit = require("jit")
local ffi = require("ffi")
local C = ffi.C

local cl = require("ljclang")
local class = require("class").class

local abs = math.abs
local format = string.format

local assert = assert
local print = print

ffi.cdef[[
char *getcwd(char *buf, size_t size);
void free(void *ptr);
]]

local function getcwd()
    if (jit.os ~= "Linux") then
        return nil
    end

    local cwd = C.getcwd(nil, 0)
    if (cwd == nil) then
        return nil
    end

    local str = ffi.string(cwd)
    C.free(cwd)
    return str
end

----------

local function printf(fmt, ...)
    print(format(fmt, ...))
end

local function errprintf(fmt, ...)
    io.stderr:write(format(fmt, ...).."\n")
end

local function usage(hline)
    if (hline) then
        print("ERROR: "..hline)
        print("")
    end
    local progname = arg[0]:match("([^/]+)$")
    print("Usage: "..progname.." -t <typedefName> -m <memberName> -O '<clang_options...>' [options...] <file.{c,h}> ...")
    print("       "..progname.." -t <typedefName> -m <memberName> [-O '<clang_options...>'] [options...] /path/to/compile_commands.json")
    print("")
    print("  For the compilation DB invocation, -O can be used for e.g. -I./clang-include (-> /usr/local/lib/clang/3.7.0/include)")
    print("  (Workaround for -isystem and -I/usr/local/lib/clang/3.7.0/include not working)")
    print("\nOptions:")
    print("  --no-color: Turn off match and diagnostic highlighting")
    print("  -n: only parse and potentially print diagnostics")
    print("  -q: be quiet (don't print diagnostics)")
    os.exit(1)
end

if (arg[1] == nil) then
    usage()
end

local parsecmdline = require("parsecmdline_pk")
local opt_meta = { t=true, m=true, O=true, q=false, n=false,
                   ["-no-color"]=false }

local opts, files = parsecmdline.getopts(opt_meta, arg, usage)

local typedefName = opts.t
local memberName = opts.m
local clangOpts = opts.O
local quiet = opts.q
local dryrun = opts.n
local useColors = not opts["-no-color"]

if (not typedefName or not memberName) then
    usage("Must provide -t and -m options")
end

local V = cl.ChildVisitResult

local g_curFileName
-- The StructDecl of the type we're searching for.
local g_structDecl

-- Visitor for finding the named structure declaration.
local GetTypeVisitor = cl.regCursorVisitor(
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

--------------------

-- For reference:
-- https://wiki.archlinux.org/index.php/Color_Bash_Prompt#List_of_colors_for_prompt_and_Bash

--local Normal = "0;"
local Bold = "1;"
--local Uline = "4;"

--local Black = "30m"
local Red = "31m"
--local Green = "32m"
--local Yellow = "33m"
--local Blue = "34m"
local Purple = "35m"
--local Cyan = "36m"
local White = "37m"

local function colorize(str, modcolor)
    return "\027["..modcolor..str.."\027[m"
end

--------------------

local SourceFile = class
{
    function(fn)
        local fh, msg = io.open(fn)
        if (fh == nil) then
            errprintf('Could not open file "%s": %s', fn, msg)
            os.exit(1)
        end

        return { fh=fh, line=0 }
    end,

    __gc = function(f)
        f.fh:close()
    end,

    getLine = function(f, line)
        assert(f.line < line)

        local str
        while (f.line < line) do
            f.line = f.line+1
            str = f.fh:read("*l")
        end

        return str
    end,
}

local g_fileIdx = {}  -- [fileName] = fileIdx
local g_fileName = {}  -- [fileIdx] = fileName
local g_fileLines = {}  -- [fileIdx] = { linenum1, linenum2, ... }, negated if spans >1 line
local g_fileColumnPairs = {}  -- [fileIdx] = { {colBeg1, colEnd1, colBeg2, colEnd2}, ... }

local function clearResults()
    g_fileIdx = {}
    g_fileName = {}
    g_fileLines = {}
    g_fileColumnPairs = {}
end

-- Visitor for looking for the wanted member accesses.
local SearchVisitor = cl.regCursorVisitor(
function(cur, parent)
    if (cur:haskind("MemberRefExpr")) then
        local membname = cur:name()
        if (membname==memberName) then
            local def = cur:definition():parent()
            if (def:haskind("StructDecl") and def == g_structDecl) then
                local fn, line, col, lineEnd, colEnd = cur:location()
                local oneline = (line == lineEnd)

                local idx = g_fileIdx[fn] or #g_fileLines+1
                if (g_fileLines[idx] == nil) then
                    -- encountering file name for the first time
                    g_fileIdx[fn] = idx
                    g_fileName[idx] = fn
                    g_fileLines[idx] = {}
                    g_fileColumnPairs[idx] = {}
                end

                local lines = g_fileLines[idx]
                local haveLine =
                    lines[#lines] ~= nil
                    and (abs(lines[#lines]) == line)

                local lidx = haveLine and #lines or #lines+1

                if (not haveLine) then
                    lines[lidx] = oneline and line or -line
                end

                local colNumPairs = g_fileColumnPairs[idx]
                if (colNumPairs[lidx] == nil) then
                    colNumPairs[lidx] = {}
                end

                local pairs = colNumPairs[lidx]
                if (oneline) then
                    -- The following 'if' check is to prevent adding the same
                    -- column pair twice, e.g. when a macro contains multiple
                    -- references to the searched-for member.
                    if (pairs[#pairs-1] ~= col) then
                        pairs[#pairs+1] = col
                        pairs[#pairs+1] = colEnd
                    end
                end
            end
        end
    end

    return V.Recurse
end)

local function colorizeResult(str, colBegEnds)
    local a=1
    local strtab = {}

    for i=1,#colBegEnds,2 do
        local b = colBegEnds[i]
        local e = colBegEnds[i+1]

        strtab[#strtab+1] = str:sub(a,b-1)
        strtab[#strtab+1] = colorize(str:sub(b,e-1), Bold..Red)
        a = e
    end
    strtab[#strtab+1] = str:sub(a)

    return table.concat(strtab)
end

local curDir = getcwd()

local function printResults()
    for fi = 1,#g_fileName do
        local fn = g_fileName[fi]

        if (curDir ~= nil and fn:sub(1,#curDir)==curDir) then
            fn = "./"..fn:sub(#curDir+2)
        end

        local lines = g_fileLines[fi]
        local pairs = g_fileColumnPairs[fi]

        local f = SourceFile(fn)

        for li=1,#lines do
--            local oneline = (lines[li] > 0)
            local line = abs(lines[li])
            local str = f:getLine(line)
            if (useColors) then
                str = colorizeResult(str, pairs[li])
            end
            printf("%s:%d: %s", fn, line, str)
        end
    end
end

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
            local suffixArgs = cl.splitAtWhitespace(clangOpts)
            for ai=1,#suffixArgs do
                args[#args+1] = suffixArgs[ai]
            end
        end
        compArgs[fi] = args

--        if (fi == 1) then print("Args: "..table.concat(args, ', ').."\n") end
    end
end

local function GetColorizeTripleFunc(color)
    return function(pre, tag, post)
        return
            colorize(pre, Bold..White)..
            colorize(tag, Bold..color)..
            colorize(post, Bold..White)
    end
end

local ColorizeErrorFunc = GetColorizeTripleFunc(Red)
local ColorizeWarningFunc = GetColorizeTripleFunc(Purple)

for fi=1,#files do
    local fn = files[fi]
    g_curFileName = fn

    local index = cl.createIndex(true, false)
    local opts = useCompDb and compArgs[fi] or clangOpts

    do
        local f, msg = io.open(fn)
        if (f == nil) then
            errprintf("ERROR: Failed opening %s", msg)
            goto nextfile
        end
        f:close()
    end

    local tu = index:parse(fn, opts)

    if (tu == nil) then
        errprintf("ERROR: Failed parsing %s", fn)
        goto nextfile
    end

    if (not quiet) then
        local diags = tu:diagnostics()
        for i=1,#diags do
            local text = diags[i].text
            if (useColors) then
                text = text:gsub("(.*)(error: )(.*)", ColorizeErrorFunc)
                text = text:gsub("(.*)(warning: )(.*)", ColorizeWarningFunc)
            end
            errprintf("%s", text)
        end
    end

    if (not dryrun) then
        local tuCursor = tu:cursor()
        tuCursor:children(GetTypeVisitor)

        if (g_structDecl == nil) then
            if (not quiet and not useCompDb) then
                -- XXX: This is kind of noisy even in non-DB
                -- mode. E.g. "mgrep.lua *.c": some C files may not include a
                -- particular header.
                errprintf("%s: Didn't find declaration for '%s'", fn, typedefName)
            end
        else
            tuCursor:children(SearchVisitor)
            printResults()
            clearResults()
            g_structDecl = nil
        end
    end

    ::nextfile::
end
