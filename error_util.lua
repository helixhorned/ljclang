local error = error

----------

local api = {}

-- Wrap 'error' in assert-like call to write type checks in one line instead of three.
function api.check(pred, msg, level)
    if (not pred) then
        error(msg, level+1)
    end
end

-- Done!
return api
