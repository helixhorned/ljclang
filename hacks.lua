
local error_util = require("error_util")

local checktype = error_util.checktype
local check = error_util.check

--

local api = {}

function api.addSystemInclude(compilerArgs, language)
    checktype(compilerArgs, 1, "table", 2)
    checktype(language, 2, "string", 2)

    check(language == "c", "argument #2 must be 'c'", 2)

    compilerArgs[#compilerArgs + 1] = "-isystem"
    -- Fixes extractdecls.lua on <signal.h>:
    compilerArgs[#compilerArgs + 1] = "/usr/lib/llvm-8/lib/clang/8.0.1/include"
end

-- Done!
return api
