#!/bin/false extractdecls.lua modspec

local check = check
local printf = printf

local printed = false

return function(cur, args)
    local spec = args[1]
    local property, printHow = spec:match("^([^:]+)(.*)$")
    check(printHow == "" or printHow == ":name=value",
          "argument #1 must be suffixed with ':name=value' or not at all")
    check(property == "size" or property == "alignment" or property == "offset",
          "argument #1 must be 'size', 'alignment' or 'offset'")
    check(property ~= "offset" or #args == 2, "Must pass two user arguments")
    check(property == "offset" or #args == 1, "Must pass exactly one user arguments")

    if (not (cur:haskind("StructDecl") and cur:isDefinition())) then
        return
    end

    if (printHow == "") then
        check(not printed, "Found more than one match")
    end
    printed = true

    local ty = cur:type()
    local prop =
        (property == "size") and ty:size() or
        (property == "alignment") and ty:alignment() or
        ty:byteOffsetOf(args[2])

    check(prop >= 0, "Error obtaining property")

    if (printHow == "") then
        printf("%d", prop)
    else
        printf("[%q]=%d,", ty:name(), prop)
    end
end
