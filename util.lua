local ffi = require("ffi")

local bit = require("bit")
local math = require("math")

local check = require("error_util").check
local class = require("class").class

local assert = assert
local error = error
local type = type
local unpack = unpack

----------

local api = {}

-- argstab = splitAtWhitespace(args)
function api.splitAtWhitespace(args)
    check(type(args) == "string", "<args> must be a string", 2)

    local argstab = {}
    -- Split delimited by whitespace.
    for str in args:gmatch("[^%s]+") do
        argstab[#argstab+1] = str
    end

    return argstab
end

-- Is <tab> a sequence of strings?
local function iscellstr(tab)
    for i=1,#tab do
        if (type(tab[i]) ~= "string") then
            return false
        end
    end

    -- We require this because in ARGS_FROM_TAB below, an index 0 would be
    -- interpreted as the starting index.
    return (tab[0] == nil)
end

function api.check_iftab_iscellstr(tab, name, level)
    if (type(tab)=="table") then
        if (not iscellstr(tab)) then
            error(name.." must be a string sequence when a table, with no element at [0]", level+1)
        end
    end
end

function api.checkOptionsArgAndGetDefault(opts, defaultValue)
    if (opts == nil) then
        opts = defaultValue;
    else
        check(type(opts)=="number" or type(opts)=="table", 3)
        api.check_iftab_iscellstr(opts, "<opts>", 3)
    end

    return opts
end

function api.handleTableOfOptionStrings(lib, prefix, opts)
    assert(type(prefix) == "string")

    if (type(opts)=="table") then
        local optflags = {}
        for i=1,#opts do
            optflags[i] = lib[prefix..opts[i]]  -- look up the enum
        end
        opts = bit.bor(unpack(optflags))
    end

    return opts
end

function api.getCommonPrefix(getString, ...)
    local commonPrefix = nil

    for key, value in ... do
        local str = getString(key, value)
        check(type(str) == "string", "getString(k, v) for iterated k, v should return a string", 2)

        if (commonPrefix == nil) then
            commonPrefix = str
        else
            for i = 1, math.min(#commonPrefix, #str) do
                if (commonPrefix:sub(1, i) ~= str:sub(1, i)) then
                    commonPrefix = commonPrefix:sub(1, i-1)
                end
            end
        end
    end

    return commonPrefix
end

-- Done!
return api
