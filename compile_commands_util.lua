local check = require("error_util").check
local LangOptions = require("dev.PchRelevantLangOptions")

local io = require("io")
local os = require("os")
local math = require("math")
local table = require("table")

local util = require("util")

local assert = assert
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local type = type

----------

local api = {}

function api.absify(filename, directory)
    local isAbsolute = (filename:sub(1,1) == "/")  -- XXX: Windows
    return isAbsolute and filename or directory.."/"..filename
end

-- Make "-Irelative/subdir" -> "-I/path/to/relative/subdir",
-- <args> is modified in-place.
local function absifyIncludeOptions(args, prefixDir)
    for i=1,#args do
        local arg = args[i]
        if (arg:sub(1,2)=="-I") then
            args[i] = "-I"..api.absify(arg:sub(3), prefixDir)
        end
    end

    return args
end

local function checkStripArg(arg)
    local IsFixedArgToStrip = {
        ["-c"] = true,
        ["-o"] = true,  -- NOTE: stripping the argument is handled at the usage site.
    }

    return IsFixedArgToStrip[arg]
        -- Strip some PCH-relevant options that are not relevant for us.
        or arg:find("^-O")
        or arg:find("^-fcomment-block-commands=")
        -- TODO: are there compile-time diagnostics from any of the sanitizers possible?
        --  Also research meaning of comments in the Clang source stating that some
        --  sanitizers may affect preprocessing.
        or arg:find("^-fsanitize=")
end

