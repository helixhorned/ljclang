local bit = require("bit")
local io = require("io")
local os = require("os")
local string = require("string")
local table = require("table")

local cl = require("ljclang")
local class = require("class").class
local compile_commands_reader = require("compile_commands_reader")
local compile_commands_util = require("compile_commands_util")
local diagnostics_util = require("diagnostics_util")
local util = require("util")

local InclusionGraph = require("inclusion_graph").InclusionGraph

local Col = require("terminal_colors")

local check = require("error_util").check
local checktype = require("error_util").checktype

local inotify = require("inotify")
local IN = inotify.IN

local assert = assert
local format = string.format
local ipairs = ipairs
local pairs = pairs
local print = print
local require = require
local tostring = tostring
local tonumber = tonumber

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

local function abort(str)
    errprint("ERROR: "..str.."\n")
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

local GlobalInclusionGraphRelation = "isIncludedBy"

local function usage(hline)
    if (hline) then
        errprint("ERROR: "..hline.."\n")
    end
    local progname = arg[0]:match("([^/]+)$")
    errprint("Usage:\n  "..progname.." [options...] <compile_commands-file>\n")
    errprintf([[
Options:
  -m: Use machine interface / "command mode" (default: for human inspection)

Human mode options:
  -g [includes|isIncludedBy]: Print inclusion graph as a DOT (of Graphviz) file to stdout and exit.
     Argument specifies the relation between graph nodes (which are file names).
     Must be used without -m.
  -l <number>: edge count limit for the graph produced by -g %s.
     If exceeded, a placeholder node is placed.
  -p: Disable color output.
  -x: exit after parsing and displaying diagnostics once.
]], GlobalInclusionGraphRelation)
    os.exit(ErrorCode.CommandLine)
end

local parsecmdline = require("parsecmdline_pk")

local opts_meta = {
    m = false,
    g = true,
    l = true,
    p = false,
    x = false,
}

local opts, args = parsecmdline.getopts(opts_meta, arg, usage)

local commandMode = opts.m
local printGraphMode = opts.g
local edgeCountLimit = tonumber(opts.l)
local plainMode = opts.p
local exitImmediately = opts.x or printGraphMode

local function colorize(...)
    if (plainMode) then
        return ...
    else
        local encoded_string = Col.encode(...)
        return Col.colorize(encoded_string)
    end
end

local function info(fmt, ...)
    local func = printGraphMode and errprintf or printf
    func("%s: "..fmt, colorize("INFO", Col.Green), ...)
end

if (commandMode) then
    for key, _ in pairs(opts_meta) do
        if key ~= 'm' and opts[key] then
            errprintf("ERROR: Option -%s only available without -m", key)
            os.exit(ErrorCode.CommandLine)
        end
    end
end

if (printGraphMode ~= nil) then
    if (printGraphMode ~= "includes" and printGraphMode ~= "isIncludedBy") then
        abort("Argument to option -g must be 'includes' or 'isIncludedBy'")
    end
end

if (edgeCountLimit ~= nil) then
    if (printGraphMode ~= GlobalInclusionGraphRelation) then
        abort("Option -l can only be used with -g being %s", GlobalInclusionGraphRelation)
    end
end

local compileCommandsFile = args[1]

if (compileCommandsFile == nil) then
    usage()
end

----------

local compileCommands, errorMessage =
    compile_commands_reader.read_compile_commands(compileCommandsFile)

if (compileCommands == nil) then
    errprintf("ERROR: failed loading '%s': %s", compileCommandsFile, errorMessage)
    os.exit(ErrorCode.CompilationDatabaseLoad)
end

