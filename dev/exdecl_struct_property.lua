#!/bin/false extractdecls.lua modspec

local check = check
local printf = printf

local printed = false

return function(cur, args)
    local property = args[1]
    check(property == "size" or property == "alignment" or property == "offset",
          "argument must be 'size', 'alignment' or 'offset'")
    check(property ~= "offset" or #args == 2, "Must pass two user arguments")
    check(property == "offset" or #args == 1, "Must pass exactly one user arguments")

    if (not (cur:haskind("StructDecl") and cur:isDefinition())) then
        return
    end

    check(not printed, "Found more than one match")
    printed = true

    local ty = cur:type()
    local prop =
        (property == "size") and ty:size() or
        (property == "alignment") and ty:alignment() or
        ty:byteOffsetOf(args[2])

    check(prop >= 0, "Error obtaining property")

    printf("%d", prop)
end
