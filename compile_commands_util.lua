local check = require("error_util").check

local assert = assert
local type = type

----------

local api = {}

local function stripArgs(args, pattern, num)
    assert(args[0] == nil)
    local numArgs = #args

    for i=1,numArgs do
        assert(type(args[i]) == "string")
    end

    for i=1,numArgs do
        if (args[i] and args[i]:find(pattern)) then
            for j=0,num-1 do
                args[i+j] = nil
            end
        end
    end

    local newargs = {}
    for i=1,numArgs do
        if (args[i] ~= nil) then
            newargs[#newargs+1] = args[i]
        end
    end
    return newargs
end

-- Strip "-c" and "-o <file>" options from args.
local function strip_c_and_o(args)
    local argsWithoutC = stripArgs(args, "^-c$", 1)
    local argsWithoutCAndO = stripArgs(argsWithoutC, "^-o$", 2)
    return argsWithoutCAndO
end

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

function api.sanitize_args(args, directory)
    check(type(args) == "table", "<args> must be a table", 2)
    check(type(directory) == "string", "<directory> must be a string", 2)

    check(directory:sub(1,1) == "/", "<directory> must start with '/'", 2)  -- XXX: Windows

    local localArgs = {}
    for i = 1,#args do
        localArgs[i] = args[i]
    end

    local strippedArgs = strip_c_and_o(localArgs)
    return absifyIncludeOptions(strippedArgs, directory)
end

return api
