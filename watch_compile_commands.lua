#!/usr/bin/env luajit

local bit = require("bit")
local ffi = require("ffi")
local io = require("io")
local math = require("math")
local os = require("os")
local string = require("string")
local table = require("table")

local cl -- loaded later
local class = require("class").class
local compile_commands_reader = require("compile_commands_reader")
local compile_commands_util = require("compile_commands_util")
local diagnostics_util = require("diagnostics_util")
local hacks = require("hacks")
local util = require("util")

local inclusion_graph = require("inclusion_graph")
local InclusionGraph = inclusion_graph.InclusionGraph

local Col = require("terminal_colors")

local check = require("error_util").check
local checktype = require("error_util").checktype

local assert = assert
local collectgarbage = collectgarbage
local format = string.format
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local print = print
local require = require
local tostring = tostring
local tonumber = tonumber
local type = type
local unpack = unpack

local arg = arg

----------

local function printf(fmt, ...)
    print(format(fmt, ...))
end

local function errprint(str)
    io.stderr:write(str.."\n")
end

local function errprintf(fmt, ...)
    errprint(format(fmt, ...))
    return true
end

local function abort(fmt, ...)
    errprintf("ERROR: "..fmt, ...)
    os.exit(1)
end

local ErrorCode = {
    CommandLine = 1,
    CompilationDatabaseLoad = 2,
    RealPathName = 3,

    WatchedFileMovedOrDeleted = 100,
    CompileCommandsJsonGeneratedEvent = 101,

    Internal = 255,
}

local function getEnv(varName, name)
    local value = os.getenv(varName)
    if (value == nil) then
        abort("Failed to obtain %s from environment variable %s.", name, varName)
    end
    return value
end

local HomeDir = getEnv("HOME", "home directory")

local PchCacheDirectory = HomeDir.."/.cache/ljclang"
local GlobalInclusionGraphRelation = "isIncludedBy"

local function usage(hline)
    if (hline) then
        errprint("ERROR: "..hline.."\n")
    end

    local progname = arg[0]:match("([^/]+)$")

    printf([[
Usage:
   %s [options...] <compile_commands-file>

In this help text, single quotes ("'") are for exposition purposes only.
They are never to be spelled in actual option arguments.

Options:
  -a: Enable automatic generation and usage of precompiled headers. For each PCH configuration
      (state of relevant compiler options) meeting a certain threshold of compile commands that
      it is used with, a PCH file is generated that includes all standard library headers.
      Note that this will remove errors due to forgetting to include a standard library header.
      Only supported for C++11 upwards.
      Precompiled headers are stored in '%s'.
  -c <concurrency>: set number of parallel parser invocations.
     - 0 means do everything serially (do not fork).
       Limitation: in this mode, changes to watched files lead to a re-processing only after all
       compile commands have been processed.
     - 'auto' means use hardware concurrency (the default).
       With concurrecny enabled, changes to watched files lead to a re-processing of affected
       compile commands as soon as possible.
  -i <severity-spec>: Enable incremental mode. Stop processing further compile commands on the first
     diagnostic matching the severity specification. Its syntax one of:
      1. a comma-separated list, <severity>(,<severity>)*
         where each <severity> is one of 'note', 'warning', 'error' or 'fatal'.
      2. a single severity suffixed by '+', meaning to select the specified severity
         and more serious ones.
     As a convenience, the specification can also be '-', meaning 'error+'.
  -g [includes|isIncludedBy]: Print inclusion graph as a DOT (of Graphviz) file to stdout and exit.
     Argument specifies the relation between graph nodes (which are file names).
  -l <number>: edge count limit for the graph produced by -g %s.
     If exceeded, a placeholder node is placed.
  -r [c<commands>|<seconds>s]: report progress after the specified number of
     processed compile commands or the given time interval.
     Specifying any of 'c0', 'c1' or '0s' effectively prints progress with each compile command.
  -s <selector>: Select compile command(s) to process.
     The following specifications for <selector> are supported:
      - '@...' or '-@...': by index (see below).
      - '{<pattern>}': by Lua pattern matching the absolute file name in a compile command.
      - A single file name which is compared with the suffix of the absolute file name in a
        compile command.
  -N: Print all diagnostics. This disables omission of:
      - diagnostics that follow a Parse Issue error, and
      - diagnostics that were seen in previous compile commands.
  -P: Disable color output.
  -x: exit after parsing and displaying diagnostics once.

  If the argument to option -s starts with '@' or '-@', it must have one of the following forms,
  where the integral <number> starts with a digit distinct from zero:
    - '@<number>': single compile command, or
    - '@<number>-' or '-@<number>': range starting or ending with the specified index, or
    - '@<number>-@<number>': inclusive range.]],
progname, PchCacheDirectory, GlobalInclusionGraphRelation)
    os.exit(ErrorCode.CommandLine)
end

local parsecmdline = require("parsecmdline_pk")

local opts_meta = {
    a = false,
    c = true,
    i = true,
    m = false,
    g = true,
    l = true,
    r = true,
    s = true,
    N = false,
    P = false,
    x = false,
}

local opts, args = parsecmdline.getopts(opts_meta, arg, usage)

local autoPch = opts.a
local concurrencyOpt = opts.c or "auto"
local commandMode = opts.m
local incrementalMode = opts.i
local printGraphMode = opts.g
local edgeCountLimit = tonumber(opts.l)
local progressSpec = opts.r
local selectionSpec = opts.s
local printAllDiags = opts.N or false
local plainMode = opts.P
local exitImmediately = opts.x or printGraphMode

local function colorize(...)
    if (plainMode) then
        return ...
    else
        local encoded_string = Col.encode(...)
        return Col.colorize(encoded_string)
    end
end

local function pluralize(count, noun, pluralSuffix, color)
    pluralSuffix = pluralSuffix or 's'
    noun = (count == 0 or count > 1) and noun..pluralSuffix or noun
    noun = (color ~= nil) and colorize(noun, color) or noun
    return format("%d %s", count, noun)
end

