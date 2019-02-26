
local ffi = require("ffi")

local assert = assert
local error = error
local pairs = pairs
local setmetatable = setmetatable
local tostring = tostring
local type = type

----------

local check = require("util").check

----------

local api = {}

function api.class(tab)
    check(type(tab) == "table", "argument must be a table", 2)

    -- The generated metatable
    local mt = { __metatable=true }
    local ctor

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
            check(#k > 0, "tab.<string> must not be empty", 2)
            check(type(v) == "function" or type(v) == "string",
                  "tab[<string>] must be a function or a string", 2)
            if (k:sub(1,2) == "__") then
                if (k == "__index" and mt.__index ~= nil) then
                    error("tab has both __index and convenience __index entries", 2)
                end
            else
                if (mt.__index == nil) then
                    mt.__index = {}
                end
            end
        else
            error("tab can contain entries at [1], or string keys", 2)
        end
    end

    check(ctor ~= nil, "tab[1] must be a constructor function or a cdecl")
    tab[1] = nil

    -- Create the metatable by taking over the contents of the one passed to us.
    for k,v in pairs(tab) do
        assert(type(k) == "string")

        if (type(v) == "string") then  -- alias
            v = tab[v]
        end

        if (k:sub(1,2) == "__") then
            mt[k] = v
        else
            mt.__index[k] = v
        end
    end

    if (type(ctor) == "function") then
        local factory = function(...)
            local t = ctor(...)
            check(type(t) == "table", "constructor must return a table", 2)
            return setmetatable(t, mt)
        end

        return factory
    else
        local ct = (type(ctor) == "string") and "struct {"..ctor.."}" or ctor
        return ffi.metatype(ct, mt)
    end
end

-- Done!
return api
