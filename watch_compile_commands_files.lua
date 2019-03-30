local bit = require("bit")
local io = require("io")
local os = require("os")
local string = require("string")
local table = require("table")

local cl = require("ljclang")
local compile_commands_reader = require("compile_commands_reader")
local compile_commands_util = require("compile_commands_util")
local diagnostics_util = require("diagnostics_util")
local util = require("util")

local InclusionGraph = require("inclusion_graph").InclusionGraph

local Col = require("terminal_colors")

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
end

local function abort(str)
    errprint(str.."\n")
    os.exit(1)
end

local ErrorCode = {
    CommandLine = 1,
    CompilationDatabaseLoad = 2,
    CompilationDatabaseEmpty = 3,
    RealPathName = 4,

    WatchedFileMovedOrDeleted = 100,
    CompileCommandsJsonGeneratedEvent = 101,
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
  -g [includes|isIncludedBy]: Print inclusion graph as a DOT (of Graphviz) file to stdout and exit.
     Argument specifies the relation between graph nodes (which are file names).
     Must be used without -m.
  -l <number>: edge count limit for the graph produced by -g %s.
     If exceeded, a placeholder node is placed.
  -p: Disable color output.
  -x: exit immediately after parsing once.
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
local exitImmediately = opts.x

local function colorize(...)
    if (plainMode) then
        return ...
    else
        return Col.colorize(...)
    end
end

if (commandMode) then
    abort("Command mode not yet implemented!")
end

if (printGraphMode ~= nil) then
    if (printGraphMode ~= "includes" and printGraphMode ~= "isIncludedBy") then
        abort("Argument to option -g must be 'includes' or 'isIncludedBy'")
    end
    if (commandMode) then
        abort("Option -g must be used without option -m")
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
    errprintf("ERROR: '%s' contains zero entries", compileCommandsFile)
    os.exit(ErrorCode.CompilationDatabaseEmpty)
end


-- Initial parse of all compilation commands in the project given by the compilation
-- database.
--
-- Outputs:
--  1. diagnostics for each compilation command
--  2. a DAG of the #include relation for the whole project

local index = cl.createIndex(true, false)

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
        errprintf("Could not obtain the real path name of '%s'", file:name())
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

local function ProcessCompileCommands(cmds, callback)
    for i, cmd in ipairs(cmds) do
        local args = compile_commands_util.sanitize_args(cmd.arguments, cmd.directory)

        -- HACKS so that certain system includes are found.
        -- TODO: use insert/remove in other places
        table.insert(args, 1, "-isystem")
        table.insert(args, 2, "/usr/lib/llvm-7/lib/clang/7.0.1/include/")  -- fixes luajit
        table.insert(args, 1, "-isystem")
        table.insert(args, 2, "/usr/lib/llvm-7/include/c++/v1")  -- fixes conky. TODO: include only with C++

        local tu, errorCode = index:parse("", args, {"KeepGoing"})
        callback(i, tu, errorCode)
    end
end

local notifier = inotify.init()
local MOVE_OR_DELETE = bit.bor(IN.MOVE_SELF, IN.DELETE_SELF)
local WATCH_FLAGS = bit.bor(IN.CLOSE_WRITE, MOVE_OR_DELETE)

-- The inclusion graph for the whole project ("global") initial configuration.
-- Will not be updated on updates to individual files.
local initialGlobalInclusionGraph = InclusionGraph()

-- Inclusion graphs for each compile command.
local compileCommandInclusionGraphs = {}

---------- HUMAN MODE ----------

local function info(fmt, ...)
    printf("%s: "..fmt, colorize("INFO", Col.Green), ...)
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

local function PrintInclusionGraphAsGraphvizDot()
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
    initialGlobalInclusionGraph:printAsGraphvizDot(title, reverse, commonPrefix, edgeCountLimit, printf)
end

local function GetAffectedCompileCommandIndexes(eventFileName)
    local indexes = {}

    for i = 1, #compileCommands do
        local graph = compileCommandInclusionGraphs[i]

        if (graph:getNode(eventFileName) ~= nil) then
            indexes[#indexes + 1] = i
        end
    end

    return indexes
end

local function AddFileWatches()
    -- Initial setup of inotify to monitor all files that directly named by any compile
    -- command or reached by #include, as well as the compile_commands.json file itself.

    local fileNameOfWd = {}

    for _, filename in initialGlobalInclusionGraph:iFileNames() do
        local wd = notifier:add_watch(filename, WATCH_FLAGS)

        -- Assert one-to-oneness. (Should be given by us having passed the file names
        -- through realPathName() earlier.)
        --
        -- TODO: this does not need to hold in the presence of hard links though. Test.
        assert(fileNameOfWd[wd] == nil or fileNameOfWd[wd] == filename)

        fileNameOfWd[wd] = filename
    end

    local compileCommandsWd = notifier:add_watch(compileCommandsFile, WATCH_FLAGS)

    return fileNameOfWd, compileCommandsWd
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

local function humanModeMain()
    -- One formatted DiagnosticSet per compile command in `cmds`.
    local formattedDiagSets = {}

    ProcessCompileCommands(compileCommands, function(i, tu, errorCode)
        if (tu == nil) then
            -- TODO: Extend in verbosity and/or handling?
            formattedDiagSets[i] = "ERROR: index:parse() failed: "..tostring(errorCode).."\n"
        else
            formattedDiagSets[i] = GetDiagnosticsForTU(tu)

            InclusionGraph_ProcessTU(initialGlobalInclusionGraph, tu)
            compileCommandInclusionGraphs[i] = InclusionGraph_ProcessTU(InclusionGraph(), tu)
        end
    end)

    -- TODO: move to separate application
    if (printGraphMode ~= nil) then
        PrintInclusionGraphAsGraphvizDot()
        os.exit(0)
    end

    local fileNameOfWd, compileCommandsWd = AddFileWatches()

    info("Have %d compile commands, watching %d files", #compileCommands,
         initialGlobalInclusionGraph:getNodeCount() + 1)

    repeat
        -- Print current diagnostics.
        -- TODO: think about handling case when files change more properly.
        -- TODO: in particular, moves and deletions. (Have common logic with compile_commands.json change?)
        -- Later: handle special case of a change of compile_commands.json, too.

        for i, cmd in ipairs(compileCommands) do
            -- TODO (prettiness): inform when a file name appears more than once?
            -- TODO (prettiness): print header line (or part of it) in different colors if
            -- compilation succeeded/failed?
            if (#formattedDiagSets[i] > 0) then
                local string = format("Command #%d: %s", i, cmd.file)
                errprintf("%s", colorize(string, Col.Bold..Col.Uline..Col.Green))
                errprintf("%s", formattedDiagSets[i])
            end
        end

        if (exitImmediately) then
            break
        end

        -- Wait for any changes to watched files.
        local event = notifier:check_(printf)

        CheckForNotHandledEvents(event, compileCommandsWd)

        local eventFileName = fileNameOfWd[event.wd]
        assert(eventFileName ~= nil)

        -- Determine the set of compile commands to reparse.

        local affectedCompileCommandIndexes = GetAffectedCompileCommandIndexes(eventFileName)
        info("Need reparsing %d compile commands", #affectedCompileCommandIndexes)

        -- TODO: update
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