local function exists(fileName)
    local f, msg = io.open(fileName)
    if (f ~= nil) then
        f:close()
        return true
    end
    -- LuaJIT always prepends the file name and ': ' if present. Strip it.
    return false, msg:sub(1 + #fileName + 2)
end

local NOTE = colorize("NOTE", Col.Bold..Col.Blue)

local function info(fmt, ...)
    local func = printGraphMode and errprintf or printf
    func("%s: "..fmt, colorize("INFO", Col.Green), ...)
end

local function errorInfo(fmt, ...)
    local func = printGraphMode and errprintf or printf
    func("%s: "..fmt, colorize("INFO", Col.Bold..Col.Red), ...)
end

local function exitRequestingBugReport()
    errorInfo("Please report this issue as a bug.")
    -- TODO: include URL to github, preferably to the issue tracker with the right branch.
    os.exit(1)
end

local function infoAndExit(fmt, ...)
    info(fmt, ...)
    os.exit(0)
end

if (commandMode) then
    for key, _ in pairs(opts_meta) do
        if key ~= 'm' and opts[key] then
            errprintf("ERROR: Option -%s only available without -m", key)
            os.exit(ErrorCode.CommandLine)
        end
    end
end

local function getUsedConcurrency()
    if (concurrencyOpt == "auto") then
        return cl.hardwareConcurrency()
    else
        if (concurrencyOpt ~= "0" and not concurrencyOpt:match("^[1-9][0-9]*$")) then
            abort("Argument to option -c must be 'auto' or an integral number")
        end

        local c = tonumber(concurrencyOpt)
        assert(c ~= nil)

        if (not (c >= 0)) then
            abort("Argument to option -c must be at least 0 if a number")
        end

        return c
    end
end

if (printGraphMode ~= nil) then
    if (printGraphMode ~= "includes" and printGraphMode ~= "isIncludedBy") then
        abort("Argument to option -g must be 'includes' or 'isIncludedBy'")
    end
end

if (incrementalMode ~= nil) then
    if (incrementalMode == "-") then
        incrementalMode = "error+"
    end

    local SeverityIdx = { note=1, warning=2, error=3, fatal=4 }
    local Severities  = { "note", "warning", "error", "fatal" }

    local incMode = {}

    if (incrementalMode:sub(-1) == '+') then
        local severity = incrementalMode:sub(1, -2)
        local startSeverityIdx = SeverityIdx[severity]

        if (startSeverityIdx == nil) then
            abort("Argument to option -i, when ending with '+', must be a single severity. "..
                      "Unknown severity '%s'.", severity)
        end

        for i = startSeverityIdx, #Severities do
            incMode[Severities[i]] = true
        end
    else
        -- Disallow the empty string manually. Having the pattern for the severity being
        -- able to match the empty string (using '*' instead of '+') is troublesome.
        if (incrementalMode:find("^,") or incrementalMode:find(",,") or incrementalMode:find(",$")) then
            abort("Argument to option -i (when not ending in '+') must be comma-separated list of severities. "..
                      "Unknown severity ''.")
        end

        for severity in incrementalMode:gmatch("[^,]+") do
            if (SeverityIdx[severity] == nil) then
                abort("Argument to option -i (when not ending in '+') must be comma-separated list of severities. "..
                          "Unknown severity '%s'.", severity)
            end
            incMode[severity] = true
        end
    end

    incrementalMode = incMode
end

if (edgeCountLimit ~= nil) then
    if (printGraphMode ~= GlobalInclusionGraphRelation) then
        abort("Option -l can only be used with -g being %s", GlobalInclusionGraphRelation)
    end
end

local printProgressAfterSeconds = nil
local printProgressAfterCcCount = nil

if (progressSpec ~= nil) then
    local isCountSpecified = (progressSpec:sub(1,1) == "c")
    local isSecondsSpecified = (progressSpec:sub(-1) == "s")

    if (not isCountSpecified and not isSecondsSpecified) then
        abort("Argument to option -r must have the form 'c<count>' or '<seconds>s'")
    end

    local num =
        isCountSpecified and tonumber(progressSpec:sub(2)) or
        isSecondsSpecified and tonumber(progressSpec:sub(1,-2))

    if (type(num) ~= "number" or not (num >= 0)) then
        abort("Number passed to option -r must be zero or greater")
    end

    if (isCountSpecified) then
        printProgressAfterCcCount = num
    else
        printProgressAfterSeconds = num
    end
end

local compileCommandsFile = args[1]

if (compileCommandsFile == nil) then
    usage()
end

-- Late load to allow printing the help text with a plain invocation.
cl = require("ljclang")
local posix = require("posix")
local POLL = posix.POLL
local inotify = require("inotify")
local IN = inotify.IN

----------

local compileCommands, errorMessage =
    compile_commands_reader.read_compile_commands(compileCommandsFile)

if (compileCommands == nil) then
    errprintf("ERROR: failed loading '%s': %s", compileCommandsFile, errorMessage)
    os.exit(ErrorCode.CompilationDatabaseLoad)
end

if (#compileCommands == 0) then
    infoAndExit("'%s' contains zero entries.", compileCommandsFile)
end

local compileCommandSelection = {
    originalCount = #compileCommands,
    -- [selected compile command index] = <original compile command index>
}

local haveFileSelection = (selectionSpec ~= nil) and (selectionSpec:sub(1, 1) == '{')

if (selectionSpec ~= nil) then
    local newCompileCommands = {}

    local function selectCompileCommand(i)
        local newIndex = #newCompileCommands + 1
        newCompileCommands[newIndex] = compileCommands[i]
        compileCommandSelection[newIndex] = i
    end

    if (selectionSpec:match("^-?@")) then
        local startStr = selectionSpec:match("^@[1-9][0-9]*") or ""
        local endStr = selectionSpec:match("@[1-9][0-9]*$") or ""
        local startIndex = tonumber(startStr:sub(2)) or 1
        local endIndex = tonumber(endStr:sub(2)) or #compileCommands

        local isSingleIndex = (selectionSpec == startStr and selectionSpec == endStr)
        local isRange = (selectionSpec == startStr..'-'..endStr)

        if (not isSingleIndex and not isRange) then
            abort("Invalid index selection specification to argument '-s'.")
        elseif (not (startIndex >= 1 and startIndex <= #compileCommands) or
                not (endIndex >= 1 and endIndex <= #compileCommands)) then
            abort("Compile command index for option '-s' out of range [1, %d]", #compileCommands)
        end

        for i = startIndex, endIndex do
            selectCompileCommand(i)
        end

        if (#newCompileCommands == 0) then
            infoAndExit("Selected empty range.")
        end
    elseif (haveFileSelection) then
        if (selectionSpec:sub(-1) ~= '}') then
            abort("Invalid pattern selection specification to argument '-s'.")
        end

        local pattern = selectionSpec:sub(2,-2)

        do
            local ok, msg = pcall(function() return pattern:match(pattern) end)
            if (not ok) then
                abort("Invalid pattern to argument '-s': %s.", msg)
            end
        end

        for i, cmd in ipairs(compileCommands) do
            if (cmd.file:match(pattern)) then
                selectCompileCommand(i)
            end
        end
    else
        local suffix = selectionSpec
        for i, cmd in ipairs(compileCommands) do
            if (#cmd.file >= #suffix and cmd.file:sub(-#suffix) == suffix) then
                selectCompileCommand(i)
            end
        end
    end

    if (#newCompileCommands == 0) then
        infoAndExit("Found no compile commands matching selection specification.")
    end

    compileCommands = newCompileCommands
end

local usedConcurrency = math.min(getUsedConcurrency(), #compileCommands)

if (autoPch ~= nil) then
    -- First, determine which PCH configurations to use.

    local countThreshold =
        usedConcurrency >= 16 and usedConcurrency or
        -- lower bound: we do not want too many PCH configurations on disk.
        8 + math.floor(usedConcurrency / 2)

    local unsupportedCount = 0
    -- { [0] = <unique count>, [<PCH file basename>] = <count> }
    local pchFileCounts = { [0] = 0 }
    -- { [<running index>] = { <PCH args...> } }
    local usedPchArgs = {}
    -- { [<PCH file basename>] = true }
    local isPchFileUsed = {}
    -- { [CC index] = <index into usedPchArgs> }
    local ccUsedPchIdxs = {}

    for _, cmd in ipairs(compileCommands) do
        local pchArgs = cmd.pchArguments
        local canHavePch = (type(pchArgs) == "table")
        assert(canHavePch or type(pchArgs) == "string")

        if (not canHavePch) then
            assert(pchArgs == "unsupported language")
            unsupportedCount = unsupportedCount + 1
        else
            local fn = pchArgs[#pchArgs]
            local oldCount = pchFileCounts[fn]
            pchFileCounts[0] = pchFileCounts[0] + ((oldCount == nil) and 1 or 0)
            pchFileCounts[fn] = (oldCount ~= nil) and oldCount + 1 or 1

            -- Deliberate: if the *new* count is *one greater* than the threshold,
            -- use the PCH configuration.
            if (oldCount == countThreshold) then
                usedPchArgs[#usedPchArgs + 1] = pchArgs
                isPchFileUsed[fn] = true
            end
        end
    end

    if (pchFileCounts[0] == 0) then
        info("Auto-PCH: no supported compile commands.")
        assert(#usedPchArgs == 0)
    else
        local suffix = unsupportedCount > 0 and
            format(", %s", pluralize(unsupportedCount, "unsupported compile command")) or ""

        info("Auto-PCH: %s of %d in total%s.",
             #usedPchArgs > 0 and pluralize(#usedPchArgs, "used configuration") or
                 "no configurations used",
             pchFileCounts[0], suffix)
    end

    if (#usedPchArgs == 0) then
        goto end_pch
    end

    -- Attach the PCH file name to compile commands that are going to be PCH-enabled.

    local pchDir = PchCacheDirectory
    local pchEnabledCcCount = 0

    for i, cmd in ipairs(compileCommands) do
        local pchArgs = cmd.pchArguments
        assert(cmd.pchFileName == nil)

        if (type(pchArgs) == "table") then
            local fn = pchArgs[#pchArgs]
            if (isPchFileUsed[fn]) then
                cmd.pchFileName = pchDir..'/'..fn
                pchEnabledCcCount = pchEnabledCcCount + 1
            end
        end
    end

    assert(pchEnabledCcCount > 0)
    info("Auto-PCH: enabled %d compile commands.", pchEnabledCcCount)

    -- Preparation

    if (os.execute("/bin/mkdir -p "..pchDir) ~= 0) then
        abort("Failed creating directory for PCH files "..pchDir)
    end

    local getPchInputFiles = function()
        local luaPath = getEnv("LUA_PATH", "Lua path")
        -- KEEPINSYNC with app.sh.in
        local ljclangDir = luaPath:match(";;(.*)/%?%.lua")
        if (ljclangDir == nil) then
            abort("Failed to obtain LJClang directory from Lua path.")
        end

        return ljclangDir.."/dev/cxx_headers.hpp", ljclangDir.."/dev/empty.cpp"
    end

    local cxxHeadersHpp, emptyCpp = getPchInputFiles()
    local clangpp = getEnv("LLVM_BINDIR", "LLVM binary directory").."/clang++"

    -- Functions

    local generatePch = function(pchArgs)
        local cmdArgs = { clangpp }

        for _, arg in ipairs(pchArgs) do
            -- os.execute uses the shell, restrict characters. We do not want quotes or
            -- spaces, nor any character that could have a special meaning to the shell.
            -- FIXME: this is too strict. Think about a better way, or use fork & exec.
            if (arg:match("[^-+~A-Za-z_0-9=.]")) then
                errorInfo("Auto-PCH: generation command argument\
  %s\
contains a disallowed character.", arg)
                exitRequestingBugReport()
            end
            cmdArgs[#cmdArgs + 1] = arg
        end

        local fullPchFileName = pchArgs.pchFileName
        cmdArgs[#cmdArgs] = fullPchFileName
        cmdArgs[#cmdArgs + 1] = cxxHeadersHpp
        cmdArgs[#cmdArgs + 1] = "2>/dev/null"

        local cmd = table.concat(cmdArgs, ' ')

        -- NOTE: we could parallelize, but that does not seem worth the effort since one
        -- PCH file is generated once and used from then on until it is invalidated for
        -- some reason (like an update to standard library headers).
        local ret = os.execute(cmd)

        if (ret ~= 0) then
            errorInfo("Auto-PCH: exited with code %d: %s", ret, cmd)
            exitRequestingBugReport()
        end

        if (not exists(fullPchFileName)) then
            errorInfo("Auto-PCH: PCH file to be generated\
  %s\
does not exist even though the command to generate it ran successfully.", fullPchFileName)
            exitRequestingBugReport()
        end
    end

    -- Attempts to compile an empty file with the given PCH configuration.
    local testPch = function(pchArgs)
        local cmdArgs = { clangpp, "-fsyntax-only", "-include-pch", pchArgs.pchFileName }

        -- Convention of compile_commands_util's getPchGenData():
        assert(pchArgs[#pchArgs - 1] == "-o")

        for i = 1, #pchArgs - 2 do
            cmdArgs[#cmdArgs + 1] = pchArgs[i]
        end

        cmdArgs[#cmdArgs + 1] = emptyCpp
        cmdArgs[#cmdArgs + 1] = "2>/dev/null"

        return (os.execute(table.concat(cmdArgs, ' ')) == 0)
    end

    -- PCH file generation loop.

    local genCount, regenCount = 0, 0

    for _, pchArgs in ipairs(usedPchArgs) do
        local fn = pchDir..'/'..pchArgs[#pchArgs]
        pchArgs.pchFileName = fn

        if (not exists(fn)) then
            generatePch(pchArgs)
            genCount = genCount + 1
        end

        -- Test usage once. If not successful, the PCH is most likely out of date and needs
        -- to be regenerated.
        local ok = testPch(pchArgs)

        if (not ok) then
            generatePch(pchArgs)
            regenCount = regenCount + 1

            if (not testPch(pchArgs)) then
                errorInfo("Auto-PCH: regenerated PCH file\
  %s\
did not successfully pass test usage with an empty C++ source file.", fn)
                exitRequestingBugReport()
            end
        end
    end

    if (genCount == 0 and regenCount == 0) then
        info("Auto-PCH: all existing PCH files are up to date.")
    else
        info("Auto-PCH: generated %s%s.",
             pluralize(genCount, "PCH file"),
             regenCount > 0 and format(", regenerated %d", regenCount) or "")
    end

::end_pch::
end

-----

local function getCompileCommandFileCounts()
    local counts = {}
    for _, cmd in ipairs(compileCommands) do
        counts[cmd.file] = (counts[cmd.file] ~= nil) and counts[cmd.file] + 1 or 1
    end
    return counts
end

local ccFileCounts = getCompileCommandFileCounts()

local function getFileOrdinal(ccIndex)
    local fileName = compileCommands[ccIndex].file
    assert(ccFileCounts[fileName] ~= nil)

    local ord = 0

    for i = 1, ccIndex do
        if (compileCommands[i].file == fileName) then
            ord = ord + 1
        end
    end

    return ord
end

---------- Common to both human and command mode ----------

local function getSite(location)
    -- Assert that the different location:*Site() functions return the same site (which
    -- means that the location does not refer into a macro instantiation or expansion) and
    -- return it.
    local expansionSite, expansionLco = location:expansionSite()
    local spellingSite, spellingLco = location:spellingSite()
    local fileSite, fileLco = location:fileSite()

    assert(fileSite == expansionSite)
    assert(fileLco == expansionLco)
    assert(fileSite == spellingSite)
    assert(fileLco == spellingLco)

    return fileSite
end

local function checkAndGetRealName(file)
    local realName = file:realPathName()

    if (realName == nil) then
        errprintf("ERROR: Could not obtain the real path name of '%s'", file:name())
        os.exit(ErrorCode.RealPathName)
    end

    return realName
end

local function InclusionGraph_ProcessTU(graph, tu)
    local callback = function(includedFile, stack)
        if (#stack == 0) then
            return
        end

        -- Can happen if "-include" was passed to Clang:
        local isFromPredefinesBuffer = (#stack == 1 and not stack[1]:isFromMainFile())

        if (isFromPredefinesBuffer) then
            -- TODO: handle?
            -- The way it is now, if the (precompiled) header from "-include ..." is a user
            -- header, we lose files in the include graph.
            return
        end

        local fromFile = getSite(stack[1])

        -- Check that all names we get passed are absolute.
        -- This should be the case because compile_commands_reader absifies names for us.
        assert(includedFile:name():sub(1,1) == "/")
        assert(fromFile:name():sub(1,1) == "/")
        -- Check sanity: system headers never include user files.
        assert(not (stack[1]:isInSystemHeader() and not includedFile:isSystemHeader()))

        if (not includedFile:isSystemHeader()) then
            local fromRealName = checkAndGetRealName(fromFile)
            local toRealName = checkAndGetRealName(includedFile)

            -- NOTE: graph is constructed with edges going
            --  from the file being '#include'd
            --  to the file containing the '#include'd
            -- That is, it models the "isIncludedBy" relation.
            -- KEEPINSYNC 'GlobalInclusionGraphRelation'.
            graph:addInclusion(toRealName, fromRealName)
        end
    end

    tu:inclusions(callback)
    return graph
end

local MOVE_OR_DELETE = bit.bor(IN.MOVE_SELF, IN.DELETE_SELF)
local WATCH_FLAGS = bit.bor(IN.CLOSE_WRITE, MOVE_OR_DELETE)

---------- HUMAN MODE ----------

local function DoProcessCompileCommand(cmd, additionalSystemInclude, parseOptions)
    local fileExists, msg = exists(cmd.file)
    if (not fileExists) then
        return nil, msg
    end

    local args = {}

    for i, arg in ipairs(cmd.arguments) do
        args[i] = arg
    end

    -- TODO: catch a possible error at this stage.
    if (cmd.pchFileName ~= nil) then
        table.insert(args, 1, "-include-pch")
        table.insert(args, 2, cmd.pchFileName)
    end

    if (additionalSystemInclude ~= nil) then
        table.insert(args, 1, "-isystem")
        table.insert(args, 2, additionalSystemInclude)
    end

    local index = cl.createIndex(true, false)
    return index:parse("", args, parseOptions)
end

local function info_underline(fmt, ...)
    local text = format(fmt, ...)
    local func = printGraphMode and errprintf or printf
    func("%s%s",
         colorize("INFO", Col.Uline..Col.Green),
         colorize(": "..text, Col.Uline..Col.White))
end

local function tryGetLanguage(cmd)
    -- Minimalistic, since only needed for a hack.

    if (cmd.file:sub(-2) == ".c") then
        return "c"
    end

    for _, arg in ipairs(cmd.arguments) do
        if (arg:sub(1,8) == "-std=c++") then
            return "c++"
        end
    end
end

local function ShouldEnableHack(diagsStr)
    local fileName = diagsStr:match("fatal error: '(.*)' file not found")

    -- NOTE: Ideally, we want to match system headers here (though: more insight needed into
    -- which exactly may fail), but enumerating them seems undesirable. Plus, the matching
    -- here should be relatively specific so as not to enable the hack when a non-system
    -- header failed being included. (This can happen if the build system generates files
    -- with C or C++ code, for example.)
    return fileName ~= nil and
        (fileName:match("^std[a-z]+%.h$") -- Attempt to match failing C headers.
      or fileName:match("^[a-z_]+$"))     -- Attempt to match failing C++ headers.
end

local function CheckForIncludeError(tu, formattedDiagSet, cmd, additionalIncludeTab)
    if (additionalIncludeTab[1] ~= nil) then
        return
    end

    local plainFormattedDiags = formattedDiagSet:getString(false)
    local enableHack = ShouldEnableHack(plainFormattedDiags)
    assert(not enableHack or (tu ~= nil))

    if (enableHack) then
        -- HACK so that certain system includes are found.
        local language = tryGetLanguage(cmd)

        if (language == "c" or language == "c++") then
            hacks.addSystemInclude(additionalIncludeTab, language)
        else
            -- Bail out. TODO: do not.
            errprintf("INTERNAL ERROR: don't know how to attempt fixing includes"..
                      " for language that was not determined automatically")
            os.exit(ErrorCode.Internal)
        end

        return true
    end
end

local function ProcessCompileCommand(ccIndex, parseOptions)
    local tu, errorCodeOrString
    local additionalIncludeTab = {}
    local count = 0

    local formattedDiagSet
    local hadSomeSystemIncludesAdded = false

    repeat
        count = count + 1
        assert(count <= 2)

        tu, errorCodeOrString = DoProcessCompileCommand(
            compileCommands[ccIndex], additionalIncludeTab[2], parseOptions)

        if (tu == nil) then
            formattedDiagSet = diagnostics_util.FormattedDiagSet(not plainMode)
            -- TODO: Extend in verbosity and/or handling?
            local info = format("%s: index:parse() failed: %s",
                                colorize("ERROR", Col.Bold..Col.Red),
                                errorCodeOrString)
            formattedDiagSet:setInfo(info)
        else
            formattedDiagSet = diagnostics_util.GetDiags(
                tu:diagnosticSet(), not plainMode, printAllDiags)
        end

        local retry = CheckForIncludeError(
            tu, formattedDiagSet, compileCommands[ccIndex], additionalIncludeTab)
        hadSomeSystemIncludesAdded = hadSomeSystemIncludesAdded or retry
    until (not retry)

    local inclusionGraph = (tu ~= nil) and
        InclusionGraph_ProcessTU(InclusionGraph(), tu) or
        InclusionGraph()

    -- Make LuaJIT release libclang-allocated TU memory.
    tu = nil
    collectgarbage()

    assert(formattedDiagSet ~= nil and inclusionGraph ~= nil)
    return formattedDiagSet, inclusionGraph, hadSomeSystemIncludesAdded
end

local OnDemandParser = class
{
    function(ccIndexes, parseOptions)
        checktype(ccIndexes, 1, "table", 2)
        checktype(parseOptions, 1, "table", 2)

        return {
            ccIndexes = ccIndexes,
            parseOptions = parseOptions,

            formattedDiagSets = {},
            inclusionGraphs = {},
            hadSomeSystemIncludesAdded = false,
        }
    end,

    getCount = function(self)
        return #self.ccIndexes
    end,

    getResults = function(self, i)
        checktype(i, 1, "number", 2)
        check(i >= 1 and i <= self:getCount(), "argument #1 must be in [1, self:getCount()]", 2)

        local tus, errorCodes = self.tus, self.errorCodes

        if (self.formattedDiagSets[i] == nil) then
            local tmp
            self.formattedDiagSets[i], self.inclusionGraphs[i], tmp =
                ProcessCompileCommand(self.ccIndexes[i], self.parseOptions)
            self.hadSomeSystemIncludesAdded = self.hadSomeSystemIncludesAdded or tmp
        end

        return self.formattedDiagSets[i], self.inclusionGraphs[i]
    end,

    iterate = function(self)
        local next = function(_, i)
            i = i+1
            if (i <= self:getCount()) then
                -- NOTE: four return values.
                return i, self.ccIndexes[i], self:getResults(i)
            end
        end

        return next, nil, 0
    end,

    getAdditionalInfo = function(self)
        if (self.hadSomeSystemIncludesAdded) then
            return "For some compile commands, system include directories were automatically added."
        end
    end,
}

local function PrintInclusionGraphAsGraphvizDot(graph)
    local directoryName = compileCommands[1].file:match("^.*/")

    -- Obtain the common prefix of all files named by any compile command and strip that
    -- prefix from the node labels.
    local commonPrefix = util.getCommonPrefix(function (_, cmd) return cmd.file end,
                                              directoryName, ipairs(compileCommands))
    if (commonPrefix == "/") then
        commonPrefix = ""
    end

    local titleSuffix = (commonPrefix == "") and "" or format(" under '%s'", commonPrefix)
    local title = format("Inclusions (%s) for '%s'%s",
                         printGraphMode, compileCommandsFile, titleSuffix)
    local reverse = (printGraphMode ~= GlobalInclusionGraphRelation)
    graph:printAsGraphvizDot(title, reverse, commonPrefix, edgeCountLimit, printf)
end

local function GetNewCcIndexes(ccInclusionGraphs, eventFileName,
                               processedCommandCount, oldCcIdxs)
    assert(#ccInclusionGraphs <= #compileCommands)
    assert(processedCommandCount <= #oldCcIdxs)

    local indexes = {}

    -- 1. compile commands affected by the file on which we had a watch event.
    for ccIdx = 1, #ccInclusionGraphs do
        if (ccInclusionGraphs[ccIdx]:getNode(eventFileName) ~= nil) then
            indexes[#indexes + 1] = ccIdx
        end
    end

    -- 2. compile commands left over if we stopped early in incremental mode.
    --  (Also see NOTE STOPPED_EARLY.)
    if (processedCommandCount < #oldCcIdxs) then
        for i = processedCommandCount, #oldCcIdxs do
            indexes[#indexes + 1] = oldCcIdxs[i]
        end
    end

    -- Now, sort+uniquify the two compile command index sequences, for the assert in checkCcIdxs_().
    -- Violation can only happen if we stopped early on a re-process that was due to an early stop.
    -- (Because we get the same compile command twice -- once from 1. and once from 2.)

    table.sort(indexes)

    local newIndexes = {}

    for i, ccIdx in ipairs(indexes) do
        if (newIndexes[#newIndexes] ~= ccIdx) then
            newIndexes[#newIndexes + 1] = ccIdx
        end
    end

    return newIndexes, #oldCcIdxs - processedCommandCount
end

local function range(n)
    local t = {}
    for i = 1, n do
        t[i] = i
    end
    return t
end

local function getFileOrdinalText(cmd, i)
    local fileCount = ccFileCounts[cmd.file]
    local ord = (fileCount > 1) and getFileOrdinal(i) or nil
    return (ord ~= nil)
        and colorize(format("[%d/%d] ", ord, fileCount),
                     Col.Bold..Col.Yellow)
        or ""
end

local function getNormalizedDiag(diagStr)
    -- TODO: inform user about the number of different sites that the diagnostics came from.
    return diagStr:gsub("In file included from [^\n]*\n", "")
end

local function getSeverityString(count, severity, color)
    return count > 0 and pluralize(count, severity, 's', Col.Bold..color) or nil
end

local SeverityCounts = class
{
    function()
        return {
            fatals = 0,
            errors = 0,
            warnings = 0,
            others = 0,
        }
    end,

    increment = function(self, severity)
        assert(self[severity] ~= nil)
        self[severity] = self[severity] + 1
    end,

    add = function(self, other)
        self.fatals = self.fatals + other.fatals
        self.errors = self.errors + other.errors
        self.warnings = self.warnings + other.warnings
        self.others = self.others + other.others
    end,

    getTotal = function(self)
        return self.fatals + self.errors + self.warnings + self.others
    end,

    getString = function(self)
        local tab = {}
        tab[#tab + 1] = getSeverityString(self.fatals, "fatal error", Col.Red)
        tab[#tab + 1] = getSeverityString(self.errors, "error", Col.Red)
        tab[#tab + 1] = getSeverityString(self.warnings, "warning", Col.Purple)
        tab[#tab + 1] = getSeverityString(self.others, "other", Col.Black)
        return table.concat(tab, ", ")
    end,
}

local FormattedDiagSetPrinter = class
{
    function()
        return {
            seenDiags = {},
            numCommandsWithOmittedDiags = 0,
            totalOmittedDiagCounts = SeverityCounts(),
            lastProgressPrintTime = os.time(),
            lastProgressPrintCcIndex = 0,
        }
    end,

    getStringsToPrint_ = function(self, formattedDiagSet)
        local toPrint = {
            omittedDiagCounts = SeverityCounts()
        }

        if (formattedDiagSet:isEmpty()) then
            return toPrint, false
        end

        local newSeenDiags = {}
        local omittedLastDiag = false

        local fDiags = formattedDiagSet:getDiags()

        local IsErrorSeverity = { fatal=true, error=true }
        local IsTrackedSeverity = { fatal=true, error=true, warning=true }

        for i, fDiag in ipairs(fDiags) do
            local str = fDiag:getString(true)
            local normStr = getNormalizedDiag(str)

            if (printAllDiags or not self.seenDiags[normStr]) then
                newSeenDiags[#newSeenDiags + 1] = normStr
                toPrint[#toPrint+1] = format("%s%s", (i == 1) and "" or "\n", str)
            else
                local severity = fDiag:getSeverity()
                local severityTag = IsTrackedSeverity[severity]
                    and severity..'s'
                    or "others"

                toPrint.omittedDiagCounts:increment(severityTag)
                omittedLastDiag = (i == #fDiags)
            end
        end

        for _, newSeenDiag in ipairs(newSeenDiags) do
            self.seenDiags[newSeenDiag] = true
        end

        local info = formattedDiagSet:getInfo()
        if (info ~= nil and not omittedLastDiag) then
            toPrint[#toPrint+1] = format("%s", info:getString(true))
        end

        return toPrint
    end,

    print = function(self, formattedDiagSet, ccIndex)
        local toPrint = self:getStringsToPrint_(formattedDiagSet)
        local pSecs, pCount = printProgressAfterSeconds, printProgressAfterCcCount

        local shouldPrint = (#toPrint > 0) or
            pSecs ~= nil and os.difftime(os.time(), self.lastProgressPrintTime) >= pSecs or
            pCount ~= nil and ccIndex - self.lastProgressPrintCcIndex >= pCount

        if (shouldPrint) then
            local cmd = compileCommands[ccIndex]
            local originalCcIndex = compileCommandSelection[ccIndex] or ccIndex

            local prefix = format("Command %s%d:",
                                  haveFileSelection and "s" or "#",
                                  haveFileSelection and ccIndex or originalCcIndex)
            local middle = getFileOrdinalText(cmd, ccIndex)
            local suffix = (#toPrint > 0) and "" or " ["..colorize("progress", Col.Green).."]"

            errprintf("%s %s%s%s",
                      colorize(prefix, Col.Bold..Col.Uline..Col.Green),
                      middle,
                      colorize(cmd.file, Col.Bold..Col.Green),
                      suffix)

            if (#toPrint > 0) then
                errprintf("%s\n", table.concat(toPrint, '\n'))
            end

            self.lastProgressPrintTime = os.time()
            self.lastProgressPrintCcIndex = ccIndex
        end

        if (toPrint.omittedDiagCounts:getTotal() > 0) then
            self.numCommandsWithOmittedDiags = self.numCommandsWithOmittedDiags + 1
            self.totalOmittedDiagCounts:add(toPrint.omittedDiagCounts)
        end
    end,

    printTrailingInfo = function(self)
        if (self.numCommandsWithOmittedDiags > 0) then
            errprintf(
                "%s: from %s, omitted %s: %s.", NOTE,
                pluralize(self.numCommandsWithOmittedDiags, "compile command"),
                pluralize(self.totalOmittedDiagCounts:getTotal(), "repeated diagnostic"),
                self.totalOmittedDiagCounts:getString())
        end
    end,
}

local Connection = class
{
    function(readFd, writeFd, childPid, extraFd)
        return {
            r = readFd,
            w = writeFd,

            childPid = childPid,
            _extra = extraFd,
        }
    end,
}

local PipePair = class
{
    function()
        return {
            toParent = posix.pipe(),
            toChild = posix.pipe(),
        }
    end,

    getConnection = function(self, whoami, childPid)
        assert(whoami == "child" or whoami == "parent")
        assert((whoami == "parent") == (childPid ~= nil))

        if (whoami == "child") then
            self.toParent.r:close()
            self.toChild.w:close()
            return Connection(self.toChild.r, self.toParent.w)
        else
            -- NOTE: deliberately keep open the write end of the 'child -> parent'
            -- connection in the parent so that we never get POLL.HUP from poll().
            --[[self.toParent.w:close()--]]
            self.toChild.r:close()
            return Connection(self.toParent.r, self.toChild.w,
                          childPid, self.toParent.w)
        end
    end,
}

local DoneHeader_t = class
{
    "char magic[4];"..
    "uint32_t diagsStrLength;"..
    "uint32_t graphStrLength;",

    __new = function(ct, length1, length2)
        -- NOTE: 'magic' deliberately not zero-terminated. See
        -- http://lua-users.org/lists/lua-l/2011-01/msg01457.html
        return ffi.new(ct, "Done", length1, length2)
    end,

    deserialize = function(self)
        return {
            magic = ffi.string(self.magic, 4),
            diagsStrLength = tonumber(self.diagsStrLength),
            graphStrLength = tonumber(self.graphStrLength),
        }
    end,
}

local ChildMarker = {
    isChild = function()
        return true
    end,
}

local ParentMarker = {
    isChild = function()
        return false
    end,
}

-- Monitors all files that directly named by any compile command or reached by #include,
-- as well as the compile_commands.json file itself.
local Notifier = class
{
    function()
        local inotifier = inotify.init()
        local compileCommandsWd = inotifier:add_watch(compileCommandsFile, WATCH_FLAGS)

        return {
            inotifier = inotifier,
            fileNameWdMap = util.Bimap("string", "number"),
            compileCommandsWd = compileCommandsWd,
        }
    end,

    addFilesFromGraph = function(self, inclusionGraph)
        for _, filename in inclusionGraph:iFileNames() do
            if (self.fileNameWdMap[filename] == nil) then
                local wd = self.inotifier:add_watch(filename, WATCH_FLAGS)

                -- Assert one-to-oneness. (Should be the case due to us having passed the file names
                -- through realPathName() earlier.)
                --
                -- TODO: this does not need to hold in the presence of hard links though. Test.
                assert(self.fileNameWdMap[wd] == nil)

                util.BimapAdd(self.fileNameWdMap, filename, wd)
            end
        end
    end,

    getWatchedFileCount = function(self)
        return util.BimapGetCount(self.fileNameWdMap) + 1
    end,

    getFileName = function(self, event)
        local filename = self.fileNameWdMap[event.wd]
        assert(filename ~= nil)
        return filename
    end,

    getRawFd = function(self)
        return self.inotifier:getRawFd()
    end,

    check_ = function(self, printfFunc)
        assert(self.inotifier ~= nil)
        local event = self.inotifier:check_(printfFunc)
        return self:checkEvent_(event)
    end,

    close = function(self)
        self.inotifier:close()
        self.inotifier = nil
    end,

    checkEvent_ = function(self, event)
        if (bit.band(event.mask, MOVE_OR_DELETE) ~= 0) then
            errprintf("Exiting: a watched file was moved or deleted. (Handling not implemented.)")
            os.exit(ErrorCode.WatchedFileMovedOrDeleted)
        end

        if (event.wd == self.compileCommandsWd) then
            errprintf("Exiting: an event was generated for '%s'. (Handling not implemented.)",
                      compileCommandsFile)
            os.exit(ErrorCode.CompileCommandsJsonGeneratedEvent)
        end

        return event
    end,
}

local function HasMatchingDiag(fDiagSet, isSeverityRelevant)
    for _, fDiag in ipairs(fDiagSet:getDiags()) do
        if (isSeverityRelevant[fDiag:getSeverity()]) then
            return true
        end
    end
end

local INOTIFY_FD_MARKER = -math.huge

local Controller = class
{
    function(...)
        return {
            onDemandParserArgs = { ... },

            -- If concurrency is requested, will be 'child' or 'parent' after forking:
            whoami = "unforked",

            -- Will be closed and nil'd in child.
            notifier = Notifier(),

            -- Child or unforked will have:
            parser = nil,  -- OnDemandParser
            printer = nil,  -- FormattedDiagSetPrinter

            -- Child will have:
            connection = nil,  -- Connection

            --== Parent will have:
            -- Table of Connection elements with possible holes. Indexed by the 'connection index'.
            connections = nil,
            -- Table (read file descriptor -> index into self.connections[]).
            readFdToConnIdx = nil,
            -- Contiguous sequence table as argument to posix.poll().
            pendingFds = nil,
        }
    end,

    is = function(self, who)
        return (self.whoami == who)
    end,

    --== Child only ==--

    send = function(self, obj)
        return self.connection.w:write(obj)
    end,

    receive = function(self)
        local str = self.connection.r:read(1)
        -- NOTE: (quoting from POSIX):
        --  "If no process has the pipe open for writing, read() shall return 0 to indicate
        --  end-of-file."
        assert(#str == 1)
        return str
    end,

    sendToParent = function(self, fDiagSet, incGraph)
        local fDiagsStr = fDiagSet:serialize()
        local graphStr = incGraph:serialize()
        local header = DoneHeader_t(#fDiagsStr, #graphStr)
        self:send(header)
        self:send(fDiagsStr)
        self:send(graphStr)
    end,

    --== Unforked or parent ==--

    setupParserAndPrinter = function(self, ...)
        self.parser = OnDemandParser(...)
        self.printer = FormattedDiagSetPrinter()
    end,

    getAdditionalInfo = function(self)
        if (self:is("unforked")) then
            return self.parser:getAdditionalInfo()
        end
    end,

    getNotifier = function(self)
        return self.notifier
    end,

    checkCcIdxs_ = function(self, ccIdxs)
        -- Assert strict monotonicity requirement.
        for i = 2, #ccIdxs do
            assert(ccIdxs[i - 1] < ccIdxs[i])
        end
        return ccIdxs
    end,

    getCcIdxs = function(self)
        return self:checkCcIdxs_(self.onDemandParserArgs[1])
    end,

    --== Parent only ==--

    sendTo = function(self, connIdx, str)
        assert(#str == 1)
        local conn = self.connections[connIdx]
        return conn.w:write(str)
    end,

    receiveString = function(self, connIdx, length)
        local conn = self.connections[connIdx]
        local str = conn.r:read(length)
        assert(#str == length)
        return str
    end,

    receiveData = function(self, connIdx, cdata)
        local conn = self.connections[connIdx]
        return conn.r:readInto(cdata)
    end,

    closeConnection = function(self, connIdx)
        local conn = self.connections[connIdx]
        local ccIdx = conn.compileCommandIndex
        local readFd = conn.r.fd

        conn.r:close()
        conn.w:close()
        assert(conn._extra ~= nil)
        conn._extra:close()

        assert(self.readFdToConnIdx[readFd] == connIdx)
        self.readFdToConnIdx[readFd] = nil

        posix.waitpid(conn.childPid, 0)

        self.connections[connIdx] = nil

        -- Remove entry from self.pendingFds[].
        local removed = false

        for i, eventFd in ipairs(self.pendingFds) do
            if (eventFd == readFd) then
                assert(not removed)
                table.remove(self.pendingFds, i)
                removed = true
            end
        end

        assert(removed)
        return ccIdx
    end,

    haveActiveChildren = function(self)
        return (#self.pendingFds > 0)
    end,

    spawnChild = function(self, ccIdx)
        assert(not self:is("child"))

        local pipes = PipePair()

        local whoami, childPid = posix.fork()
        self.whoami = whoami

        local connection = pipes:getConnection(whoami, childPid)

        if (self:is("child")) then
            self.connection = connection
            self.notifier:close()
            self.notifier = nil
            self:setupParserAndPrinter({ccIdx}, unpack(self.onDemandParserArgs, 2))
            return ChildMarker
        end

        -- Set up and/or update the child-tracking state in the parent.

        connection.compileCommandIndex = ccIdx

        local connections = self.connections or {}
        local connIdx = #connections + 1
        connections[connIdx] = connection
        self.connections = connections

        local readFdToConnIdx = self.readFdToConnIdx or {}
        local readFd = connection.r.fd
        assert(readFdToConnIdx[readFd] == nil)
        readFdToConnIdx[readFd] = connIdx
        self.readFdToConnIdx = readFdToConnIdx

        local pendingFds = self.pendingFds or { events=POLL.IN }
        pendingFds[#pendingFds + 1] = readFd
        self.pendingFds = pendingFds

        return ParentMarker
    end,

    -- TODO: watch inotify descriptor, too.
    wait = function(self)
        assert(self:is("parent"))

        local inotifyFd = self.notifier:getRawFd()
        self.pendingFds[#self.pendingFds + 1] = inotifyFd
        local pollfds = posix.poll(self.pendingFds)
        self.pendingFds[#self.pendingFds] = nil

        local connIdxs = {}
        local haveInotifyFd = false

        for i = 1, #pollfds do
            -- We should never get:
            --  - POLL.HUP: we (the parent) keep the write end of the 'child -> parent'
            --      connection open just so that the pipe is always connected.
            --  - POLL.NVAL: we should always valid pipe file descriptors to poll().
            --
            -- TODO: deal with possible POLL.ERR?
            assert(pollfds[i].revents == POLL.IN)

            local fd = pollfds[i].fd
            local connIdx = (fd == inotifyFd) and INOTIFY_FD_MARKER or self.readFdToConnIdx[fd]
            assert(connIdx ~= nil)

            haveInotifyFd = haveInotifyFd or (fd == inotifyFd)
            connIdxs[i] = connIdx
        end

        return connIdxs, haveInotifyFd
    end,

    --== Unforked only ==--

    setupConcurrency = function(self, ccInclusionGraphs)
        local ccIdxs = self:getCcIdxs()
        local localConcurrency = math.min(usedConcurrency, #ccIdxs)
        local spawnCount = 0

        -- Spawn the initial batch of children.
        for ii = 1, localConcurrency do
            spawnCount = spawnCount + 1
            if (self:spawnChild(ccIdxs[ii]):isChild()) then
                return ChildMarker, 0
            end
        end

        assert(self.printer == nil)
        self.printer = FormattedDiagSetPrinter()

        local ii = localConcurrency + 1

        local firstUnprocessedIdx = 1
        local formattedDiagSets = {}
        local lastCcIdxToPrint = math.huge
        local hadInotifyFd = false

        repeat
            local connIdxs, haveInotifyFd = self:wait()
            local spawnNewChildren = not haveInotifyFd and (lastCcIdxToPrint == math.huge)
            local newChildCount = #connIdxs

            hadInotifyFd = hadInotifyFd or haveInotifyFd

            -- To retain the requested concurrency, spawn as many new children as we were
            -- informed are ready.
            while (spawnNewChildren and newChildCount > 0 and ii <= #ccIdxs) do
                spawnCount = spawnCount + 1
                if (self:spawnChild(ccIdxs[ii]):isChild()) then
                    return ChildMarker, 0
                end

                newChildCount = newChildCount - 1
                ii = ii + 1
            end

            -- Now, for each ready child in turn, first inform it that it can go ahead
            -- printing and then wait for it to complete that.
            for _, connIdx in ipairs(connIdxs) do
                if (connIdx == INOTIFY_FD_MARKER) then
                    -- If any watched file has been modified, stop printing.
                    -- Continue handling the outstanding connections, though.
                    lastCcIdxToPrint = 0
                    goto nextIteration
                end

                local doneMsg = self:receiveData(connIdx, DoneHeader_t(0, 0)):deserialize()
                assert(doneMsg.magic == "Done")

                local serializedDiags = self:receiveString(connIdx, doneMsg.diagsStrLength)
                local serializedGraph = self:receiveString(connIdx, doneMsg.graphStrLength)

                -- NOTE: may introduce holes in the (integer) key sequence of
                -- self.connections[].
                local ccIdx = self:closeConnection(connIdx)

                formattedDiagSets[ccIdx] = diagnostics_util.FormattedDiagSet_Deserialize(
                    serializedDiags, not plainMode)
                ccInclusionGraphs[ccIdx] = inclusion_graph.Deserialize(serializedGraph)

                if (incrementalMode ~= nil) then
                    if (HasMatchingDiag(formattedDiagSets[ccIdx], incrementalMode)) then
                        -- We are in incremental mode and have detected a diagnostic severity
                        -- for which the user wants us to stop. So:
                        --
                        --  1. Do not spawn any more new children.
                        --  2. But, do handle the ones currently in flight.
                        --
                        -- NOTE: requires strictly monotonic ascending 'ccIdxs' (asserted
                        -- above) for sane functioning.
                        lastCcIdxToPrint = math.min(lastCcIdxToPrint, ccIdx)
                    end
                end

                ::nextIteration::
            end

            -- Print diagnostic sets in compile command order.
            -- TODO: for command mode (where we might want to get results as soon as they
            --  arrive), make this an option?
            for idx = firstUnprocessedIdx, #ccIdxs do
                local ccIdx = ccIdxs[idx]
                local fDiagSet = formattedDiagSets[ccIdx]
                formattedDiagSets[ccIdx] = nil

                if (fDiagSet == nil) then
                    break
                elseif (ccIdx <= lastCcIdxToPrint) then
                    self.notifier:addFilesFromGraph(ccInclusionGraphs[ccIdx])
                    self.printer:print(fDiagSet, ccIdx)
                    firstUnprocessedIdx = firstUnprocessedIdx + 1
                end
            end
        until (not self:haveActiveChildren())

        self.printer:printTrailingInfo()

        local earlyStopReason = hadInotifyFd or incrementalMode
        assert(not earlyStopReason and spawnCount == #ccIdxs or
                   earlyStopReason and spawnCount <= #ccIdxs)

        return ParentMarker, firstUnprocessedIdx - 1
    end,

    printDiagnostics = function(self, ccInclusionGraphs)
        if (usedConcurrency == 0) then
            self:setupParserAndPrinter(unpack(self.onDemandParserArgs))
        else
            local marker, processedCcCount = self:setupConcurrency(ccInclusionGraphs)
            if (not marker:isChild()) then
                return processedCcCount
            end
        end

        local iterationCount = 0

        for i, ccIndex, fDiagSet, incGraph in self.parser:iterate() do
            iterationCount = iterationCount + 1
            assert((i == 1) == (iterationCount == 1))

            if (self:is("child")) then
                self:sendToParent(fDiagSet, incGraph)
            else
                ccInclusionGraphs[ccIndex] = incGraph
                self.notifier:addFilesFromGraph(incGraph)
                self.printer:print(fDiagSet, ccIndex)

                if (incrementalMode ~= nil and HasMatchingDiag(fDiagSet, incrementalMode)) then
                    break
                end
            end
        end

        if (self:is("child")) then
            assert(iterationCount == 1)
            os.exit(0)
        end

        self.printer:printTrailingInfo()

        return iterationCount
    end,
}

local function PrintInitialInfo()
    local prefix = pluralize(#compileCommands, "compile command")
    local middle = (selectionSpec ~= nil) and
        format(" (of %d)", compileCommandSelection.originalCount) or ""
    local suffix = (usedConcurrency > 0) and
        format(" with %s", pluralize(usedConcurrency, "worker process", "es")) or ""
    info("Processing %s%s%s.", prefix, middle, suffix)

    if (haveFileSelection) then
        local selectedCount = #compileCommandSelection
        local firstCcIdx = compileCommandSelection[1]
        local lastCcIdx = compileCommandSelection[selectedCount]

        if (selectedCount > 1) then
            local all = (selectedCount == lastCcIdx - firstCcIdx + 1)

            info("(%s compile commands in the range #%d-#%d.)",
                 all and "All" or "A subset of", firstCcIdx, lastCcIdx)
        end
    end
end

local function SetSigintHandler()
    if (usedConcurrency > 0) then
        -- Set SIGINT handling to default (that is, to terminate the receiving process)
        -- instead of the Lua debug hook set by LuaJIT in order to avoid being spammed
        -- with backtraces from the child processes.
        local SIG = posix.SIG
        posix.signal(SIG.INT, SIG.DFL)
    end
end

local function GetGlobalInclusionGraph(compileCommandCount, ccInclusionGraphs)
    local globalGraph = InclusionGraph()
    for i = 1, compileCommandCount do
        if (ccInclusionGraphs[i] ~= nil) then
            globalGraph:merge(ccInclusionGraphs[i])
        end
    end
    return globalGraph
end

------------------------------

local function humanModeMain()
    PrintInitialInfo()
    SetSigintHandler()

    local startTime = os.time()

    -- Inclusion graphs for each compile command.
    local ccInclusionGraphs = {}

    local parserOpts = printGraphMode and {"SkipFunctionBodies", "Incomplete"} or {}
    local control = Controller(range(#compileCommands), parserOpts)

    repeat
        -- Print current diagnostics.
        -- TODO: think about handling case when files change more properly.
        -- TODO: in particular, moves and deletions. (Have common logic with compile_commands.json change?)
        -- Later: handle special case of a change of compile_commands.json, too.

        local processedCommandCount = control:printDiagnostics(ccInclusionGraphs)
        local notifier

        -- TODO: move to separate application
        if (printGraphMode ~= nil) then
            local graph = GetGlobalInclusionGraph(#compileCommands, ccInclusionGraphs)
            PrintInclusionGraphAsGraphvizDot(graph)
            -- TODO: see if there were errors, actually. After all, there may have been
            -- #include errors!
        end

        if (not exitImmediately) then
            notifier = control:getNotifier()
            info("Watching %d files.", notifier:getWatchedFileCount())
        end

        if (control:getAdditionalInfo() ~= nil) then
            info("%s", control:getAdditionalInfo())
        end

        local currentCcIdxs = control:getCcIdxs()
        -- NOTE [STOPPED_EARLY]: it could happen that in incremental mode, there was an
        -- error on the very last compile command. This should be counted as early stop but
        -- is not, among other things to keep the code simpler. This does mean however that
        -- if a subsequent run happens due to a change of a file unrelated to the previously
        -- failing command, the latter will not be re-processed.
        local stoppedEarly = (processedCommandCount < #currentCcIdxs)

        info_underline("Processed %s%s in %d seconds.",
                       pluralize(processedCommandCount, "compile command"),
                       stoppedEarly and format(" (of %d requested)", #control:getCcIdxs()) or "",
                       os.difftime(os.time(), startTime))
        printf("")

        if (exitImmediately) then
            break
        end

        -- Wait for any changes to watched files.
        local event = notifier:check_(printf)
        local eventFileName = notifier:getFileName(event)
        notifier:close()

        -- Determine the set of compile commands to re-process.
        local newCcIdxs, earlyStopCount = GetNewCcIndexes(
            ccInclusionGraphs, eventFileName,
            processedCommandCount, currentCcIdxs)

        info("Detected modification of %s. Processing %s%s.",
             colorize(eventFileName, Col.Bold..Col.White),
             pluralize(#newCcIdxs, "compile command"),
             earlyStopCount > 0 and format(" (including %d due to prior early stop)", earlyStopCount) or "")

        -- Finally, re-process them.
        startTime = os.time()
        control = Controller(newCcIdxs, parserOpts)
    until (false)
end

---------- COMMAND MODE ----------

local function commandModeMain()
    -- TODO
end

----------------------------------

if (commandMode) then
    commandModeMain()
else
    humanModeMain()
end
