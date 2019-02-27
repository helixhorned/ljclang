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

-- Make "-Irelative/subdir" -> "-I/path/to/relative/subdir",
-- <opts> is modified in-place.
local function absifyIncludeOptions(args, prefixDir)
    for i=1,#args do
        local opt = args[i]
        if (opt:sub(1,2)=="-I" and opt:sub(3,3)~="/") then
            args[i] = "-I" .. prefixDir .. "/" .. opt:sub(3)
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