if (#compileCommands == 0) then
    info("'%s' contains zero entries.", compileCommandsFile)
    os.exit(0)
end

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

-- Initial parse of all compilation commands in the project given by the compilation
-- database.
--
-- Outputs:
--  1. diagnostics for each compilation command
--  2. a DAG of the #include relation for the whole project

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

    return fileSite, fileLco
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

local function DoProcessCompileCommand(cmd, additionalSystemInclude, parseOptions)
    local args = compile_commands_util.sanitize_args(cmd.arguments, cmd.directory)

    if (additionalSystemInclude ~= nil) then
        table.insert(args, 1, "-isystem")
        table.insert(args, 2, additionalSystemInclude)
    end

    local index = cl.createIndex(true, false)

    return index:parse("", args, parseOptions)
end

local MOVE_OR_DELETE = bit.bor(IN.MOVE_SELF, IN.DELETE_SELF)
local WATCH_FLAGS = bit.bor(IN.CLOSE_WRITE, MOVE_OR_DELETE)

-- Inclusion graphs for each compile command.
local compileCommandInclusionGraphs = {}

---------- HUMAN MODE ----------

local function info_underline(fmt, ...)
    local text = string.format(fmt, ...)
    local func = printGraphMode and errprintf or printf
    func("%s%s",
         colorize("INFO", Col.Uline..Col.Green),
         colorize(": "..text, Col.Uline..Col.White))
end

local function GetDiagnosticsForTU(tu)
    local lines = {}

    local callbacks = {
        function() end,

        function(fmt, ...)
            lines[#lines+1] = format(fmt, ...)
        end,
    }

    -- Format diagnostics immediately to not keep the TU around.
    diagnostics_util.PrintDiags(tu:diagnosticSet(), not plainMode, callbacks)
    return table.concat(lines, '\n')
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

local function CheckForIncludeError(tu, formattedDiagSet, cmd, additionalIncludeTab)
    if (additionalIncludeTab[1] ~= nil) then
        return
    end

    local plainFormattedDiagSet = Col.strip(formattedDiagSet)

    local haveIncludeErrors =
        (plainFormattedDiagSet:match("fatal error: ") ~= nil) and
        (plainFormattedDiagSet:match("'.*' file not found") ~= nil)
    assert(not haveIncludeErrors or (tu ~= nil))

    if (haveIncludeErrors) then
        -- HACK so that certain system includes are found.
        local language = tryGetLanguage(cmd)

        additionalIncludeTab[1] =
            -- Fixes LuaJIT:
            (language == "c") and "/usr/lib/llvm-7/lib/clang/7.0.1/include" or
            -- Fixes conky, but breaks EP (personal project of author):
            (language == "c++") and "/usr/lib/llvm-7/include/c++/v1" or
            -- Bail out.
            errprintf("INTERNAL ERROR: don't know how to attempt fixing includes"..
                      " for language that was not determined automatically")
                and os.exit(ErrorCode.Internal)
        return true
    end
end

local function ProcessCompileCommand(ccIndex, parseOptions, successCallback)
    local tu, errorCode
    local additionalIncludeTab = {}
    local count = 0

    local formattedDiagSet
    local hadSomeSystemIncludesAdded = false

    repeat
        count = count + 1
        assert(count <= 2)

        tu, errorCode = DoProcessCompileCommand(
            compileCommands[ccIndex], additionalIncludeTab[1], parseOptions)

        if (tu == nil) then
            -- TODO: Extend in verbosity and/or handling?
            formattedDiagSet = "ERROR: index:parse() failed: "..tostring(errorCode).."\n"
        else
            formattedDiagSet = GetDiagnosticsForTU(tu)
        end

        local retry = CheckForIncludeError(
            tu, formattedDiagSet, compileCommands[ccIndex], additionalIncludeTab)
        hadSomeSystemIncludesAdded = hadSomeSystemIncludesAdded or retry
    until (not retry)

    if (tu ~= nil) then
        if (successCallback ~= nil) then
            successCallback(tu)
        end
        compileCommandInclusionGraphs[ccIndex] = InclusionGraph_ProcessTU(InclusionGraph(), tu)
    end

    local displayFormattedDiagSet = plainMode and
        Col.strip(formattedDiagSet) or
        Col.colorize(formattedDiagSet)

    return displayFormattedDiagSet, hadSomeSystemIncludesAdded
end

local OnDemandParser = class
{
    function(ccIndexes, parseOptions, successCallback)
        return {
            ccIndexes = ccIndexes,
            parseOptions = parseOptions,
            successCallback = successCallback,

            formattedDiagSets = {},
            hadSomeSystemIncludesAdded = false,
        }
    end,

    getCount = function(self)
        return #self.ccIndexes
    end,

    getFormattedDiagSet = function(self, i)
        checktype(i, 1, "number", 2)
        check(i >= 1 and i <= self:getCount(), "argument #1 must be in [1, self:getCount()]", 2)

        local tus, errorCodes = self.tus, self.errorCodes

        if (self.formattedDiagSets[i] == nil) then
            local tmp
            self.formattedDiagSets[i], tmp = ProcessCompileCommand(
                self.ccIndexes[i], self.parseOptions, self.successCallback)
            self.hadSomeSystemIncludesAdded = self.hadSomeSystemIncludesAdded or tmp
        end

        return self.formattedDiagSets[i]
    end,

    iterate = function(self)
        local next = function(_, i)
            i = i+1
            if (i <= self:getCount()) then
                return i, self:getFormattedDiagSet(i), self.ccIndexes[i]
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

local function GetAffectedCompileCommandIndexes(eventFileName)
    local indexes = {}

    for i = 1, #compileCommands do
        local graph = compileCommandInclusionGraphs[i]

        if (graph ~= nil and graph:getNode(eventFileName) ~= nil) then
            indexes[#indexes + 1] = i
        end
    end

    return indexes
end

local function AddFileWatches(initialGraph)
    -- Initial setup of inotify to monitor all files that directly named by any compile
    -- command or reached by #include, as well as the compile_commands.json file itself.

    local notifier = inotify.init()
    local fileNameOfWd = {}

    for _, filename in initialGraph:iFileNames() do
        local wd = notifier:add_watch(filename, WATCH_FLAGS)

        -- Assert one-to-oneness. (Should be the case due to us having passed the file names
        -- through realPathName() earlier.)
        --
        -- TODO: this does not need to hold in the presence of hard links though. Test.
        assert(fileNameOfWd[wd] == nil or fileNameOfWd[wd] == filename)

        fileNameOfWd[wd] = filename
    end

    local compileCommandsWd = notifier:add_watch(compileCommandsFile, WATCH_FLAGS)

    return notifier, fileNameOfWd, compileCommandsWd
end

local function CheckForNotHandledEvents(event, compileCommandsWd)
    if (bit.band(event.mask, MOVE_OR_DELETE) ~= 0) then
        errprintf("Exiting: a watched file was moved or deleted. (Handling not implemented.)")
        os.exit(ErrorCode.WatchedFileMovedOrDeleted)
    end

    if (event.wd == compileCommandsWd) then
        errprintf("Exiting: an event was generated for '%s'. (Handling not implemented.)",
                  compileCommandsFile)
        os.exit(ErrorCode.CompileCommandsJsonGeneratedEvent)
    end
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
        and colorize(string.format("[%d/%d] ", ord, fileCount),
                     Col.Bold..Col.Yellow)
        or ""
end

local function printFormattedDiagSet(formattedDiagSet, ccIndex)
    if (#formattedDiagSet > 0) then
        local cmd = compileCommands[ccIndex]

        local prefix = format("Command #%d:", ccIndex)
        local middle = getFileOrdinalText(cmd, ccIndex)

        errprintf("%s %s%s",
                  colorize(prefix, Col.Bold..Col.Uline..Col.Green),
                  middle,
                  colorize(cmd.file, Col.Bold..Col.Green))
        errprintf("%s", formattedDiagSet)
        return true
    end
end

local function humanModeMain()
    info("Processing %d compile commands.", #compileCommands)

    -- The inclusion graph for the whole project ("global") initial configuration.
    -- Will not be updated on changes to individual files.
    local initialGlobalInclusionGraph = InclusionGraph()

    local startTime = os.time()

    local parserOpts = printGraphMode and {"SkipFunctionBodies", "Incomplete"} or {}
    local successCallback = function(tu)
        InclusionGraph_ProcessTU(initialGlobalInclusionGraph, tu)
    end

    local onDemandParser = OnDemandParser(range(#compileCommands), parserOpts, successCallback)

    local notifier, fileNameOfWd, compileCommandsWd

    repeat
        -- Print current diagnostics.
        -- TODO: think about handling case when files change more properly.
        -- TODO: in particular, moves and deletions. (Have common logic with compile_commands.json change?)
        -- Later: handle special case of a change of compile_commands.json, too.

        for i, formattedDiagSet, ccIndex in onDemandParser:iterate() do
            local printedDiag = printFormattedDiagSet(formattedDiagSet, ccIndex)
        end

        -- TODO: move to separate application
        if (printGraphMode ~= nil) then
            PrintInclusionGraphAsGraphvizDot(initialGlobalInclusionGraph)
            -- TODO: see if there were errors, actually. After all, there may have been
            -- #include errors!
        end

        if (notifier == nil and not exitImmediately) then
            notifier, fileNameOfWd, compileCommandsWd =
                AddFileWatches(initialGlobalInclusionGraph)
            info("Watching %d files.", initialGlobalInclusionGraph:getNodeCount() + 1)
        end

        if (onDemandParser:getAdditionalInfo() ~= nil) then
            info("%s", onDemandParser:getAdditionalInfo())
        end
        info_underline("Processed %d compile commands in %d seconds.",
                       onDemandParser:getCount(), os.difftime(os.time(), startTime))
        printf("")

        if (exitImmediately) then
            break
        end

        -- Wait for any changes to watched files.
        local event = notifier:check_(printf)
        startTime = os.time()

        CheckForNotHandledEvents(event, compileCommandsWd)

        local eventFileName = fileNameOfWd[event.wd]
        assert(eventFileName ~= nil)

        -- Determine the set of compile commands to re-process.
        local ccIndexes = GetAffectedCompileCommandIndexes(eventFileName)

        info("Detected modification of %s. Need re-processing %d compile commands.",
             colorize(eventFileName, Col.Bold..Col.White), #ccIndexes)

        -- Finally, re-process them.
        onDemandParser = OnDemandParser(ccIndexes, parserOpts)
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
