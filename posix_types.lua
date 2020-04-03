local ffi = require("ffi")

----------

local ljposix = ffi.load("ljposix")

-- From libljclang_support.so or libljposix.so:
ffi.cdef[[
const char *ljclang_getTypeDefs();
]]

ffi.cdef(ffi.string(ljposix.ljclang_getTypeDefs()))

return {}
