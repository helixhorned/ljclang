#!/bin/false extractdecls.lua modspec

local check = check
local concat = concat
local printf = printf

local printed = false

return function(cur)
    if (not cur:haskind("MacroDefinition")) then
        return
    end

    check(not printed, "Found more than one match")
    printed = true

    local tokens = cur:_tokens()
    printf("%s", concat(tokens, "", 2, #tokens))
end
