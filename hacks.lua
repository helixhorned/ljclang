
local error_util = require("error_util")

local checktype = error_util.checktype
local check = error_util.check

--

local api = {}

function api.addSystemInclude(compilerArgs, language)
    checktype(compilerArgs, 1, "table", 2)
    checktype(language, 2, "string", 2)

    check(language == "c" or language == "c++",
          "argument #2 must be 'c' or 'c++'", 2)

    compilerArgs[#compilerArgs + 1] = "-isystem"
    compilerArgs[#compilerArgs + 1] = (language == "c") and
        -- Fixes LuaJIT, extractdecls.lua on <signal.h>:
        "/usr/lib/llvm-8/lib/clang/8.0.1/include" or
        -- Fixes conky, but breaks EP (personal project of author):
        -- (from libc++)
        "/usr/lib/llvm-8/include/c++/v1"
end

-- Done!
return api
