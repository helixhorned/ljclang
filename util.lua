local ffi = require("ffi")

local bit = require("bit")
local math = require("math")

local error_util = require("error_util")
local check = error_util.check
local checktype = error_util.checktype
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
        opts = (#opts > 0) and bit.bor(unpack(optflags)) or 0
    end

    return opts
end

function api.getCommonPrefix(getString, commonPrefix, ...)
    checktype(getString, 1, "function", 2)
    check(commonPrefix == nil or type(commonPrefix) == "string",
          "argument #2 must be nil or a string", 2)

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

function api.copySequence(tab)
    local newTab = {}

    for i = 1,#tab do
        newTab[i] = tab[i]
    end

    return newTab
end

---------- Bimap ----------

local BimapTags = {
    FIRST_TYPE = {},
    SECOND_TYPE = {},
    COUNT = {},
}

api.Bimap = class
{
    function(firstType, secondType)
        checktype(firstType, 1, "string", 2)
        checktype(secondType, 2, "string", 2)
        check(firstType ~= secondType, "arguments #1 and #2 must be distinct", 2)

        return {
            [BimapTags.FIRST_TYPE] = firstType,
            [BimapTags.SECOND_TYPE] = secondType,
            [BimapTags.COUNT] = 0,
        }
    end,

    -- NOTE: 'self' itself is used to store the data.
    -- Hence, the "member functions" are stand-alone.
}

function api.BimapAdd(self, first, second)
    checktype(first, 1, self[BimapTags.FIRST_TYPE], 2)
    checktype(second, 2, self[BimapTags.SECOND_TYPE], 2)

    -- NOTE: No checking of any kind (such as for one-to-oneness).
    self[first] = second
    self[second] = first

    self[BimapTags.COUNT] = self[BimapTags.COUNT] + 1
end

function api.BimapGetCount(self)
    return self[BimapTags.COUNT]
end

-- Done!
return api
