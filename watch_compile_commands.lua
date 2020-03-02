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

local CacheDirectory = HomeDir.."/.cache/ljclang"
local TempDirectory = "/tmp/ljclang"
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
  -c <concurrency>: set number of parallel parser invocations. (Minimum: 1)
     'auto' means use hardware concurrency (the default).
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
  -s [-]<selector1> [-s [-]<selector2> ...]: Select compile command(s) to process.
     Selectors are processed in the order they appear on the command line. Each selector can
     be prefixed by '-', which means to remove the matching set of compile commands from the
     current set. If a removal appears first, the initial set contains all compile commands,
     otherwise it is empty.
     Each <selector> can be one of:
      - '@...': by index (see below).
      - '{<pattern>}': by Lua pattern matching the absolute file name in a compile command.
  -N: Print all diagnostics. This disables omission of:
      - diagnostics that follow a Parse Issue error, and
      - diagnostics that were seen in previous compile commands.
  -P: Disable color output.
  -v: Be verbose. Currently: output compiler invocations for Auto-PCH generation failures.
  -x: exit after parsing and displaying diagnostics once.

  If the selector to an option -s starts with '@', it must have one of the following forms,
  where the integral <number> starts with a decimal digit distinct from zero:
    - '@<number>': single compile command, or
    - '@<number>..': range starting with the specified index, or
    - '@<number>..<number>': inclusive range.]],
progname, CacheDirectory, GlobalInclusionGraphRelation)
    os.exit(ErrorCode.CommandLine)
end

local parsecmdline = require("parsecmdline_pk")

local opts_meta = {
    a = false,
    c = true,
    i = true,
    m = true,
    g = true,
    l = true,
    r = true,
    s = 1,  -- collect all instances
    N = false,
    P = false,
    v = false,
    x = false,
}

local opts, args = parsecmdline.getopts(opts_meta, arg, usage)

local autoPch = opts.a
local concurrencyOpt = opts.c or "auto"
local requestFifoFileName = opts.m
local commandMode = (requestFifoFileName ~= nil)
local incrementalMode = opts.i
local printGraphMode = opts.g
local edgeCountLimit = tonumber(opts.l)
local progressSpec = opts.r
local selectionSpecs = opts.s
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

-- NOTE: 'mi' is shorthand for "machine interface" and is (somewhat inaccurately) used
-- synonymously with "command mode".
local function miInfo(fmt, ...)
    local func = printGraphMode and errprintf or printf
    func("%s: "..fmt, colorize("INFO", Col.Bold..Col.Cyan), ...)
end

local function errorInfo(fmt, ...)
    local func = printGraphMode and errprintf or printf
    func("%s: "..fmt, colorize("INFO", Col.Bold..Col.Red), ...)
end

local function warnInfo(fmt, ...)
    local func = printGraphMode and errprintf or printf
    func("%s: "..fmt, colorize("INFO", Col.Bold..Col.Purple), ...)
end

local function errorInfoAndExit(fmt, ...)
    errorInfo(fmt, ...)
    os.exit(1)
end

local function exitRequestingBugReport()
    errorInfoAndExit("Please report this issue as a bug.")
    -- TODO: include URL to github, preferably to the issue tracker with the right branch.
end

local function infoAndExit(fmt, ...)
    info(fmt, ...)
    os.exit(0)
end

local function getUsedConcurrency()
    if (concurrencyOpt == "auto") then
        return math.max(1, cl.hardwareConcurrency())
    else
        if (not concurrencyOpt:match("^[1-9][0-9]*$")) then
            abort("Argument to option -c must be 'auto' or a positive integral number.")
        end

        local c = tonumber(concurrencyOpt)
        assert(c ~= nil and c >= 1)
        return c
    end
end

if (commandMode) then
    local DisallowedOpts = {'i', 'g', 'x'}

    for _, opt in ipairs(DisallowedOpts) do
        if (opts[opt]) then
            errprintf("ERROR: Option -%s only available without -m", opt)
            os.exit(ErrorCode.CommandLine)
        end
    end
end

if (printGraphMode ~= nil) then
    if (printGraphMode ~= "includes" and printGraphMode ~= "isIncludedBy") then
        abort("Argument to option -g must be 'includes' or 'isIncludedBy'.")
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
        abort("Option -l can only be used with -g being %s.", GlobalInclusionGraphRelation)
    end
end

local printProgressAfterSeconds = nil
local printProgressAfterCcCount = nil

if (progressSpec ~= nil) then
    local isCountSpecified = (progressSpec:sub(1,1) == "c")
    local isSecondsSpecified = (progressSpec:sub(-1) == "s")

    if (not isCountSpecified and not isSecondsSpecified) then
        abort("Argument to option -r must have the form 'c<count>' or '<seconds>s'.")
    end

    local num =
        isCountSpecified and tonumber(progressSpec:sub(2)) or
        isSecondsSpecified and tonumber(progressSpec:sub(1,-2))

    if (type(num) ~= "number" or not (num >= 0)) then
        abort("Number passed to option -r must be zero or greater.")
    end

    if (isCountSpecified) then
        if (commandMode) then
            -- See MONOTONIC_PRINT for why.
            abort("'c<count>' form of -r not allowed in command mode.")
        end
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
local linux_decls = require("ljclang_linux_decls")
local inotify = require("inotify")
local IN = inotify.IN

----------

