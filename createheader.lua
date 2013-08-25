#!/usr/bin/env luajit

local io = require("io")
local os = require("os")

local dir = arg[1]

if (dir == nil) then
    print("Usage: ", arg[0], " /usr/path/to/clang-c/ > ljclang_Index_h.lua")
    os.exit(1)
end

local function loadandstrip(filename)
    local f, errmsg = io.open(dir.."/"..filename)
    if (f==nil) then
        print("Error opening file: ", errmsg)
        os.exit(2)
    end

    local str = f:read("*a")
    f:close()

    -- Remove...
    return str:gsub("#ifdef __.-#endif\n", "")  -- #ifdef __cplusplus/__have_feature ... #endif
              :gsub("#define.-[^\\]\n", "")  -- multi-line #defines
              :gsub("/%*%*.-%*/", "")  -- comments, but keep headers with license ref
              :gsub("#[^\n]-\n", "")  -- single-line preprocessor directives
              :gsub("CINDEX_LINKAGE","")
              :gsub("CINDEX_DEPRECATED","")
              :gsub("time_t", "// time_t")  -- clang_getFileTime declaration
end

local cxstring_h = loadandstrip("CXString.h")
local index_h = loadandstrip("Index.h")

print("require('ffi').cdef[==========[\n",
      cxstring_h, index_h, "]==========]")
