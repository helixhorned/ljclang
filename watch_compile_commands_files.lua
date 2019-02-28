
local bit = require("bit")
local io = require("io")
local os = require("os")
local string = require("string")
local table = require("table")

local cl = require("ljclang")
local compile_commands_reader = require("compile_commands_reader")
local compile_commands_util = require("compile_commands_util")
local diagnostics_util = require("diagnostics_util")
local InclusionGraph = require("inclusion_graph").InclusionGraph

local Col = require("terminal_colors")
local colorize = Col.colorize

local inotify = require("inotify")
local IN = inotify.IN

local assert = assert
local format = string.format
local ipairs = ipairs
local pairs = pairs
local print = print
local require = require

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

local function usage(hline)
    if (hline) then
        errprint("ERROR: "..hline.."\n")
    end
    local progname = arg[0]:match("([^/]+)$")
    errprint("Usage:\n  "..progname.." [options...] <compile_commands-file> <project-root-directory>\n")
    errprint[[
Options:
  -m: Use machine interface / "command mode" (default: for human inspection)
]]
    os.exit(1)
end

local parsecmdline = require("parsecmdline_pk")
local opts, args = parsecmdline.getopts({ m=false }, arg, usage)

local commandMode = opts.m

if (commandMode) then
    abort("Command mode not yet implemented!")
end

local compileCommandsFile = args[1]
local projectRootDir = args[2]

if (compileCommandsFile == nil or projectRootDir == nil) then
    usage()
end

----------

local cmds, errmsg = compile_commands_reader.read_compile_commands(compileCommandsFile)
if (cmds == nil) then
    errprintf("ERROR: failed loading '%s': %s", compileCommandsFile, errmsg)
    os.exit(1)
end

-- Initial parse of all compilation commands.
-- Outputs:
--  1. diagnostics for each compilation command
--  2. a DAG of the #include relation for the whole project (= compilation database)

local index = cl.createIndex(true, false)

---------- Common to both human and command mode ----------

-- Initial setup of inotify to monitor all source files named by any compile command.
--
-- TODO: move to after parsing all commands and creating the inclusion graph:
-- then, we can also add files reached by #include (but not system headers).

local notifier = inotify.init()
local WATCH_FLAGS = bit.bor(IN.MODIFY, IN.MOVE_SELF, IN.DELETE_SELF)

for _, cmd in ipairs(cmds) do
    notifier:add_watch(cmd.file, WATCH_FLAGS)
end

local getSite = function(location)
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

local BuildInclusionGraph = function(tu)
    local inclusionGraph = InclusionGraph()

    local callback = function(includedFile, stack)
        if (#stack == 0) then
            return
        end

        local toFileName = includedFile:name()
        local fromFile = getSite(stack[1])
        local fromFileName = fromFile:name()
--printf("qwe %s %s", fromFileName, toFileName)

        -- Check that all names we get passed are absolute.
        -- This should be the case because compile_commands_reader absifies names for us.
        assert(toFileName:sub(1,1) == "/")
        assert(fromFileName:sub(1,1) == "/")

        -- Check sanity: system headers never include user files.
        assert(not (stack[1]:isInSystemHeader() and not includedFile:isSystemHeader()))

        if (not includedFile:isSystemHeader()) then
            -- Be even stricter: verify that the names we obtain from plain name() are
            -- canonical. (We assume that realPathName() gives us the canonical file name.)
            --
            -- NOTE: for system headers this may not hold.
            --
            -- (XXX: and strictly seen, for user files this does not need to hold, either.
            -- It is well conceivable that a compile_commands.json includes file names that
            -- contain '..', for example.)
            --
            -- TODO: just use realPathName() across the board, then?
--print("names: ", toFileName, includedFile:realPathName())
            assert(toFileName == includedFile:realPathName())
            assert(fromFileName == fromFile:realPathName())

            inclusionGraph:addInclusion(fromFileName, toFileName)
        end
    end

    tu:inclusions(callback)
    return inclusionGraph
end

---------- HUMAN MODE ----------

local function humanModeMain()
    -- One formatted DiagnosticSet per compile command in `cmds`.
    local formattedDiagSets = {}

    -- TODO: progress meter. Make it time-based in human mode? (E.g. every 5 seconds.)
    for i, cmd in ipairs(cmds) do
        local args = compile_commands_util.sanitize_args(cmd.arguments, cmd.directory)
        local tu, errorCode = index:parse("", args, {"KeepGoing"})

        if (tu == nil) then
            formattedDiagSets[i] = "index:parse() failed: "..errorCode
            goto nextfile
        end

        -- Build inclusion graph.

        local inclusionGraph = BuildInclusionGraph(tu)

        -- TEMP
        for _, fileName in inclusionGraph:iFileNames() do
            for _, from, to in inclusionGraph:getNode(fileName):iEdges() do
                printf("%s includes %s", from, to)
            end
        end

        -- Obtain diagnostics.

        local lines = {}

        local callbacks = {
            function() end,

            function(fmt, ...)
                lines[#lines+1] = format(fmt, ...)
            end,
        }

        -- Format diagnostics immediately to not keep the TU around.
        diagnostics_util.PrintDiags(tu:diagnosticSet(), true, callbacks)
        formattedDiagSets[i] = table.concat(lines, '\n')
        ::nextfile::
    end

    repeat
        -- Print current diagnostics.
        -- TODO: handle case when files change.
        -- TODO: in particular, moves and deletions. (Have common logic with compile_commands.json change?)

        for i, cmd in ipairs(cmds) do
            -- TODO (prettiness): inform when a file name appears more than once?
            -- TODO (prettiness): print header line (or part of it) in different colors if
            -- compilation succeeded/failed?
            local string = format("Command #%d: %s", i, cmd.file)
            errprintf("%s", colorize(string, Col.Bold..Col.Uline..Col.Green))
            errprintf("%s", formattedDiagSets[i])
        end

        -- Wait for any changes to watched files.
        notifier:check_(printf)
        -- TODO

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
