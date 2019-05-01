local bit = require("bit")
local ffi = require("ffi")
local io = require("io")
local math = require("math")
local os = require("os")
local string = require("string")
local table = require("table")

local cl = require("ljclang")
local class = require("class").class
local compile_commands_reader = require("compile_commands_reader")
local compile_commands_util = require("compile_commands_util")
local diagnostics_util = require("diagnostics_util")
local hacks = require("hacks")
local posix = require("posix")
local util = require("util")

local POLL = posix.POLL

local inclusion_graph = require("inclusion_graph")
local InclusionGraph = inclusion_graph.InclusionGraph

local Col = require("terminal_colors")

local check = require("error_util").check
local checktype = require("error_util").checktype

local inotify = require("inotify")
local IN = inotify.IN

local assert = assert
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
  -c <concurrency>: set number of parallel parser invocations.
     0 means do everything serially (do not fork),
     'auto' means use hardware concurrency (the default).
  -g [includes|isIncludedBy]: Print inclusion graph as a DOT (of Graphviz) file to stdout and exit.
     Argument specifies the relation between graph nodes (which are file names).
  -l <number>: edge count limit for the graph produced by -g %s.
     If exceeded, a placeholder node is placed.
  -N: Disable omission of repeated diagnostics.
  -P: Disable color output.
  -x: exit after parsing and displaying diagnostics once.
]], GlobalInclusionGraphRelation)
    os.exit(ErrorCode.CommandLine)
end

local parsecmdline = require("parsecmdline_pk")

local opts_meta = {
    c = true,
    m = false,
    g = true,
    l = true,
    N = false,
    P = false,
    x = false,
}

local opts, args = parsecmdline.getopts(opts_meta, arg, usage)

local concurrencyOpt = opts.c or "auto"
local commandMode = opts.m
local printGraphMode = opts.g
local edgeCountLimit = tonumber(opts.l)
local printAllDiags = opts.N
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

local usedConcurrency = getUsedConcurrency()

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

local MOVE_OR_DELETE = bit.bor(IN.MOVE_SELF, IN.DELETE_SELF)
local WATCH_FLAGS = bit.bor(IN.CLOSE_WRITE, MOVE_OR_DELETE)

---------- HUMAN MODE ----------

local function DoProcessCompileCommand(cmd, additionalSystemInclude, parseOptions)
    local args = compile_commands_util.sanitize_args(cmd.arguments, cmd.directory)

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

local function CheckForIncludeError(tu, formattedDiagSet, cmd, additionalIncludeTab)
    if (additionalIncludeTab[1] ~= nil) then
        return
    end

    local plainFormattedDiags = formattedDiagSet:getString(false)

    local haveIncludeErrors =
        (plainFormattedDiags:match("fatal error: ") ~= nil) and
        (plainFormattedDiags:match("'.*' file not found") ~= nil)
    assert(not haveIncludeErrors or (tu ~= nil))

    if (haveIncludeErrors) then
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
    local tu, errorCode
    local additionalIncludeTab = {}
    local count = 0

    local formattedDiagSet
    local hadSomeSystemIncludesAdded = false

    repeat
        count = count + 1
        assert(count <= 2)

        tu, errorCode = DoProcessCompileCommand(
            compileCommands[ccIndex], additionalIncludeTab[2], parseOptions)

        if (tu == nil) then
            formattedDiagSet = diagnostics_util.FormattedDiagSet(not plainMode)
            -- TODO: Extend in verbosity and/or handling?
            formattedDiagSet:setInfo("ERROR: index:parse() failed: "..tostring(errorCode))
        else
            formattedDiagSet = diagnostics_util.GetDiags(tu:diagnosticSet(), not plainMode)
        end

        local retry = CheckForIncludeError(
            tu, formattedDiagSet, compileCommands[ccIndex], additionalIncludeTab)
        hadSomeSystemIncludesAdded = hadSomeSystemIncludesAdded or retry
    until (not retry)

    local inclusionGraph = (tu ~= nil) and
        InclusionGraph_ProcessTU(InclusionGraph(), tu) or
        InclusionGraph()

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

