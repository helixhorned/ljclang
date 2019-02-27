local io = require("io")

local math = require("math")
local util = require("util")
local check = util.check

local assert = assert
local ipairs = ipairs
local loadstring = loadstring
local pairs = pairs
local pcall = pcall
local setfenv = setfenv
local type = type

----------

local api = {}

local function tweak_json_string_for_load_as_lua_table(str)
    -- replace leading/trailing '[]' with '{}'
    str = str:gsub("^%[\n", "{\n"):gsub("\n%]\n?$", "\n}")
    -- replace any other '[]' (expected: of 'arguments' key, if present)
    str = str:gsub(": %[\n", ": {\n"):gsub("%], *\n", "},\n")
    -- replace '"<key>": ' by 'key= ' (expected to occur in what would now be a Lua table)
    return "return "..str:gsub('\n( *)"([a-z]+)": ', '\n%1%2= ')
end

local function validate_compile_commands_table(cmds)
    local PREFIX = "ERROR: Unexpected input: parsed result "

    if (type(cmds) ~= "table") then
        return PREFIX.."is not a Lua table"
    end

    local numCmds = #cmds

    for k,_ in pairs(cmds) do
        if (type(k) ~= "number") then
            return PREFIX.."contains non-numeric keys"
        end

        if (math.floor(k) ~= k) then
            return PREFIX.."contains non-integral numeric keys"
        end

        if (not (k >= 1 and k <= numCmds)) then
            return PREFIX.."contains numeric keys inconsistent with #table"
        end
    end

    local hasArgs = (numCmds > 0 and cmds[1].arguments ~= nil)
    local hasCommand = (numCmds > 0 and cmds[1].command ~= nil)

    if (numCmds > 0 and not hasArgs and not hasCommand) then
        return PREFIX.."is non-empty but its first element contains neither key 'arguments' nor 'command'"
    end

    local key = hasArgs and "arguments" or "command"
    local expectedKeyType = hasArgs and "table" or "string"
    local expectedMissingKey = hasArgs and "command" or "arguments"

    for _, cmd in ipairs(cmds) do
        if (type(cmd) ~= "table") then
            return PREFIX.."contains missing or non-table elements"
        end

        if (type(cmd.directory) ~= "string") then
            return PREFIX.."contains an element with key 'directory' missing or not of string type"
        end

        if (type(cmd.file) ~= "string") then
            return PREFIX.."contains an element with key 'file' missing or not of string type"
        end

        if (type(cmd[key]) ~= expectedKeyType) then
            return PREFIX.."contains an element with key '"..key..
                "' missing or not of "..expectedKeyType.." type"
        end

        if (cmd[expectedMissingKey] ~= nil) then
            return PREFIX.."contains and element with key '"..expectedMissingKey..
                "' unexpectedly present"
        end

        if (hasCommand and cmd.command:match("\\%s")) then
            -- We will split the command by whitespace, so escaped whitespace characters
            -- would throw us off the track. For now, bail out if we come across that case.
            return PREFIX.."contains an element with key 'command' "..
                "containing a backslash followed by whitespace (not implemented)"
        end
    end

    return nil, hasCommand
end

-- If the entries have key 'command', add key 'args'.
local function tweak_compile_commands_table(cmds, hasCommand)
    assert(type(cmds) == "table")

    if (hasCommand) then
        for _, cmd in ipairs(cmds) do
            local argv = util.splitAtWhitespace(cmd.command)
            local arguments = {}

            for i = 2,#argv do
                -- Keep only the arguments, not the invoked executable name.
                arguments[i - 1] = argv[i]
            end

            cmd.arguments = arguments
            cmd.command = nil
        end
    end

    return cmds
end

local function load_json_as_lua_string(str)
    local func, errmsg = loadstring(str, "compile_commands.json as Lua table")

    if (func == nil) then
        return nil, errmsg
    end

    -- Completely empty the function's environment as an additional safety measure,
    -- then run the chunk protected.
    local ok, result = pcall(setfenv(func, {}))
    if (not ok) then
        assert(type(result) == "string")  -- error message
        return nil, result
    end

    local errmsg, hasCommand = validate_compile_commands_table(result)
    if (errmsg ~= nil) then
        return nil, errmsg
    end

    return tweak_compile_commands_table(result, hasCommand)
end

-- Parses a compile_commands.json file, returning a Lua table.
-- On failure, returns nil and an error message.
--
-- Supported formats:
--
-- [
--   <entry_0>,
--   <entry_1>,
--   ...
-- ]
--
-- with <entry_i> being either (1)
--
-- {
--   "arguments": [ <string>, <string>, ... ],
--   "directory": <string>,
--   "file": <string>
-- }
--
-- or (2)
--
-- {
--   "command": <string>  (compiler executable followed by its arguments, whitespace-separated)
--   "directory": <string>,
--   "file": <string>
-- }
--
-- The returned table always contains entries of the form (1). Backslashes followed by
-- whitespace in the "command" key in form (2) are rejected.
function api.parse_compile_commands(compile_commands_string)
    check(type(compile_commands_string) == "string",
          "<compile_commands_string> must be a string", 2)

    local str = tweak_json_string_for_load_as_lua_table(compile_commands_string)
    return load_json_as_lua_string(str)
end

function api.read_compile_commands(filename)
    check(type(filename) == "string", "<filename> must be a string", 2)
    local f, msg = io.open(filename)

    if (f == nil) then
        return nil, msg
    end

    local str = f:read("*a")
    f:close()
    assert(type(str) == "string")

    return api.parse_compile_commands(str)
end

-- Done!
return api
