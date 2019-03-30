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
local colorize = Col.colorize

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

local function usage(hline)
    if (hline) then
        errprint("ERROR: "..hline.."\n")
    end
    local progname = arg[0]:match("([^/]+)$")
    errprint("Usage:\n  "..progname.." [options...] <compile_commands-file>\n")
    errprint[[
Options:
  -m: Use machine interface / "command mode" (default: for human inspection)
  -g [includes|isIncludedBy]: Print inclusion graph as a DOT (of Graphviz) file to stdout and exit.
     Argument specifies the relation between graph nodes (which are file names).
     Must be used without -m.
]]
    os.exit(ErrorCode.CommandLine)
end

local parsecmdline = require("parsecmdline_pk")

local opts_meta = {
    m = false,
    g = true,
}

local opts, args = parsecmdline.getopts(opts_meta, arg, usage)

local commandMode = opts.m
local printGraphMode = opts.g

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
    errprintf("ERROR: '%s' contains zero compile commands", compileCommandsFile)
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

local InclusionGraph_ProcessTU = function(graph, tu)
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
            graph:addInclusion(fromRealName, toRealName)
        end
    end

    tu:inclusions(callback)
    return graph
end

local function ProcessCompileCommands(cmds, callback)
    for i, cmd in ipairs(cmds) do
        local args = compile_commands_util.sanitize_args(cmd.arguments, cmd.directory)
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

local function GetDiagnosticsForTU(tu)
    local lines = {}

    local callbacks = {
        function() end,

        function(fmt, ...)
            lines[#lines+1] = format(fmt, ...)
        end,
    }

    -- Format diagnostics immediately to not keep the TU around.
    diagnostics_util.PrintDiags(tu:diagnosticSet(), true, callbacks)
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
    local reverse = (printGraphMode == "isIncludedBy")
    initialGlobalInclusionGraph:printAsGraphvizDot(title, reverse, commonPrefix, printf)
end

local function humanModeMain()
    -- One formatted DiagnosticSet per compile command in `cmds`.
    local formattedDiagSets = {}

    ProcessCompileCommands(compileCommands, function(i, tu, errorCode)
        if (tu == nil) then
            -- TODO: Extend in verbosity and/or handling?
            formattedDiagSets[i] = "ERROR: index:parse() failed: "..tostring(errorCode)
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

    -- Initial setup of inotify to monitor all files that directly named by any compile
    -- command or reached by #include, as well as the compile_commands.json file itself.

    local fileNameOfWd = {}

    for _, filename in initialGlobalInclusionGraph:iFileNames() do
        local wd = notifier:add_watch(filename, WATCH_FLAGS)

        -- Assert one-to-oneness. (Should be given by us having passed the file names
        -- through realPathName() earlier.)
        assert(fileNameOfWd[wd] == nil or fileNameOfWd[wd] == filename)

        fileNameOfWd[wd] = filename
    end

    local compileCommandsWd = notifier:add_watch(compileCommandsFile, WATCH_FLAGS)

    -- TODO: build *per-compile-command* include graphs. Use each one to decide whether a
    -- file change affects a compile command. Note: only the nodes (file names) are needed.

    repeat
        -- Print current diagnostics.
        -- TODO: think about handling case when files change more properly.
        -- TODO: in particular, moves and deletions. (Have common logic with compile_commands.json change?)

        for i, cmd in ipairs(compileCommands) do
            -- TODO (prettiness): inform when a file name appears more than once?
            -- TODO (prettiness): print header line (or part of it) in different colors if
            -- compilation succeeded/failed?
            local string = format("Command #%d: %s", i, cmd.file)
            errprintf("%s", colorize(string, Col.Bold..Col.Uline..Col.Green))
            errprintf("%s", formattedDiagSets[i])
        end

        -- Wait for any changes to watched files.
        local event = notifier:check_(printf)

        if (bit.band(event.mask, MOVE_OR_DELETE) ~= 0) then
            errprintf("Exiting: a watched file was moved or deleted. (Handling not implemented.)")
            os.exit(ErrorCode.WatchedFileMovedOrDeleted)
        end

        if (event.wd == compileCommandsWd) then
            errprintf("Exiting: an event was generated for '%s'. (Handling not implemented.)",
                      compileCommandsFile)
            os.exit(ErrorCode.CompileCommandsJsonGeneratedEvent)
        end

        local eventFileName = fileNameOfWd[event.wd]
        assert(eventFileName ~= nil)

        -- Determine the set of compile commands to reparse.
        -- TODO
        -- Later: handle special case of a change of compile_commands.json, too.
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
