#!/usr/bin/env luajit
-- mgrep.lua -- Search for named member accesses.

local require = require

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

local compile_commands_util = require("compile_commands_util")

local abs = math.abs
local format = string.format

local arg = arg
local assert = assert
local ipairs = ipairs
local print = print
local type = type

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

local function errprint(str)
    io.stderr:write(str.."\n")
end

local function errprintf(fmt, ...)
    errprint(format(fmt, ...))
end

local function abort(str)
    errprint(str.."\n")
    os.exit(1)
end

local function usage(hline)
    if (hline) then
        errprint("ERROR: "..hline.."\n")
    end
    local progname = arg[0]:match("([^/]+)$")
    errprint("Usage:\n  "..progname.." <typeName>::<memberName> [options...] [filenames...]\n")
    errprint
[[
Options:
  -d /path/to/compile_commands.json: use compilation database
  -O '<clang_options...>': pass options to Clang, split at whitespace
  --no-color: Turn off match and diagnostic highlighting
  -n: only parse and potentially print diagnostics
  -q: be quiet (don't print diagnostics)

  For the compilation DB invocation, -O can be used for e.g.
    -I./clang-include (-> /usr/local/lib/clang/3.7.0/include)
  (Attempt to use either -isystem or -I/usr/local/lib/clang/3.7.0/include
  to prevent messages like "fatal error: 'stddef.h' file not found".)
  This issue seems to be fixed with LLVM 4.0 though.
]]
    os.exit(1)
end

if (arg[1] == nil) then
    usage()
end

local parsecmdline = require("parsecmdline_pk")
local opt_meta = {
    [0] = -1,
    d=true, O=true, q=false, n=false,
    ["-no-color"]=false
}

local opts, files = parsecmdline.getopts(opt_meta, arg, usage)

local compDbName = opts.d
local clangOpts = opts.O
local quiet = opts.q
local dryrun = opts.n
local useColors = not opts["-no-color"]

local queryStr = files[0]
files[0] = nil

if (queryStr == nil) then
    usage("Must provide <typeName>::<memberName> to search for as first argument")
end

local function parseQueryString(qstr)
    local pos = qstr:find("::")
    if (pos == nil) then
        abort("ERROR: member to search for must be specified as <typeName>::<memberName>")
    end

    return qstr:sub(1,pos-1), qstr:sub(pos+2)
end

local typeName, memberName = parseQueryString(queryStr)

-- The ClassDecl or StructDecl of the type we're searching for:
local g_structDecl
local g_cursorKind

local V = cl.ChildVisitResult
-- Visitor for finding the named structure declaration.
local GetTypeVisitor = cl.regCursorVisitor(
function(cur, parent)
    local curKind = cur:kind()

    if (curKind == "ClassDecl" or curKind == "StructDecl") then
        if (cur:name() == typeName) then
            g_structDecl = cl.Cursor(cur)
            g_cursorKind = curKind
            return V.Break
        end
    elseif (curKind == "TypedefDecl") then
        local typ = cur:typedefType()
        local structDecl = typ:declaration()
        if (structDecl:haskind("StructDecl")) then
--            printf("typedef struct %s %s", structDecl:name(), cur:name())
            if (cur:name() == typeName) then
                g_structDecl = structDecl
                g_cursorKind = "StructDecl"
                return V.Break
            end
        end
    end

    -- The structure declaration might not be found on the top level for C++
    -- code, 'Recurse' instead of 'Continue'.
    --
    -- NOTE: Of course, mgrep does not have any notable C++ naming support, but
    -- one might use it to search code originally written as C which then had
    -- C++ "added in".
    return V.Recurse
end)

--------------------

local Col = require("terminal_colors")
local colorize = Col.colorize

local SourceFile = class
{
    function(fn)
        local fh, msg = io.open(fn)
        if (fh == nil) then
            errprintf("Could not open %s", msg)
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
        if (membname == memberName) then
            local def = cur:definition():parent()
            if (def:haskind(g_cursorKind) and def == g_structDecl) then
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
        strtab[#strtab+1] = colorize(str:sub(b,e-1), Col.Bold..Col.Red)
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
            local line = abs(lines[li])
            local str = f:getLine(line)
            if (useColors) then
                str = colorizeResult(str, pairs[li])
            end
            printf("%s:%d: %s", fn, line, str)
        end
    end
end

-- Use a compilation database?
local useCompDb = (compDbName ~= nil)
local compArgs = {}  -- if using compDB, will have #compArgs == #compDbEntries, each a table

if (not useCompDb and #files == 0) then
    os.exit(0)
end

if (useCompDb) then
    if (#files > 0) then
        usage("When using compilation database, must pass no file names")
    end

    local compDbPos = compDbName:find("[\\/]compile_commands.json$")
    if (compDbPos == nil) then
        usage("File name of compilation database must be compile_commands.json")
    end

    local compDbDir = compDbName:sub(1, compDbPos)
    local db = cl.CompilationDatabase(compDbDir)

    if (db == nil) then
        abort("Fatal: Could not load compilation database")
    end

    local cmds = db:getAllCompileCommands()

    if (#cmds == 0) then
        -- NOTE: We get a CompilationDatabase even if
        -- clang_CompilationDatabase_fromDirectory() failed (as evidenced by
        -- error output from "LIBCLANG TOOLING").
        abort("Fatal: Compilation database contains no entries, or an error occurred")
    end

    for ci, cmd in ipairs(cmds) do
        local args = compile_commands_util.sanitize_args(cmd:getArgs(), cmd:getDirectory())

        if (clangOpts ~= nil) then
            local suffixArgs = cl.splitAtWhitespace(clangOpts)
            for ai=1,#suffixArgs do
                args[#args+1] = suffixArgs[ai]
            end
        end
        compArgs[ci] = args
    end

    for i=1,#cmds do
        -- Fake presence of files for compilation database mode for the later loop.
        files[i] = "/dev/null"  -- XXX: Windows
    end
end

local function GetColorizeTripleFunc(severityTextColor, colorizeMainText)
    return function(pre, tag, post)
        return
            colorize(pre, Bold..White)..
            colorize(tag, Bold..severityTextColor)..
            (colorizeMainText and colorize(post, Bold..White) or post)
    end
end

local ColorizeErrorFunc = GetColorizeTripleFunc(Red, true)
local ColorizeWarningFunc = GetColorizeTripleFunc(Purple, true)
local ColorizeNoteFunc = GetColorizeTripleFunc(Black, false)

local function FormatDiagnostic(diag, printCategory)
    local text = diag:format()

    if (useColors) then
        text = text:gsub("(.*)(error: )(.*)", ColorizeErrorFunc)
        text = text:gsub("(.*)(warning: )(.*)", ColorizeWarningFunc)
        text = text:gsub("(.*)(note: )(.*)", ColorizeNoteFunc)
    end

    local category = diag:category()
    return text .. ((printCategory and #category > 0) and " ["..category.."]" or "")
end

local function PrintPrefixDiagnostics(diags, indentation)
    for i = 1, #diags do
        local text = diags[i]:spelling()

        if (text:match("^in file included from ")) then
            errprintf("%s%s", string.rep(" ", indentation), "In"..text:sub(3))
        else
            return i
        end
    end

    return #diags + 1
end

local function PrintDiagnostics(diags, startIndex, indentation)
    assert(type(startIndex) == "number")
    assert(type(indentation) == "number")

    for i = startIndex, #diags do
        local diag = diags[i]
        local childDiags = diag:childDiagnostics()

        local innerStartIndex = PrintPrefixDiagnostics(childDiags, indentation)
        errprintf("%s%s", string.rep(" ", indentation), FormatDiagnostic(diag, indentation == 0))
        -- Recurse. We expect only at most two levels in total (but do not check for that).
        PrintDiagnostics(diag:childDiagnostics(), innerStartIndex, indentation + 2)

        if (indentation == 0) then
            -- Print a newline.
            errprintf("")
        end
    end
end

local foundStruct = false

for fi=1,#files do
    local fn = files[fi]

    local index = cl.createIndex(true, false)
    local opts = useCompDb and compArgs[fi] or clangOpts or {}

    do
        local f, msg = io.open(fn)
        if (f == nil) then
            errprintf("ERROR: Failed opening %s", msg)
            goto nextfile
        end
        f:close()
    end

    local tu, errorCode = index:parse(useCompDb and "" or fn, opts, {"KeepGoing"})

    if (tu == nil) then
        errprintf("ERROR: Failed parsing %s: %s", fn, errorCode)
        goto nextfile
    end

    if (not quiet) then
        PrintDiagnostics(tu:diagnosticSet(), 1, 0)
    end

    if (not dryrun) then
        local tuCursor = tu:cursor()
        tuCursor:children(GetTypeVisitor)

        if (g_structDecl ~= nil) then
            tuCursor:children(SearchVisitor)
            printResults()
            clearResults()
            g_structDecl = nil
            g_cursorKind = nil
            foundStruct = true
        end
    end

    ::nextfile::
end

if (not foundStruct) then
    if (not quiet) then
        errprintf("Did not find declaration for '%s'.", typeName)
    end
    os.exit(1)
end
