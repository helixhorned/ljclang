local assert = assert
local error = error
local type = type

----------

local api = {}

-- TODO: default 'level' to 2 for the following two functions?

-- Wrap 'error' in assert-like call to write type checks in one line instead of three.
function api.check(pred, msg, level)
    if (not pred) then
        error(msg, level+1)
    end
end

function api.checktype(object, argIdx, typename, level)
    -- NOTE: type(nil) returns nil. We disallow passing nil for `typename` however:
    -- the resulting check would be "is <object>'s type anything other than nil" rather than
    -- the more likely intended "is <object>'s type nil (in other words, is it nil?)".
    assert(type(argIdx) == "number")
    assert(type(typename) == "string")

    if (type(object) ~= typename) then
        local msg = "argument #"..argIdx.." must be a "..typename.." (got "..type(object)..")"
        error(msg, level+1)
    end
end

-- Done!
return api
