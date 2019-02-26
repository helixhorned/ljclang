local ffi = require("ffi")

local bit = require("bit")

local assert = assert
local error = error
local type = type
local unpack = unpack

----------

-- Wrap 'error' in assert-like call to write type checks in one line instead of three.
local function check(pred, msg, level)
    if (not pred) then
        error(msg, level+1)
    end
end

-- argstab = splitAtWhitespace(args)
local function splitAtWhitespace(args)
    -- TODO: use 'check()' if this is an API function? Or remove it from the API?
    assert(type(args) == "string")
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

local function check_iftab_iscellstr(tab, name, level)
    if (type(tab)=="table") then
        if (not iscellstr(tab)) then
            error(name.." must be a string sequence when a table, with no element at [0]", level+1)
        end
    end
end

local function checkOptionsArgAndGetDefault(opts, defaultValue)
    if (opts == nil) then
        opts = defaultValue;
    else
        check(type(opts)=="number" or type(opts)=="table", 3)
        check_iftab_iscellstr(opts, "<opts>", 3)
    end

    return opts
end

local function handleTableOfOptionStrings(lib, prefix, opts)
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

-- Return API table.
return {
    check = check,
    splitAtWhitespace = splitAtWhitespace,
    check_iftab_iscellstr = check_iftab_iscellstr,
    checkOptionsArgAndGetDefault = checkOptionsArgAndGetDefault,
    handleTableOfOptionStrings = handleTableOfOptionStrings,
}
