local cl = require("ljclang")

local check = require("error_util").check

local type = type

----------

local api = {}

-- Strip "-c" and "-o <file>" options from args.
local function strip_c_and_o(args)
    local argsWithoutC = cl.stripArgs(args, "^-c$", 1)
    return cl.stripArgs(argsWithoutC, "^-o$", 2)
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

    return absifyIncludeOptions(strip_c_and_o(args), directory)
end

return api
