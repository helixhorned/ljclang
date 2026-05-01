local bit = require("bit")
local math = require("math")

local error_util = require("error_util")
local check = error_util.check
local checktype = error_util.checktype
local class = require("class").class

local assert = assert
local error = error
local ipairs = ipairs
local type = type
local unpack = unpack

----------

local api = {}

-- argstab = splitAtWhitespace(args)
function api.splitAtWhitespace(args)
    check(type(args) == "string", "<args> must be a string")

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

function api.check_iftab_iscellstr(tab, name, additional_level)
    if (additional_level == nil) then
        additional_level = 0
    end
	assert(type(name) == "string")
    assert(type(additional_level) == "number")

    if (type(tab)=="table") then
        if (not iscellstr(tab)) then
            error(name.." must be a string sequence when a table, with no element at [0]", 3 + additional_level)
        end
    end
end

function api.checkOptionsArgAndGetDefault(opts, defaultValue)
    if (opts == nil) then
        opts = defaultValue;
    else
        check(type(opts)=="number" or type(opts)=="table",
              "argument #1 must be a number or a table", 2)
        api.check_iftab_iscellstr(opts, "<opts>", 2)
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
    checktype(getString, 1, "function")
    check(commonPrefix == nil or type(commonPrefix) == "string",
          "argument #2 must be nil or a string")

    for key, value in ... do
        local str = getString(key, value)
        check(type(str) == "string", "getString(k, v) for iterated k, v should return a string")

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
        checktype(firstType, 1, "string")
        checktype(secondType, 2, "string")
        check(firstType ~= secondType, "arguments #1 and #2 must be distinct")

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
    checktype(first, 1, self[BimapTags.FIRST_TYPE])
    checktype(second, 2, self[BimapTags.SECOND_TYPE])

    -- NOTE: No checking of any kind (such as for one-to-oneness).
    self[first] = second
    self[second] = first

    self[BimapTags.COUNT] = self[BimapTags.COUNT] + 1
end

function api.MakeBimap(tab)
    checktype(tab, 1, "table")

    local firstItem = tab[1]
    local bimap = api.Bimap(type(firstItem[1]), type(firstItem[2]))

    for _, item in ipairs(tab) do
        api.BimapAdd(bimap, item[1], item[2])
    end

    return bimap
end

function api.BimapGetCount(self)
    return self[BimapTags.COUNT]
end

---------- BoolArray ----------

local function CheckIsFiniteInt(number, argIdx)
    checktype(number, argIdx, "number", 1)
    check(number >= 1 and number < math.huge, "argument must be a finite number", -1)
    check(math.floor(number) == number, "argument must be an integral number", -1)
end

api.BoolArray = function(size, initialValue)
    CheckIsFiniteInt(size, 1)
    checktype(initialValue, 2, "boolean")

    local array = {}
    for i = 1,size do
        array[i] = initialValue
    end
    return array
end

-- Done!
return api
