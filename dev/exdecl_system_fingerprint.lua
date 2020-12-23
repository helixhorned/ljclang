#!/bin/false extractdecls.lua modspec

local ffi = ffi
local printf = printf

local printed = false

return function(cur)
    if (not printed) then
        printed = true
        -- KEEPINSYNC posix_types.lua.in
        -- NOTE: for all processor architectures that LuaJIT supports,
        --  the string 'ffi.arch' implies bitness and endianness.
        --  See the definitions of macro 'LJ_ARCH_NAME' in its 'src/lj_arch.h'.
        printf("%s-%s", ffi.os, ffi.arch)
    end
end
