#!/bin/false extractdecls.lua modspec

local check = check
local printf = printf

----------

local TypeStrForByteCount = {
    [1] = "uint8_t",
    [2] = "uint16_t",
    [4] = "uint32_t",
    [8] = "uint64_t"
}

local printed = false

return function(cur)
    if (not (cur:haskind("TypedefDecl") and cur:isDefinition())) then
        return
    end

    -- TODO: allow batch usage.
    check(not printed, "Found more than one match")
    printed = true

    local ty = cur:type()
    local align = ty:alignment()
    local size = ty:size()

    check(align >= 0, "Error obtaining alignment")
    check(size >= 0, "Error obtaining size")

    check(size % align == 0,
           "Unsupported size: not evenly divisible by alignment")
    local alignTypeStr = TypeStrForByteCount[align]
    check(alignTypeStr ~= nil, "Unexpected or overlarge alignment")

    printf("struct { %s v_[%d]; }", alignTypeStr, size/align)
end
