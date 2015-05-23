
local error = error
local pairs = pairs
local setmetatable = setmetatable
local type = type

----------

local function check(pred, msg, level)
    if (not pred) then
        error(msg, level+1)
    end
end

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
            -- constructor: a function that returns a table
            check(type(v) == "function", "tab[1] must be a function", 2)
            ctor = v
        elseif (type(k) == "string") then
            check(#k > 0, "tab.<string> must not be empty", 2)
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

    check(ctor ~= nil, "tab[1] must provide a constructor")

    -- apply tab contents
    for k,v in pairs(tab) do
        if (type(k) == "string") then
            if (k:sub(1,2) == "__") then
                mt[k] = v
            else
                mt.__index[k] = v
            end
        end
    end

    local factory = function(...)
        local t = ctor(...)
        check(type(t) == "table", "constructor must return a table", 2)
        return setmetatable(t, mt)
    end

    return factory
end

-- Done!
return api
