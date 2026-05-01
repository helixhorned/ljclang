
local error_util = require("error_util")
local llvm_libdir_include = require("llvm_libdir_include")[1]

local checktype = error_util.checktype
local check = error_util.check

--

local api = {}

function api.addSystemInclude(compilerArgs, language)
    checktype(compilerArgs, 1, "table")
    checktype(language, 2, "string")

    check(language == "c", "argument #2 must be 'c'")

    compilerArgs[#compilerArgs + 1] = "-isystem"
    -- Fixes extractdecls.lua on <signal.h>:
    compilerArgs[#compilerArgs + 1] = llvm_libdir_include
end

-- Done!
return api