-- Returns: sequence table with compiler arguments to generate a PCH, or error string.
-- The table has the PCH file name (only basename) as the last value.
local function getPchGenArgs(args)
    -- NOTE: this is true for non-Android Linux, according to
    -- Linux::GetDefaultCXXStdlibType() in LLVM's clang/lib/Driver/ToolChains/Linux.cpp
    local SystemDefaultStdLib = "libstdc++"

    local cxxStd, stdLib = nil, SystemDefaultStdLib

    -- Reference: LLVM's
    -- clang/include/clang/Basic/DiagnosticSerializationKinds.td
    -- clang/include/clang/Basic/LangOptions.def
    -- clang/lib/Serialization/ASTReader.cpp
    --   See "PCH validator implementation".
    -- clang/docs/ClangCommandLineReference.rst

    -- Do we have characters that are not valid in a file name?
    local haveBadChars = false

    local checkString = function(str)
        haveBadChars = haveBadChars or (str:match('/') ~= nil)
        return str
    end

    -- { <langOptKey> = true/false/value }
    -- Only values that are non-default (for options whose default is known) will remain.
    local langOptValues = {}

    -- Dependent options and/or those we do not know the default of. These are simply collected.
    local optSeq = {}

    for i = 1, #args do
        local arg = args[i]

        -- NOTE: see CAUTION LUA_PATTERN.
        -- NOTE: with multiple occurrences of the the same option, the last occurrence wins:
        -- same behavior as GCC or Clang.
        if (arg == "-ansi") then
            cxxStd = "c++03"
        elseif (arg:find("^-std=")) then
            cxxStd = checkString(arg:sub(#"^-std="))
        elseif (arg:find("^-[DU]_")) then
            -- Collect macro (un)definitions starting with an underscore, as these might
            -- have consequences on conditional compilation in one or more standard library
            -- headers. Note that such definitions would cleanly be only allowed to "the
            -- implementation": otherwise, C++17 20.5.4.3.2 [macro.names] restricts *any*
            -- attempt at hooking into standard libraries via the preprocessor. For example,
            -- building LLVM on Linux has this:
            --  -D_GNU_SOURCE -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS
            optSeq[#optSeq + 1] = arg
        elseif (arg:find("^-stdlib=")) then
            stdLib = checkString(arg:sub(#"^-stdlib="))

            -- NOTE: LLVM's clang/lib/Driver/ToolChain.cpp has
            --   // Only use "platform" in tests to override CLANG_DEFAULT_CXX_STDLIB!
            -- But, nothing prevents it from being passed in general.
            if (stdLib == "platform") then
                stdLib = SystemDefaultStdLib
            end
        else
            -- LangOpts handling

            local argUptoEq = arg:match("^-f.-=")  -- NOTE: match *shortest* sequence up to '='
            local isNegative = arg:match("^-fno%-")

            local key = argUptoEq
                or (isNegative and arg:gsub("^-fno%-", "-f"))
                or arg

            local langOptIdx = LangOptions.ArgToOptIdx[key]

            if (langOptIdx ~= nil) then
                -- Encountered a PCH-relevant option.
                local opt = LangOptions.Opts[langOptIdx]
                local defaultValue, abbrev = opt[3], opt[4]

                if (type(defaultValue) == "boolean") then
                    local value = (not isNegative)
                    if (value ~= defaultValue) then
                        langOptValues[key] = value
                    else
                        langOptValues[key] = nil
                    end
                elseif (type(defaultValue) == "string" or type(defaultValue) == "number") then
                    assert(argUptoEq)
                    local value = checkString(arg:sub(#argUptoEq + 1))
                    langOptValues[key] = (value ~= tostring(defaultValue)) and value or nil
                else
                    assert(type(defaultValue) == "table")

                    -- Assume that mentioning one and the same option multiple times
                    -- consecutively is the same as mentioning it once, but besides that,
                    -- make no assumptions.
                    if (optSeq[#optSeq] ~= arg) then
                        optSeq[#optSeq + 1] = checkString(arg)
                    end
                end
            end
        end
    end

    -- Make sure this list is exhaustive in excluding C++ before C++11: the list of language
    -- standards supported by clang is in LLVM's clang/include/clang/Frontend/LangStandards.def
    local IsUnsupportedCxxVersion = {
        ["c++98"] = true,
        ["c++03"] = true,
        ["gnu++98"] = true,
        ["gnu++03"] = true,
    }

    -- TODO: use the C++ standard version that the compiler uses by default if not
    -- explicitly specified?
    if (cxxStd == nil
            -- Exclude languages other than C++.
            -- TODO: what about 'openclcpp, "c++"' in LLVM's LangStandards.def?
            or not cxxStd:find("++", 1, true)
            -- Do not support C++ before C++11.
            or IsUnsupportedCxxVersion[cxxStd]) then
        return "unsupported language"
    end

    -- Sort for deterministic order.
    local langOptKeys = {}
    for key, _ in pairs(langOptValues) do
        langOptKeys[#langOptKeys + 1] = key
    end
    table.sort(langOptKeys)

    -- REMEMBER: increment 'V<number>' if the file name format changes.
    local prefixParts = { "allV1", cxxStd, stdLib }

    local middleParts, middleArgs = {}, {}

    for _, key in ipairs(langOptKeys) do
        local langOptIdx = LangOptions.ArgToOptIdx[key]
        local abbrev = LangOptions.Opts[langOptIdx][4]
        local value = langOptValues[key]
        local isBoolean = (type(value) == "boolean")
        assert(abbrev ~= nil)
        assert(isBoolean or type(value) == "string")

        middleParts[#middleParts + 1] = isBoolean and
            abbrev..(value and 'T' or 'F') or
            abbrev.."="..value

        middleArgs[#middleArgs + 1] = isBoolean and
            (value and key or key:gsub("^-f", "-fno-")) or
            (key .. value)
    end

    local suffixParts = optSeq

    local fileName = table.concat(prefixParts, '-')
        ..(#middleParts == 0 and "" or '-'..table.concat(middleParts, '~'))
        -- NOTE: might have an ambiguity if argument value contains '~'. But, such an
        -- argument to any of our '=' options would not be an allowed value. So, don't do
        -- anything about it: the PCH should not compile.
        ..(#suffixParts == 0 and "" or '~'..table.concat(suffixParts, '~'))
        ..".pch"

    local args = {
        "-x", "c++-header",

        "-std="..cxxStd,
        "-stdlib="..stdLib,
    }

    for _, arg in ipairs(middleArgs) do
        args[#args + 1] = arg
    end

    for _, arg in ipairs(optSeq) do
        args[#args + 1] = arg
    end

    args[#args + 1] = "-o"
    args[#args + 1] = fileName  -- file name comes last by our convention

    return args
end

function api.sanitize_args(args, directory)
    check(type(args) == "table", "<args> must be a table", 2)
    check(type(directory) == "string", "<directory> must be a string", 2)

    check(directory:sub(1,1) == "/", "<directory> must start with '/'", 2)  -- XXX: Windows

    local localArgs = {}
    local argCountToIgnore = 0

    for _, arg in ipairs(args) do
        -- NOTE: This is somewhat specific to the watch_compile_commands use case.
        -- TODO: pull out (again)?
        if (argCountToIgnore <= 0 and not checkStripArg(arg)) then
            localArgs[#localArgs + 1] = arg
        end
        argCountToIgnore = (arg == "-o") and 1 or argCountToIgnore - 1
    end

    return absifyIncludeOptions(localArgs, directory), getPchGenArgs(localArgs)
end

----------

-- Preparation: run 'clang -v' on the compile commands. We use it to extact and add to the
-- search path the system include directories added by the Clang driver (see e.g. functions
-- AddClangSystemIncludeArgs() under LLVM's clang/lib/Driver/ToolChains/*.cpp). Omitting this
-- yields include errors on certain system includes. See
-- http://clang.llvm.org/docs/LibTooling.html#builtin-includes

function api.obtainSystemIncludes(clang, concurrency,
                                  compileCommands,  -- elements modified in-place
                                  cacheDirectory, F)
    local ccCount = #compileCommands
    local localConcurrency = math.min(concurrency, ccCount)

    -- Second return value: argument list signature for caching results of computations on
    --  the argument list. Note that this caching only works as long as we do not process
    --  the include dependencies. But, by the time we do, we hopefully have a way of running
    --  this preparation concurrently with the main parsing loop.
    local getArgsAndSig = function(ccIdx)
        local cmd = compileCommands[ccIdx]
        local args = util.copySequence(cmd.arguments)

        -- Get the last dot-separated component as the extension.
        local ext = args[cmd.fileNameIdx]:match("%.([^%.]+)$")

        if (ext ~= nil) then
            -- We do not use the include dependency output, so use an empty dummy file.
            -- (Quick test using all LLVM CCs: 2s vs 8s.)
            local dummyFileName = cacheDirectory..'/empty.'..ext

            -- Create the empty file with the same extension as the source file.
            -- (Since Clang potentially uses the extension to decide for a language.)
            local f = io.open(dummyFileName, 'w') or
                F.errorInfoAndExit("Failed opening '%s'.", dummyFileName)
            f:close()

            args[cmd.fileNameIdx] = dummyFileName
        end

        -- Request verbose information.
        table.insert(args, 1, "-v")
        -- Request header dependency information, running only to the preprocessing stage.
        -- TODO: use the output produced by this.
        table.insert(args, 2, "-MM")
        table.insert(args, 3, "-MG")

        -- Compute arguments' signature, keeping only those on which '-v' output depends.
        -- TODO: likely, this can be made more precise, dropping more irrelevant arguments
        --  than just the file name.
        local sigArgs = util.copySequence(cmd.arguments)
        table.remove(sigArgs, cmd.fileNameIdx)

        -- NOTE: the extension is considered significant to the caching mechanism!
        return args, ext..'\0\0'..table.concat(sigArgs, '\0')
    end

    -- { [<index into compileCommands>] = Callable (blocks until process finishes) }
    local futures = {}
    -- { [<signature>] = false/true }
    local seenSignature = {}
    -- { [<signature>] = <string (output of clang command)> }
    local resultForSignature = {}
    -- { [<index into compileCommands>] = <signature> }
    local signatureForCcIdx = {}

    local spawnWorker = function(ccIdx)
        local args, signature = getArgsAndSig(ccIdx)
        signatureForCcIdx[ccIdx] = signature

        if (seenSignature[signature] == nil) then
            seenSignature[signature] = true
            futures[ccIdx] = F.ExecuteAsync(clang, args)
            return true
        end
    end

    local headCcIdx = 1
    local workerCount = 0

    local spawnWorkers = function()
        while (workerCount < concurrency and headCcIdx <= ccCount) do
            if (spawnWorker(headCcIdx)) then
                workerCount = workerCount + 1
            end
            headCcIdx = headCcIdx + 1
        end
    end

    local getResult = function(ccIdx)
        local future = futures[ccIdx]
        local ccSig = signatureForCcIdx[ccIdx]

        assert((future ~= nil) == (resultForSignature[ccSig] == nil))

        if (future ~= nil) then
            local result = future()
            workerCount = workerCount - 1

            if (result == nil) then
                local argsStr = table.concat((getArgsAndSig(ccIdx)), ' ')
                F.errorInfo("Failed running preparatory step for compile command #%d:\n%s %s",
                          ccIdx, clang, argsStr)
                F.errorInfo("Please make sure that the original compile command invocation succeeds.")
                F.errorInfoAndExit("If the issue persists after that, please report it as a bug.")
            end

            -- Retain the requested concurrency.
            spawnWorkers()

            -- Cache the result.
            resultForSignature[ccSig] = result
        end

        return resultForSignature[ccSig]
    end

    local handleWorkerOutput = function(output, finishedCcIdx)
        assert(type(output) == "string")

        local cmd = compileCommands[finishedCcIdx]

        do
            -- NOTE: this depends on the precise formatting of the '-v' output.
            --  Further, we assume that the command line arguments are on the same line.
            local _, endIdx = output:find(' "'..clang..'" -cc1 ', 1, true)

            if (endIdx == nil) then
                F.errorInfo("For command #%d (%s), did not find clang -cc1 invocation in '-v' output.",
                            finishedCcIdx, cmd.file:match("[^/]+$"))
                -- NOTE: do not make this fatal. Just do not add the implicit include paths,
                -- likely leading to errors down the road.
            else
                local ccArgs = cmd.arguments
                local cc1Line = output:sub(endIdx + 1):match("^([^\n]+)\n")

                for includeDir in cc1Line:gmatch("-internal[-extrnc]*-isystem ([^ ]+)") do
                    -- NOTE: we get 'unknown argument' if we pass '-internal-...'.
                    ccArgs[#ccArgs + 1] = "-isystem"
                    ccArgs[#ccArgs + 1] = includeDir
                end
            end
        end
    end

    ----

    local startTime = os.time()

    -- Initial batch.
    spawnWorkers()

    -- Handle children in a FIFO fashion.
    -- TODO: if necessary (which seems unlikely), handle in a poll() way.
    for ccIdx = 1, ccCount do
        local result = getResult(ccIdx)
        handleWorkerOutput(result, ccIdx)
    end

    local prepTime = os.difftime(os.time(), startTime)

    if (prepTime >= 2) then
        F.info("Prepared compile commands in %d seconds.", prepTime)
    end
end

---------- Done!
return api
