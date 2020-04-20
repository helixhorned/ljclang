#!/bin/false extractdecls.lua modspec

local check = check
local printf = printf

local printed = false

return function(cur)
    if (not (cur:haskind("StructDecl") and cur:isDefinition())) then
        return
    end

    check(not printed, "Found more than one match")
    printed = true

    local ty = cur:type()
    local size = ty:size()

    check(size >= 0, "Error obtaining size")

    printf("%d", size)
end
