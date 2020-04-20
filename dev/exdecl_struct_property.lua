#!/bin/false extractdecls.lua modspec

local check = check
local printf = printf

local printed = false

return function(cur, args)
    check(#args == 1, "Must pass exactly one user argument")
    local property = args[1]
    check(property == "size" or property == "alignment",
          "argument must be 'size' or 'alignment'")

    if (not (cur:haskind("StructDecl") and cur:isDefinition())) then
        return
    end

    check(not printed, "Found more than one match")
    printed = true

    local ty = cur:type()
    local prop = (property == "size") and ty:size() or ty:alignment()

    check(prop >= 0, "Error obtaining property")

    printf("%d", prop)
end