local function ReadCompileCommands()
    local compileCmds, errorMessage =
        compile_commands_reader.read_compile_commands(compileCommandsFile)

    if (compileCmds == nil) then
        errprintf("ERROR: failed loading '%s': %s", compileCommandsFile, errorMessage)
        os.exit(ErrorCode.CompilationDatabaseLoad)
    end

    if (#compileCmds == 0) then
        infoAndExit("'%s' contains zero entries.", compileCommandsFile)
    end

    return compileCmds
end

local function HandleSelectionSpec(compileCmds, fullSelectSpec, specIdx,
                                   currentIsSelected --[[modified in-place]])
    local specPrefix, selectSpec = fullSelectSpec:match("^(%-?)(.*)$")
    assert(selectSpec ~= nil)

    local isAddition = (specPrefix == "");
    assert(isAddition or specPrefix == '-')

    local selType = selectSpec:sub(1, 1)
    local haveIndexSelection = (selType == '@')
    local haveFileSelection = (selType == '{')
    local errorSuffix = format("at '-s' option #%d", specIdx)

    local function selectCompileCommand(i)
        currentIsSelected[i] = isAddition
    end

    if (haveIndexSelection) then
        local startStr, rangeStr, endStr = selectSpec:match("^@([1-9][0-9]*)([%.]*)([0-9]*)$")

        local isValid =
            (startStr ~= nil and rangeStr ~= nil and endStr ~= nil) and
            (rangeStr == "" or rangeStr == "..") and
            (endStr == "" or endStr:sub(1,1) ~= '0')

        if (not isValid) then
            abort("Invalid index selection specification %s.", errorSuffix)
        end

        -- NOTE: in Lua, if assert() returns, it returns the value passed.
        --  Check that the argument value was properly converted this way.
        local startIndex = assert(tonumber(startStr)) or 1
        local endIndex =
            endStr ~= "" and assert(tonumber(endStr)) or  -- @<number>..<number>
            rangeStr ~= "" and #compileCmds or            -- @<number>..
            startIndex                                    -- @<number>

        assert(startIndex >= 1 and endIndex >= 1)

        if (not (startIndex <= #compileCmds) or not (endIndex <= #compileCmds)) then
            abort("Compile command index out of range [1, %d] %s.",
                  #compileCmds, errorSuffix)
        end

        if (startIndex > endIndex) then
            infoAndExit("Selected empty range %s.", errorSuffix)
        end

        for i = startIndex, endIndex do
            selectCompileCommand(i)
        end
    elseif (haveFileSelection) then
        if (selectSpec:sub(-1) ~= '}') then
            abort("Invalid pattern selection specification %s.", errorSuffix)
        end

        local pattern = selectSpec:sub(2,-2)

        do
            local ok, msg = pcall(function() return pattern:match(pattern) end)
            if (not ok) then
                abort("Invalid pattern %s: %s.", errorSuffix, msg)
            end
        end

        for i, cmd in ipairs(compileCmds) do
            if (cmd.file:match(pattern)) then
                selectCompileCommand(i)
            end
        end
    else
        abort("Invalid selection specification %s.", errorSuffix)
    end

    return haveFileSelection
end

local function HandleAllSelectionSpecs()
    assert(type(selectionSpecs) == "table")

    local allCompileCommands = ReadCompileCommands()

    local selectInfo = {
        -- [selected compile command index] = <original compile command index>
        indexMap = {},

        originalCcCount = #allCompileCommands,
        haveFileSelection = false,
        isContiguous = true,
    }

    if (#selectionSpecs == 0) then
        return allCompileCommands, selectInfo
    end

    local firstSpecIsRemoval = (selectionSpecs[1]:sub(1,1) == '-')
    local isCcSelected = util.BoolArray(#allCompileCommands, firstSpecIsRemoval)

    for specIdx, spec in ipairs(selectionSpecs) do
        selectInfo.haveFileSelection =
            HandleSelectionSpec(allCompileCommands, spec, specIdx, isCcSelected) or
            selectInfo.haveFileSelection
    end

    local newCompileCommands = {}

    for i, cmd in ipairs(allCompileCommands) do
        if (isCcSelected[i]) then
            local newIdx = #newCompileCommands + 1
            newCompileCommands[newIdx] = cmd
            selectInfo.indexMap[newIdx] = i
        end
    end

    if (#newCompileCommands == 0) then
        infoAndExit("No compile commands remaining after selection.")
    end

    local sel = selectInfo.indexMap
    selectInfo.isContiguous = (#sel == sel[#sel] - sel[1] + 1)

    return newCompileCommands, selectInfo
end

local compileCommands, selectionInfo = HandleAllSelectionSpecs()
local usedConcurrency = math.min(getUsedConcurrency(), #compileCommands)

do
    -- [<absolute file name>] = { sIdx1 [, sIdx2, ...] }  (selected CC indexes)
    local ccIdxsFor = {}

    for ccIdx, cmd in ipairs(compileCommands) do
        ccIdxsFor[cmd.file] = ccIdxsFor[cmd.file] or {}
        local idxsForCc = ccIdxsFor[cmd.file]
        idxsForCc[#idxsForCc + 1] = ccIdx
    end

    selectionInfo.ccIdxsFor = ccIdxsFor
end

----------

local Connection = class
{
    function(readFd, writeFd, childPid, extraFd)
        assert(readFd ~= nil)
        assert(writeFd ~= nil)

        return {
            r = readFd,
            w = writeFd,

            -- May be nil:
            childPid = childPid,
            _extra = extraFd,
        }
    end,

    close = function(self)
        self.r:close()
        self.w:close()

        if (self._extra ~= nil) then
            self._extra:close()
        end
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

        if (whoami == "child") then
            self.toParent.r:close()
            self.toChild.w:close()
            return Connection(self.toChild.r, self.toParent.w)
        else
            local toParentW = (childPid ~= nil) and self.toParent.w or nil

            if (toParentW == nil) then
                self.toParent.w:close()
            else
                -- Deliberately keep open the write end of the 'child -> parent'
                -- connection in the parent so that we never get POLL.HUP from poll().
            end

            self.toChild.r:close()
            return Connection(self.toParent.r, self.toChild.w,
                              childPid, toParentW)
        end
    end,
}

local function ReadAll(readFd)
    local readParts = {}

    repeat
        readParts[#readParts + 1] = readFd:read(8192)
    until (#readParts[#readParts] == 0)

    readParts[#readParts] = nil
    return table.concat(readParts)
end

local function WaitForChild(pid)
    local status, exitCode = posix.waitpid(pid, 0)
    assert((status == "exited") == (exitCode == 0))
    -- Return 'huge' value to signal we do not know the real return value.
    return (status == "exited") and 0 or math.huge
end

local function Execute(fileName, args)
    local whoami, pid = posix.fork()

    if (whoami == "child") then
        -- Redirect the standard streams.
        posix.freopen("/dev/null", "r", ffi.C.stdin)
        posix.freopen("/dev/null", "w", ffi.C.stdout)
        posix.freopen("/dev/null", "rw", ffi.C.stderr)

        posix.exec(fileName, args)
    else
        return WaitForChild(pid)
    end
end

local function ExecuteAsync(fileName, args)
    local pipePair = PipePair()
    local whoami, pid = posix.fork()
    local conn = pipePair:getConnection(whoami)

    if (whoami == "child") then
        -- Redirect stdout and stderr to the write end of the passed pipe.
        conn.w:capture(posix.STDOUT_FILENO)
        conn.w:capture(posix.STDERR_FILENO)

        posix.exec(fileName, args)
    else
        return function()
            local str = ReadAll(conn.r)
            conn:close()
            local exitCode = WaitForChild(pid)
            return (exitCode == 0) and str or nil
        end
    end
end

local function GetPchInputFiles()
    local luaPath = getEnv("LUA_PATH", "Lua path")
    -- KEEPINSYNC with app.sh.in
    local ljclangDir = luaPath:match(";;(.*)/%?%.lua")
    if (ljclangDir == nil) then
        abort("Failed to obtain LJClang directory from Lua path.")
    end

    return ljclangDir.."/dev/cxx_headers.hpp", ljclangDir.."/dev/empty.cpp"
end

if (Execute("/bin/mkdir", {"-p", CacheDirectory}) ~= 0) then
    errorInfoAndExit("Failed creating cache directory %s.", CacheDirectory)
end

---------- Command mode / Machine interface ----------

local MI = {
    FIFO_WATCH_FLAGS = IN.CLOSE_WRITE,
}

MI.State = class
{
    function()
        local O = posix.O

        -- NOTE: do not use io.open():
        --  - It would block for as long as there are no writers.
        --  - We need the file descriptor for inotify, anyway.
        local fifoFd = ffi.C.open(requestFifoFileName, bit.bor(O.RDONLY, O.NONBLOCK))

        if (fifoFd == -1) then
            errorInfoAndExit("Failed opening FIFO %s.", requestFifoFileName)
        end

        local inotifier = inotify.init()
        inotifier:add_watch(requestFifoFileName, MI.FIFO_WATCH_FLAGS)

        return {
            clientPidFifo = posix.Fd(fifoFd),
            clientInotifier = inotifier,
        }
    end,
}

local mi = commandMode and MI.State() or nil

local FormattedDiagSetPrinter  -- "forward-declare"

function MI.GetRealNameFor(fileName)
    if (fileName == nil) then
        return nil, "missing file name"
    end

    assert(#fileName > 0)  -- because we matched with '+'
    if (fileName:sub(1,1) ~= '/') then
        return nil, "file name must be absolute"
    end

    local realName, errorMsg = posix.realpath(fileName)
    if (realName == nil) then
        return nil, "failed resolving file name: "..errorMsg
    end

    return realName
end

function MI.DoHandleClientRequest(command, args, crTab)
    local control, prioritizeCcFunc = unpack(crTab)

    if (command == "-C") then
        -- NOTE: arguments are completely ignored.
        return ""
    elseif (command == "diags") then
        local keepColors = (args[1] == "-k")
        if (keepColors) then
            table.remove(args, 1)
        end

        local realName, errorMsg = MI.GetRealNameFor(args[1])
        if (realName == nil) then
            return nil, errorMsg
        end

        -- TODO: handle non-sources.
        local idxsForCc = selectionInfo.ccIdxsFor[realName]
        if (idxsForCc == nil) then
            return nil, "no compile commands for file name"
        end

        local printer = FormattedDiagSetPrinter()
        local haveUnprocessed = false
        local tab = {}

        for _, ccIdx in ipairs(idxsForCc) do
            local fDiagSet = control.miFormattedDiagSets[ccIdx]
            if (fDiagSet == nil) then
                -- Compile command not yet processed, so:
                prioritizeCcFunc(ccIdx)
                haveUnprocessed = true
            else
                tab[#tab + 1] = printer:emulatePrint(keepColors, fDiagSet, ccIdx)
            end
        end

        if (haveUnprocessed) then
            table.insert(tab, 1, "INFO: one or more compile commands not yet processed.")
        end

        return table.concat(tab, '\n')
    end

    return nil, "unrecognized command"
end

function MI.GetOutputFifo(clientId, errorSuffix)
    local returnFifoName = format("%s/wcc-client-%s.fifo", TempDirectory, clientId)

    local O = posix.O
    local fifoFd = ffi.C.open(returnFifoName, bit.bor(O.WRONLY, O.NONBLOCK))

    if (fifoFd == -1) then
        miInfo("Failed opening FIFO for results of %s. Was it opened for reading?",
               errorSuffix)
        return
    end

    return posix.Fd(fifoFd)
end

function MI.HandleClientRequest(request, crTab)
    assert(type(request) == "string")
    assert(request:match('\n') == nil)

    local args = {}

    do
        local ii = 0
        for arg in request:gmatch("[^%s]+") do
            ii = ii+1
            args[ii - 2] = arg
        end
    end

    local clientId, command = unpack(args, -1, 0)
    args[-1] = nil
    args[0] = nil

    if (clientId == nil or not (clientId == '-' or clientId:match("^[0-9]+$"))) then
        miInfo("Ignored client request (client ID malformed).")
    end

    local isAnonRequest = (clientId == '-')
    local errorSuffix = isAnonRequest and
        "request by unknown client" or
        format("request by client %s", clientId)

    miInfo("client: %s %s", command, table.concat(args, ' '))

    if (command == nil) then
        -- NOTE: don't bother outputting anything to the client-prepared FIFO.
        miInfo("Ignoring %s: missing command.", errorSuffix)
        return
    end

    local fifo = (not isAnonRequest) and MI.GetOutputFifo(clientId, errorSuffix) or nil
    if (fifo ~= nil) then
        -- Send an acknowledgement of the request receival (3 bytes).
        fifo:writePipe("ACK")
    end

    -- Do the actual work for the request.
    local result, errorMsg = MI.DoHandleClientRequest(command, args, crTab)
    assert(result == nil or type(result) == "string")

    if (fifo ~= nil) then
        local output = {
            -- Success status (3 bytes).
            (errorMsg ~= nil) and "rER" or "rOK",
            -- Result text.
            (errorMsg ~= nil) and errorMsg or result,
            -- Newline.
            '\n',
        }

        fifo:writePipe(table.concat(output))
        fifo:close()
    end
end

function MI.HandleClientRequests(crTab)
    assert(#crTab == 2)

    -- Read from the client inotify file descriptor (to clear the poll()
    -- status) and discard. We are only interested in the data arrived in
    -- the client request FIFO.
    mi.clientInotifier:waitForEvents()

    local fifo = mi.clientPidFifo
    assert(fifo ~= nil)

    local pipeIsEmpty = function(str)
        return
            -- we got errno EAGAIN: pipe is empty and some process has it open for writing.
            (str == nil) or
            -- we got return 0: pipe is empty and no process has the pipe open for writing.
            (str == "")
    end

    local ChunkSize = 4096

    while (true) do
        local requests = fifo:readNonblocking(ChunkSize)

        if (pipeIsEmpty(requests)) then
            break
        end

        if (#requests == ChunkSize) then
            -- Bail out: the tail might straddle a message.
            errorInfoAndExit("Client request FIFO overflow.")
        end

        if (requests:sub(-1) ~= "\n") then
            miInfo("Client request FIFO: possible message loss.")
        end

        for request in requests:gmatch("(.-)\n") do
            MI.HandleClientRequest(request, crTab)
        end
    end
end

---------- Preparation ----------

local function resolveClangBinary(name)
    local binDir = getEnv("LLVM_BINDIR", "LLVM binary directory")
    local fileName = binDir .. "/" .. name
    local realName, errMsg = posix.realpath(fileName)

    if (realName == nil) then
        abort("Failed resolving %s: %s.", fileName, errMsg)
    end

    return realName
end

compile_commands_util.obtainSystemIncludes(
    -- NOTE: here, the real name of the binary is required because it is matched in the
    --  output of the program invocation.
    resolveClangBinary("clang"),
    usedConcurrency, compileCommands, CacheDirectory,
    {
        errorInfo = errorInfo,
        errorInfoAndExit = errorInfoAndExit,
        ExecuteAsync = ExecuteAsync,
        info = info,
    }
)

---------- Automatic precompiled headers ----------

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
                -- Tentatively use. We may still disable usage if PCH generation fails.
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

    -- Files in fixed paths

    local cxxHeadersHpp, emptyCpp = GetPchInputFiles()
    local clangpp = resolveClangBinary("clang++")

    -- Functions

    local generatePch = function(pchArgs)
        local cmdArgs = {}

        for _, arg in ipairs(pchArgs) do
            cmdArgs[#cmdArgs + 1] = arg
        end

        local fullPchFileName = pchArgs.pchFileName
        cmdArgs[#cmdArgs] = fullPchFileName
        cmdArgs[#cmdArgs + 1] = cxxHeadersHpp

        -- NOTE: we could parallelize, but that does not seem worth the effort since one
        -- PCH file is generated once and used from then on until it is invalidated for
        -- some reason (like an update to standard library headers).
        local ret = Execute(clangpp, cmdArgs)

        if (ret ~= 0) then
            if (opts.v) then
                warnInfo("Auto-PCH: generation of PCH file failed: %s %s",
                         clangpp, table.concat(cmdArgs, ' '))
            end
            return false
        end

        if (not exists(fullPchFileName)) then
            errorInfo("Auto-PCH: PCH file to be generated\
  %s\
does not exist even though the command to generate it ran successfully.", fullPchFileName)
            exitRequestingBugReport()
        end

        return true
    end

    -- Attempts to compile an empty file with the given PCH configuration.
    local testPch = function(pchArgs)
        local cmdArgs = { "-fsyntax-only", "-include-pch", pchArgs.pchFileName }

        -- Convention of compile_commands_util's getPchGenData():
        assert(pchArgs[#pchArgs - 1] == "-o")

        for i = 1, #pchArgs - 2 do
            cmdArgs[#cmdArgs + 1] = pchArgs[i]
        end

        cmdArgs[#cmdArgs + 1] = emptyCpp

        return (Execute(clangpp, cmdArgs) == 0)
    end

    -- PCH file generation loop.

    local pchDir = CacheDirectory
    local genCount, regenCount, failCount = 0, 0, 0

    for _, pchArgs in ipairs(usedPchArgs) do
        local fn = pchArgs[#pchArgs]
        local absFileName = pchDir..'/'..fn
        pchArgs.pchFileName = absFileName

        if (not exists(absFileName)) then
            if (not generatePch(pchArgs)) then
                isPchFileUsed[fn] = false
                failCount = failCount + 1
                goto nextPch
            end

            genCount = genCount + 1
        end

        -- Test usage once. If not successful, the PCH is most likely out of date and needs
        -- to be regenerated.
        local ok = testPch(pchArgs)

        if (not ok) then
            if (not generatePch(pchArgs)) then
                isPchFileUsed[fn] = false
                failCount = failCount + 1
                goto nextPch
            end

            regenCount = regenCount + 1

            if (not testPch(pchArgs)) then
                errorInfo("Auto-PCH: regenerated PCH file\
  %s\
did not successfully pass test usage with an empty C++ source file.", fn)
                exitRequestingBugReport()
            end
        end

        ::nextPch::
    end

    if (genCount == 0 and regenCount == 0) then
        info("Auto-PCH: all existing PCH files are up to date.")
    else
        info("Auto-PCH: generated %s%s.",
             pluralize(genCount, "PCH file"),
             regenCount > 0 and format(", regenerated %d", regenCount) or "")
    end

    if (failCount > 0 and not opts.v) then
        warnInfo("Auto-PCH: generation of %s failed. Use -v for details.",
                 pluralize(failCount, "PCH file"))
    end

    -- Attach the PCH file name to compile commands that are going to be PCH-enabled.

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

----------

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

---------- SymbolIndex ----------

local SymbolInfo = ffi.typeof[[struct {
    uint64_t intFlags;  // intrinsic flags (identifying a particular symbol)
    uint64_t extFlags;  // extrinsic flags (describing a particular symbol use)
}]]

local SymbolInfoPage = (function()
    local pageSize = posix.sysconf(posix._SC.PAGESIZE)
    assert(pageSize % ffi.sizeof(SymbolInfo) == 0)
    return ffi.typeof("$ [$]", SymbolInfo, pageSize / ffi.sizeof(SymbolInfo))
end)()

local MaxSymPages = {
    Local = (ffi.abi("64bit") and 1*2^30 or 128*2^20) / ffi.sizeof(SymbolInfoPage),
    Global = (ffi.abi("64bit") and 4*2^30 or 512*2^20) / ffi.sizeof(SymbolInfoPage),
}

local SymbolIndex = class
{
    function()
        local PROT, MAP, LMAP = posix.PROT, posix.MAP, linux_decls.MAP
        local SymbolInfoPagePtr = ffi.typeof("$ *", SymbolInfoPage)

        local requestSymPages = function(count, flags)
            local voidPtr = posix.mmap(nil, count * ffi.sizeof(SymbolInfoPage),
                                       PROT.READ + PROT.WRITE, flags, -1, 0)
            return ffi.cast(SymbolInfoPagePtr, voidPtr)
        end

        local allLocalPages = {}
        for i = 1, usedConcurrency do
            allLocalPages[i] = requestSymPages(MaxSymPages.Local, MAP.SHARED + LMAP.ANONYMOUS)
        end

        return {
            globalPages = requestSymPages(MaxSymPages.Global, MAP.PRIVATE + LMAP.ANONYMOUS),
            allLocalPages = allLocalPages,
        }
    end,
}

---------- Main ----------

local function DoProcessCompileCommand(cmd, parseOptions)
    local fileExists, msg = exists(cmd.file)
    if (not fileExists) then
        return nil, msg
    end

    local args = util.copySequence(cmd.arguments)

    -- TODO: catch a possible error at this stage.
    if (cmd.pchFileName ~= nil) then
        table.insert(args, 1, "-include-pch")
        table.insert(args, 2, cmd.pchFileName)
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

local function ProcessCompileCommand(ccIndex, parseOptions)
    local tu, errorCodeOrString
    local formattedDiagSet

    tu, errorCodeOrString = DoProcessCompileCommand(
        compileCommands[ccIndex], parseOptions)

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

    local inclusionGraph = (tu ~= nil) and
        InclusionGraph_ProcessTU(InclusionGraph(), tu) or
        InclusionGraph()

    -- Make LuaJIT release libclang-allocated TU memory.
    tu = nil
    collectgarbage()

    assert(formattedDiagSet ~= nil and inclusionGraph ~= nil)
    return formattedDiagSet, inclusionGraph
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
            self.formattedDiagSets[i], self.inclusionGraphs[i] =
                ProcessCompileCommand(self.ccIndexes[i], self.parseOptions)
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

local function GetNewCcIndexes(ccInclusionGraphs, eventFileNames,
                               processedCommandCount, oldCcIdxs)
    assert(processedCommandCount <= #oldCcIdxs)

    -- [SEQ_REAP] In command mode, we are not necessarily reaping the results sequentially
    -- because we can prioritize compile commands much later than the current "head"!
    -- However, in human mode we do: using '#' (the length operator), we depend on the
    -- sequence table having no "holes".
    local ccEndIdx = commandMode and #compileCommands or #ccInclusionGraphs

    if (not commandMode) then
        assert(ccEndIdx <= #compileCommands)
        for ccIdx = 1, #compileCommands do
            assert((ccInclusionGraphs[ccIdx] ~= nil) == (ccIdx <= ccEndIdx))
        end
    end

    local isCompileCommandAffected = function(ccIdx)
        local incGraph = ccInclusionGraphs[ccIdx]
        if (incGraph == nil) then
            assert(commandMode)
            return false
        end

        for i = 1, #eventFileNames do
            if (incGraph:getNode(eventFileNames[i]) ~= nil) then
                return true
            end
        end

        return false
    end

    local indexes, affectedIndexes = {}, {}

    -- 1. compile commands affected by the files on which we had a watch event.
    for ccIdx = 1, ccEndIdx do
        if (isCompileCommandAffected(ccIdx)) then
            affectedIndexes[#affectedIndexes + 1] = ccIdx
            indexes[#indexes + 1] = ccIdx
        end
    end

    -- 2. compile commands left over if we stopped early in incremental mode or due to a
    --  detected file change. (Also see NOTE STOPPED_EARLY.)
    if (processedCommandCount < #oldCcIdxs) then
        for i = processedCommandCount, #oldCcIdxs do
            indexes[#indexes + 1] = oldCcIdxs[i]
        end
    end

    -- Now, sort+uniquify the two compile command index sequences, for the assert in checkCcIdxs_().
    -- Violation can only happen if we stopped early on a re-process that was due to an early stop.
    -- (Because we get the same compile command twice -- once from 1. and once from 2.)
    --
    -- In command mode where there is no guarantee of sequentiality things get even more
    -- complicated. Note that 'processedCommandCount' is a conservative figure in the
    -- command mode case: we might have actually already handled a compile command we would
    -- now have re-processed again, but deviating into this direction is OK. (Wrongly not
    -- re-processing is not OK.)
    --
    -- TODO: rewrite to pass (conceptually) a set of indexes of handled compile commands?
    --  Get rid of the sequentiality requirement altogether?
    table.sort(indexes)

    local newIndexes = {}

    for _, ccIdx in ipairs(indexes) do
        if (newIndexes[#newIndexes] ~= ccIdx) then
            newIndexes[#newIndexes + 1] = ccIdx
        end
    end

    if (commandMode) then
        -- Put the compile commands affected by a file change to the front.
        local cmNewIndexes = util.copySequence(affectedIndexes)

        for _, ccIdx in ipairs(newIndexes) do
            if (not isCompileCommandAffected(ccIdx)) then
                cmNewIndexes[#cmNewIndexes + 1] = ccIdx
            end
        end

        newIndexes = cmNewIndexes
    end

    return newIndexes, affectedIndexes, #oldCcIdxs - processedCommandCount
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

local function getCcIdxString(ccIndex)
    local selInfo = selectionInfo
    local originalCcIndex = selInfo.indexMap[ccIndex] or ccIndex
    local printLocalIdx = (selInfo.haveFileSelection or not selInfo.isContiguous)

    return format("%s%d",
                  printLocalIdx and "s" or "#",
                  printLocalIdx and ccIndex or originalCcIndex)
end

FormattedDiagSetPrinter = class
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
            local str = fDiag:getString(not plainMode)
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
            toPrint[#toPrint+1] = format("%s", info:getString(not plainMode))
        end

        return toPrint
    end,

    emulatePrint = function(self, keepColors, ...)
        local oldGlobals = { plainMode, printProgressAfterSeconds, printProgressAfterCcCount }
        -- Set up (1) no colors and (2) printing for each compile command, even if it has no
        -- diagnostics.
        plainMode, printProgressAfterSeconds, printProgressAfterCcCount = not keepColors, nil, 0

        local lines = {}
        local capturePrintf = function(fmt, ...)
            lines[#lines + 1] = format(fmt, ...)
        end

        self:print(capturePrintf, ...)

        plainMode, printProgressAfterSeconds, printProgressAfterCcCount = unpack(oldGlobals, 1, 3)

        return table.concat(lines, '\n')
    end,

    print = function(self, printfFunc, formattedDiagSet, ccIndex)
        local toPrint = self:getStringsToPrint_(formattedDiagSet)
        local pSecs, pCount = printProgressAfterSeconds, printProgressAfterCcCount

        local shouldPrint = (#toPrint > 0) or
            pSecs ~= nil and os.difftime(os.time(), self.lastProgressPrintTime) >= pSecs or
            -- NOTE [MONOTONIC_PRINT]: in command mode, the sequence of 'ccIndex'es is not
            --  necessarily monotonic. A large one (for a command that got prioritized)
            --  would suppress progress printing until commands with larger indexes or
            --  diagnostics.
            pCount ~= nil and ccIndex - self.lastProgressPrintCcIndex >= pCount

        if (shouldPrint) then
            local cmd = compileCommands[ccIndex]
            local prefix = format("Command %s:", getCcIdxString(ccIndex))
            local middle = getFileOrdinalText(cmd, ccIndex)
            local suffix = (#toPrint > 0) and "" or " ["..colorize("progress", Col.Green).."]"

            printfFunc("%s %s%s%s",
                       colorize(prefix, Col.Bold..Col.Uline..Col.Green),
                       middle,
                       colorize(cmd.file, Col.Bold..Col.Green),
                       suffix)

            if (#toPrint > 0) then
                printfFunc("%s\n", table.concat(toPrint, '\n'))
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

    check_ = function(self)
        assert(self.inotifier ~= nil)

        local events = self.inotifier:waitForEvents()
        for i = 1, #events do
            self:checkEvent_(events[i])
        end
        return events
    end,

    close = function(self)
        self.inotifier:close()
        self.inotifier = nil
    end,

    checkEvent_ = function(self, event)
        if (bit.band(event.mask, MOVE_OR_DELETE) ~= 0) then
            -- TODO: handle. Happens with e.g. 'git stash pop'.
            errprintf("Exiting: a watched file was moved or deleted. (Handling not implemented.)")
            os.exit(ErrorCode.WatchedFileMovedOrDeleted)
        end

        if (event.wd == self.compileCommandsWd) then
            errprintf("Exiting: an event was generated for '%s'. (Handling not implemented.)",
                      compileCommandsFile)
            os.exit(ErrorCode.CompileCommandsJsonGeneratedEvent)
        end
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
    -- <members>: table of certain members that can be taken over from run to run.
    function(members, ...)
        return {
            onDemandParserArgs = { ... },

            -- Will be 'child' or 'parent' after forking:
            whoami = "unforked",

            -- Will be closed and nil'd in child.
            notifier = members.notifier or Notifier(),

            -- Will be nil'd in child.
            symbolIndex = SymbolIndex(),

            --== Child will have:
            parser = nil,  -- OnDemandParser
            connection = nil,  -- Connection

            --== Parent will have:
            -- Table of Connection instances, with possible holes. Indexed by the 'connection index'.
            connections = nil,
            -- Table (read file descriptor -> index into self.connections[]).
            readFdToConnIdx = nil,
            -- Contiguous sequence table as argument to posix.poll().
            pendingFds = nil,
            -- FormattedDiagSetPrinter:
            printer = nil,
            -- Will be filled only in command mode:
            miFormattedDiagSets = members.miFormattedDiagSets or {},
        }
    end,

    is = function(self, who)
        return (self.whoami == who)
    end,

    --== Child only ==--

    send = function(self, obj)
        return self.connection.w:write(obj)
    end,

    sendToParent = function(self, fDiagSet, incGraph)
        local fDiagsStr = fDiagSet:serialize()
        local graphStr = incGraph:serialize()
        local header = DoneHeader_t(#fDiagsStr, #graphStr)
        self:send(header)
        self:send(fDiagsStr)
        self:send(graphStr)
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
        return conn.r:readInto(cdata, false)
    end,

    getConnectionAndCcIdx = function(self, connIdx)
        local conn = self.connections[connIdx]
        return conn, conn.compileCommandIndex
    end,

    closeConnection = function(self, connIdx)
        local conn, ccIdx = self:getConnectionAndCcIdx(connIdx)
        local readFd = conn.r.fd

        conn:close()

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
            self.symbolIndex = nil
            self.parser = OnDemandParser({ccIdx}, unpack(self.onDemandParserArgs, 2))
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

    isOutstanding = function(self, ccIdxToCheck)
        for _, readFd in ipairs(self.pendingFds) do
            local _, ccIdx = self:getConnectionAndCcIdx(self.readFdToConnIdx[readFd])
            if (ccIdx == ccIdxToCheck) then
                return true
            end
        end

        return false
    end,

    -- TODO: watch inotify descriptor, too.
    wait = function(self)
        assert(self:is("parent"))

        local pendingFds = self.pendingFds
        local oldPendingFdCount = #pendingFds

        local inotifyFd = self.notifier:getRawFd()
        local clientInotifyFd = commandMode and mi.clientInotifier:getRawFd() or nil

        pendingFds[#pendingFds + 1] = inotifyFd
        pendingFds[#pendingFds + 1] = clientInotifyFd

        local pollfds = posix.poll(pendingFds)

        pendingFds[oldPendingFdCount + 2] = nil
        pendingFds[oldPendingFdCount + 1] = nil

        local connIdxs = {}
        local haveInotifyFd, haveClientRequest = false, false

        for i = 1, #pollfds do
            -- We should never get:
            --  - POLL.HUP: we (the parent) keep the write end of the 'child -> parent'
            --      connection open just so that the pipe is always connected.
            --  - POLL.NVAL: we should always pass valid pipe file descriptors to poll().
            --
            -- TODO: deal with possible POLL.ERR?
            assert(pollfds[i].revents == POLL.IN)

            local fd = pollfds[i].fd

            if (fd == clientInotifyFd) then
                haveClientRequest = true
            else
                local connIdx = (fd == inotifyFd) and INOTIFY_FD_MARKER or self.readFdToConnIdx[fd]
                assert(connIdx ~= nil)

                haveInotifyFd = haveInotifyFd or (fd == inotifyFd)
                connIdxs[#connIdxs + 1] = connIdx
            end
        end

        return connIdxs, haveInotifyFd, haveClientRequest
    end,

    --== Main path ==--

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
        local ccIdxs = self.onDemandParserArgs[1]
        assert(type(ccIdxs) == "table")
        return commandMode and ccIdxs or self:checkCcIdxs_(ccIdxs)
    end,

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
        local formattedDiagSets = {}  -- in command mode, only used for control flow

        local lastCcIdxToPrint = math.huge
        local hadInotifyFd = false

        local prioritizeCcFunc = function(ccIdxToBump)
            -- TODO: wait for the compile command to process, only then send the result.
            for i = ii, #ccIdxs do
                if (ccIdxs[i] == ccIdxToBump) then
                    -- NOTE: this makes 'ccIdxs' non-monotonic when i > ii.
                    table.remove(ccIdxs, i)
                    table.insert(ccIdxs, ii, ccIdxToBump)
                    miInfo("Prioritized compile command %s.", getCcIdxString(ccIdxToBump))
                    return
                end
            end

            -- A prioritize request must be for a compile command that is to be processed,
            -- but has not yet been.
            assert(self:isOutstanding(ccIdxToBump))
        end

        repeat
            local connIdxs, haveInotifyFd, haveClientRequest = self:wait()
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

            -- Now, for each ready child, receive and handle the data it sent.
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

                local fDiagSet = diagnostics_util.FormattedDiagSet_Deserialize(
                    serializedDiags, not plainMode)
                assert(fDiagSet ~= nil)

                formattedDiagSets[ccIdx] = fDiagSet;

                -- TODO: immediately add files to the include graph here? (We are already
                --  effectively doing this in command mode, but not otherwise. In human mode
                --  we depend on 'ccInclusionGraphs' being a hole-less sequence: SEQ_REAP.)
                ccInclusionGraphs[ccIdx] = inclusion_graph.Deserialize(serializedGraph)

                if (commandMode) then
                    self.miFormattedDiagSets[ccIdx] = fDiagSet
                    self.notifier:addFilesFromGraph(ccInclusionGraphs[ccIdx])
                    -- Print diagnostic set immediately on arrival.
                    self.printer:print(errprintf, fDiagSet, ccIdx)
                elseif (incrementalMode ~= nil) then
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

            -- In human mode, print diagnostic sets in compile command order.
            -- In command mode, run the loop only to update 'firstUnprocessedIdx'
            -- which is returned later.
            for idx = firstUnprocessedIdx, #ccIdxs do
                local ccIdx = ccIdxs[idx]
                local fDiagSet = formattedDiagSets[ccIdx]
                formattedDiagSets[ccIdx] = nil

                if (fDiagSet == nil) then
                    break
                elseif (ccIdx <= lastCcIdxToPrint) then
                    if (not commandMode) then
                        self.notifier:addFilesFromGraph(ccInclusionGraphs[ccIdx])
                        self.printer:print(errprintf, fDiagSet, ccIdx)
                    end
                    firstUnprocessedIdx = firstUnprocessedIdx + 1
                end
            end

            if (haveClientRequest) then
                -- Handle client requests that arrived in between processing child results.
                MI.HandleClientRequests{self, prioritizeCcFunc}
            end
        until (not self:haveActiveChildren())

        self.printer:printTrailingInfo()

        local earlyStopReason = hadInotifyFd or incrementalMode
        assert(not earlyStopReason and spawnCount == #ccIdxs or
                   earlyStopReason and spawnCount <= #ccIdxs)

        return ParentMarker, firstUnprocessedIdx - 1
    end,

    printDiagnostics = function(self, ccInclusionGraphs)
        local marker, processedCcCount = self:setupConcurrency(ccInclusionGraphs)
        if (not marker:isChild()) then
            return processedCcCount
        end

        assert(self:is("child"))

        local iterationCount = 0

        for i, ccIndex, fDiagSet, incGraph in self.parser:iterate() do
            iterationCount = iterationCount + 1
            assert((i == 1) == (iterationCount == 1))

            self:sendToParent(fDiagSet, incGraph)
        end

        assert(iterationCount == 1)
        os.exit(0)
    end,
}

local function PrintInitialInfo()
    local prefix = pluralize(#compileCommands, "compile command")
    local middle = (#selectionSpecs > 0) and
        format(" (of %d)", selectionInfo.originalCcCount) or ""
    local suffix =
        format(" with %s", pluralize(usedConcurrency, "worker process", "es"))
    info("Processing %s%s%s.", prefix, middle, suffix)

    if (selectionInfo.haveFileSelection) then
        local sel = selectionInfo.indexMap
        info("(%s compile commands in the range #%d-#%d.)",
             selectionInfo.isContiguous and "All" or "A subset of", sel[1], sel[#sel])
    end
end

local function SetSigintHandler()
    -- Set SIGINT handling to default (that is, to terminate the receiving process)
    -- instead of the Lua debug hook set by LuaJIT in order to avoid being spammed
    -- with backtraces from the child processes.
    local SIG = posix.SIG
    posix.signal(SIG.INT, SIG.DFL)
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

local function Poll(spec)
    local isReady = {}
    local pollfds = posix.poll(spec)

    for _, event in ipairs(pollfds) do
        assert(event.revents == POLL.IN)  -- TODO: handle POLL.ERR?
        isReady[event.fd] = true
    end

    return isReady
end

local function main()
    PrintInitialInfo()
    SetSigintHandler()

    local startTime = os.time()

    -- Inclusion graphs for each compile command.
    local ccInclusionGraphs = {}

    local parserOpts = printGraphMode and {"SkipFunctionBodies", "Incomplete"} or {}
    local control = Controller({}, range(#compileCommands), parserOpts)

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

        if (commandMode) then
            local fileInotifyFd = notifier:getRawFd()
            local clientInotifyFd = mi.clientInotifier:getRawFd()

            repeat
                -- Wait for either changes to files or client requests.
                local isReady = Poll({events=POLL.IN, fileInotifyFd, clientInotifyFd})

                if (isReady[clientInotifyFd]) then
                    MI.HandleClientRequests{control, function(_)
                        -- A prioritize request can only happen while processing.
                        assert(false)
                    end}
                end
            until (isReady[fileInotifyFd])
        end

        -- Wait for and react to changes to watched files. In command mode, the waiting part
        -- has already been accomplished (see above).
        local events = notifier:check_()
        local eventFileNames = {}
        for _, event in ipairs(events) do
            eventFileNames[#eventFileNames + 1] = notifier:getFileName(event)
        end

        -- Determine the set of compile commands to re-process.
        local newCcIdxs, affectedCcIdxs, earlyStopCount = GetNewCcIndexes(
            ccInclusionGraphs, eventFileNames,
            processedCommandCount, currentCcIdxs)

        local getFileStr = function(i)
            return colorize(eventFileNames[i], Col.Bold..Col.White)
        end

        local modifiedFilesStr =
            (#eventFileNames == 1) and getFileStr(1) or
            (#eventFileNames == 2) and format("%s and %s", getFileStr(1), getFileStr(2)) or
            format("%s and %d more files", getFileStr(1), #eventFileNames - 1)

        info("Detected modification of %s. Processing %s%s.",
             modifiedFilesStr,
             pluralize(#newCcIdxs, "compile command"),
             earlyStopCount > 0 and format(" (including %d due to prior early stop)", earlyStopCount) or "")

        -- Finally, re-process them.

        local filter = function(fDiagSets)
            for _, ccIdx in ipairs(newCcIdxs) do
                fDiagSets[ccIdx] = nil
            end
            return fDiagSets
        end

        local membersTakenOver = {
            -- We may not have seen all events that are due to arrive in the immediate
            -- future, so make sure they are not lost.
            notifier = notifier,

            miFormattedDiagSets = filter(control.miFormattedDiagSets),
        }

        for _, ccIdx in ipairs(affectedCcIdxs) do
            -- Clear cached diagnostic sets for the change-affected compile commands.
            membersTakenOver.miFormattedDiagSets[ccIdx] = nil
        end

        startTime = os.time()
        control = Controller(membersTakenOver, newCcIdxs, parserOpts)
    until (false)
end

main()
