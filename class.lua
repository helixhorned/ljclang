
local ffi = require("ffi")

local assert = assert
local error = error
local pairs = pairs
local setmetatable = setmetatable
local tostring = tostring
local type = type

local check = require("error_util").check

----------

local api = {}

function api.class(tab)
    check(type(tab) == "table", "argument must be a table", 2)

    -- The generated metatable
    local mt = { __metatable="class" }
    local ctor

    -- Whether we have "plain" string keys, that is, ones not starting with two underscores.
    local havePlainKeys = false

    -- check tab contents
    for k,v in pairs(tab) do
        if (k == 1) then
            -- constructor: a function that returns a table, or string
            -- containing struct definition.
            local isCType = (type(v) == "cdata" and tostring(v):match("^ctype<"))
            check(type(v) == "function" or type(v) == "string" or isCType,
                  "tab[1] must be a function, string or ctype", 2)
            ctor = v
        elseif (type(k) == "string") then
            check(type(v) == "function" or type(v) == "string",
                  "tab[<string>] must be a function or a string", 2)
            if (k:sub(1,2) == "__") then
                if (k == "__index") then
                    check(type(v) == "function", "tab.__index must be a function", 2)
                end
            else
                havePlainKeys = true
            end
        else
            error("tab can contain entries at [1], or string keys", 2)
        end
    end

    local __index_tab = {}
    local __index_func = tab.__index

    if (__index_func ~= nil and havePlainKeys) then
        -- The case where 'tab' has both key '__index' (which then must be a function, as
        -- checked above), as well as convenience string keys.
        error("tab has both __index and convenience __index entries", 2)
    elseif (havePlainKeys) then
        mt.__index = __index_tab
    elseif (__index_func ~= nil) then
        mt.__index = __index_func
    end

    check(ctor ~= nil, "must provide a constructor in tab[1]")
    tab[1] = nil

    -- Create the metatable by taking over the contents of the one passed to us.
    for k,v in pairs(tab) do
        assert(type(k) == "string")

        if (type(v) == "string") then  -- alias
            v = tab[v]
        end

        if (k:sub(1,2) == "__") then
            if (k ~= "__index") then
                mt[k] = v
            end
        else
            __index_tab[k] = v
        end
    end

    if (type(ctor) == "function") then
        local factory = function(...)
            local t = ctor(...)
            check(t == nil or type(t) == "table", "constructor must return nil or a table", 2)
            if (t ~= nil) then
                return setmetatable(t, mt)
            end
        end

        return factory
    else
        local ct = (type(ctor) == "string") and "struct {"..ctor.."}" or ctor
        return ffi.metatype(ct, mt)
    end
end

-- Done!
return api