local function GetAffectedCompileCommandIndexes(ccInclusionGraphs, eventFileName)
    local indexes = {}

    for i = 1, #compileCommands do
        if (ccInclusionGraphs[i]:getNode(eventFileName) ~= nil) then
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
        and colorize(format("[%d/%d] ", ord, fileCount),
                     Col.Bold..Col.Yellow)
        or ""
end

local function getNormalizedDiag(diagStr)
    -- TODO: inform user about the number of different sites that the diagnostics came from.
    return diagStr:gsub("In file included from [^\n]*\n", "")
end

local function pluralize(count, noun, pluralSuffix)
    pluralSuffix = pluralSuffix or 's'
    return format("%d %s%s", count, noun, count > 1 and pluralSuffix or "")
end

local FormattedDiagSetPrinter = class
{
    function()
        return {
            seenDiags = {},
            numCommandsWithOmittedDiags = 0,
            totalOmittedDiagCount = 0,
        }
    end,

    getStringsToPrint_ = function(self, formattedDiagSet)
        local toPrint = {
            omittedDiagCount = 0,
        }

        if (formattedDiagSet:isEmpty()) then
            return toPrint
        end

        local newSeenDiags = {}
        local omittedLastDiag = false

        local fDiags = formattedDiagSet:getDiags()

        for i, fDiag in ipairs(fDiags) do
            local str = fDiag:getString(true)
            local normStr = getNormalizedDiag(str)

            if (printAllDiags or not self.seenDiags[normStr]) then
                newSeenDiags[#newSeenDiags + 1] = normStr
                toPrint[#toPrint+1] = format("%s%s", (i == 1) and "" or "\n", str)
            else
                toPrint.omittedDiagCount = toPrint.omittedDiagCount + 1
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

        if (#toPrint > 0) then
            local cmd = compileCommands[ccIndex]

            local prefix = format("Command #%d:", ccIndex)
            local middle = getFileOrdinalText(cmd, ccIndex)

            errprintf("%s %s%s",
                      colorize(prefix, Col.Bold..Col.Uline..Col.Green),
                      middle,
                      colorize(cmd.file, Col.Bold..Col.Green))

            errprintf("%s\n", table.concat(toPrint, '\n'))
        end

        if (toPrint.omittedDiagCount > 0) then
            self.numCommandsWithOmittedDiags = self.numCommandsWithOmittedDiags + 1
            self.totalOmittedDiagCount = self.totalOmittedDiagCount + toPrint.omittedDiagCount
        end
    end,

    printTrailingInfo = function(self)
        if (self.numCommandsWithOmittedDiags > 0) then
            errprintf(
                "%s: omitted %s from %s.",
                colorize("NOTE", Col.Bold..Col.Blue),
                pluralize(self.totalOmittedDiagCount, "repeated diagnostic"),
                pluralize(self.numCommandsWithOmittedDiags, "command"))
        end
    end,
}

-- For clearer exposition only.
local FdPair = class
{
    function(readFd, writeFd, extraFd)
        return {
            r = readFd,
            w = writeFd,

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

    getUsedEnds = function(self, whoami)
        assert(whoami == "child" or whoami == "parent")

        if (whoami == "child") then
            self.toParent.r:close()
            self.toChild.w:close()
            return FdPair(self.toChild.r, self.toParent.w)
        else
            -- NOTE: deliberately keep open the write end of the 'child -> parent'
            -- connection in the parent so that we never get POLL.HUP from poll().
            --[[self.toParent.w:close()--]]
            self.toChild.r:close()
            return FdPair(self.toParent.r, self.toChild.w,
                          self.toParent.w)
        end
    end,
}

local Message = {
    Ready = "R",   -- 1: child -> parent
    Clear = "C",   -- 2: parent -> child
    Done = "Done", -- 3: child -> parent
}

local DoneHeader_t = class
{
    "char magic[4];"..
    "uint32_t length;",

    __new = function(ct, length)
        -- NOTE: 'magic' deliberately not zero-terminated. See
        -- http://lua-users.org/lists/lua-l/2011-01/msg01457.html
        return ffi.new(ct, Message.Done, length)
    end,

    deserialize = function(self)
        return {
            magic = ffi.string(self.magic, 4),
            length = tonumber(self.length),
        }
    end,
}

local Controller = class
{
    function(...)
        return {
            onDemandParserArgs = { ... },

            -- If concurrency is requested, will be 'child' or 'parent' after forking:
            whoami = "unforked",

            -- Child or unforked will have:
            parser = nil,  -- OnDemandParser
            printer = nil,  -- FormattedDiagSetPrinter

            -- Child will have:
            connection = nil,  -- FdPair

            --== Parent will have:
            -- Table of FdPair elements with possible holes. Indexed by the 'connection index'.
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

    onBeforePrint = function(self)
        assert(not self:is("parent"))

        if (self:is("child")) then
            self:send(Message.Ready)
            local msg = self:receive()
            assert(msg == Message.Clear)
        end
    end,

    onAfterPrint = function(self, incGraph)
        assert(not self:is("parent"))

        if (self:is("child")) then
            local graphStr = incGraph:serialize()
            local header = DoneHeader_t(#graphStr)
            self:send(header)
            self:send(graphStr)
        end
    end,

    --== Unforked or parent ==--

    setupParserAndPrinter = function(self, ...)
        self.parser = OnDemandParser(...)
        self.onDemandParserArgs = nil
        self.printer = FormattedDiagSetPrinter()
    end,

    getAdditionalInfo = function(self)
        if (self:is("unforked")) then
            return self.parser:getAdditionalInfo()
        end
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

        assert(self.readFdToConnIdx[readFd] == connIdx)
        self.readFdToConnIdx[readFd] = nil

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

        self.whoami = posix.fork()

        local connection = pipes:getUsedEnds(self.whoami)

        if (self:is("child")) then
            self.connection = connection
            self:setupParserAndPrinter({ccIdx}, unpack(self.onDemandParserArgs, 2))
            return true
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
    end,

    -- TODO: watch inotify descriptor, too.
    wait = function(self)
        assert(self:is("parent"))

        local pollfds = posix.poll(self.pendingFds)
        local connIdxs = {}

        for i = 1, #pollfds do
            -- We should never get:
            --  - POLL.HUP: we (the parent) keep the write end of the 'child -> parent'
            --      connection open just so that the pipe is always connected.
            --  - POLL.NVAL: we should always valid pipe file descriptors to poll().
            --
            -- TODO: deal with possible POLL.ERR?
            assert(pollfds[i].revents == POLL.IN)

            local connIdx = self.readFdToConnIdx[pollfds[i].fd]
            assert(connIdx ~= nil)
            connIdxs[i] = connIdx
        end

        return connIdxs
    end,

    --== Unforked only ==--

    setupConcurrency = function(self, ccInclusionGraphs)
        local ccIdxs = self.onDemandParserArgs[1]
        local localConcurrency = math.min(usedConcurrency, #ccIdxs)
        local spawnCount = 0

        -- Spawn the initial batch of children.
        for ii = 1, localConcurrency do
            spawnCount = spawnCount + 1
            if (self:spawnChild(ccIdxs[ii])) then
                return true
            end
        end

        local ii = localConcurrency + 1

        repeat
            local connIdxs = self:wait()
            local newChildCount = #connIdxs

            -- To retain the requested concurrency, spawn as many new children as we were
            -- informed are ready.
            while (newChildCount > 0 and ii <= #ccIdxs) do
                spawnCount = spawnCount + 1
                if (self:spawnChild(ccIdxs[ii])) then
                    return true
                end

                newChildCount = newChildCount - 1
                ii = ii + 1
            end

            -- Now, for each ready child in turn, first inform it that it can go ahead
            -- printing and then wait for it to complete that.
            for _, connIdx in ipairs(connIdxs) do
                local readyMsg = self:receiveString(connIdx, 1)
                assert(readyMsg == Message.Ready)

                self:sendTo(connIdx, Message.Clear)

                local doneMsg = self:receiveData(connIdx, DoneHeader_t(0)):deserialize()
                assert(doneMsg.magic == Message.Done)

                local serializedGraph = self:receiveString(connIdx, doneMsg.length)

                -- NOTE: may introduce holes in the (integer) key sequence of
                -- self.connections[].
                local ccIdx = self:closeConnection(connIdx)

                ccInclusionGraphs[ccIdx] = inclusion_graph.Deserialize(serializedGraph)
            end
        until (not self:haveActiveChildren())

        assert(spawnCount == #ccIdxs)
    end,

    printDiagnostics = function(self, ccInclusionGraphs)
        local compileCommandCount = #self.onDemandParserArgs[1]

        if (usedConcurrency == 0) then
            self:setupParserAndPrinter(unpack(self.onDemandParserArgs))
        else
            if (not self:setupConcurrency(ccInclusionGraphs)) then
                return compileCommandCount
            end
        end

        local iterationCount = 0
        local inclusionGraph

        for i, ccIndex, fDiagSet, incGraph in self.parser:iterate() do
            iterationCount = iterationCount + 1
            assert((i == 1) == (iterationCount == 1))

            if (i == 1) then
                self:onBeforePrint()
            end

            self.printer:print(fDiagSet, ccIndex)

            inclusionGraph = incGraph
            ccInclusionGraphs[ccIndex] = incGraph
        end

        assert(iterationCount >= 1)
        assert(not self:is("child") or iterationCount == 1)

        self.printer:printTrailingInfo()
        self:onAfterPrint(inclusionGraph)

        if (self:is("child")) then
            os.exit(0)
        end

        return compileCommandCount
    end,
}

local function PrintInitialInfo()
    local prefix = pluralize(#compileCommands, "compile command")
    local suffix = (usedConcurrency > 0) and
        format(" with %s", pluralize(usedConcurrency, "worker process", "es")) or ""
    info("Processing %s%s.", prefix, suffix)
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

local function humanModeMain()
    PrintInitialInfo()
    SetSigintHandler()

    local startTime = os.time()

    -- Inclusion graphs for each compile command.
    local ccInclusionGraphs = {}

    local parserOpts = printGraphMode and {"SkipFunctionBodies", "Incomplete"} or {}
    local control = Controller(range(#compileCommands), parserOpts)

    local notifier, fileNameOfWd, compileCommandsWd

    repeat
        -- Print current diagnostics.
        -- TODO: think about handling case when files change more properly.
        -- TODO: in particular, moves and deletions. (Have common logic with compile_commands.json change?)
        -- Later: handle special case of a change of compile_commands.json, too.

        local processedCommandCount = control:printDiagnostics(ccInclusionGraphs)

        -- TODO: move to separate application
        if (printGraphMode ~= nil) then
            local graph = GetGlobalInclusionGraph(#compileCommands, ccInclusionGraphs)
            PrintInclusionGraphAsGraphvizDot(graph)
            -- TODO: see if there were errors, actually. After all, there may have been
            -- #include errors!
        end

        if (notifier == nil and not exitImmediately) then
            local graph = GetGlobalInclusionGraph(#compileCommands, ccInclusionGraphs)
            notifier, fileNameOfWd, compileCommandsWd = AddFileWatches(graph)
            info("Watching %d files.", graph:getNodeCount() + 1)
        end

        if (control:getAdditionalInfo() ~= nil) then
            info("%s", control:getAdditionalInfo())
        end
        info_underline("Processed %s in %d seconds.",
                       pluralize(processedCommandCount, "compile command"),
                       os.difftime(os.time(), startTime))
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
        local ccIndexes = GetAffectedCompileCommandIndexes(
            ccInclusionGraphs, eventFileName)

        info("Detected modification of %s. Need re-processing %s.",
             colorize(eventFileName, Col.Bold..Col.White),
             pluralize(#ccIndexes, "compile command"))

        -- Finally, re-process them.
        control = Controller(ccIndexes, parserOpts)
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
