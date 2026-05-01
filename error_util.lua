local assert = assert
local error = error
local type = type

----------

local api = {}

-- Wrap 'error' in assert-like call to write type checks in one line instead of three.
function api.check(pred, msg, additional_level)
    if (additional_level == nil) then
        additional_level = 0
    end
	assert(type(msg) == "string")
    assert(type(additional_level) == "number")

    if (not pred) then
        error(msg, 3 + additional_level)
    end
end

function api.checktype(object, argIdx, typename, additional_level)
    -- NOTE: type(nil) returns nil. We disallow passing nil for `typename` however:
    --  the resulting check would be "is <object>'s type anything other than nil" rather than
    --  the more likely intended "is <object>'s type nil (in other words, is it nil?)".
    assert(type(argIdx) == "number")
    assert(type(typename) == "string")
    if (additional_level == nil) then
        additional_level = 0
    end
    assert(type(additional_level) == "number")

    if (type(object) ~= typename) then
        local msg = ("argument #%d must be a %s (got %s)"):format(argIdx, typename, type(object))
        error(msg, 3 + additional_level)
    end
end

-- Done!
return api
