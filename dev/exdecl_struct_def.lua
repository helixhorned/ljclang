#!/bin/false extractdecls.lua modspec

local check = check
local concat = concat
local printf = printf

local printed = false

return function(cur)
    if (not (cur:haskind("StructDecl") and cur:isDefinition())) then
        return
    end

    -- TODO: FreeType: why are there seemingly multiple definitions of 'FT_Vector_'?
    if (not printed) then
        printed = true

        local tokens = cur:_tokens()
        printf("%s", concat(tokens, ' ', 2, #tokens))
    end
end
