#!/usr/bin/env luajit

local io = require("io")
local os = require("os")

local dir = arg[1]

if (dir == nil) then
    print("Usage: "..arg[0].." /usr/path/to/clang-c/ > ljclang_Index_h.lua")
    os.exit(1)
end

local function loadandstrip(filename)
    local f, errmsg = io.open(dir.."/"..filename)
    if (f==nil) then
        print("Error opening file: "..errmsg)
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
              :gsub("LLVM_CLANG_C_EXTERN_C_BEGIN","")
              :gsub("LLVM_CLANG_C_EXTERN_C_END","")
              :gsub("time_t clang_getFileTime.-\n", "// REMOVED: clang_getFileTime\n")
              :gsub(" *\n+", "\n")
end

local cxstring_h = loadandstrip("CXString.h")
local cxfile_h = loadandstrip("CXFile.h")
local cxsourcelocation_h = loadandstrip("CXSourceLocation.h")
local cxdiagnostic_h = loadandstrip("CXDiagnostic.h")
local cxcompdb_h = loadandstrip("CXCompilationDatabase.h")
local cxerrorcode_h = loadandstrip("CXErrorCode.h")
local index_h = loadandstrip("Index.h")

print("require('ffi').cdef[==========[\n",
      cxstring_h, cxfile_h, cxsourcelocation_h, cxdiagnostic_h, cxcompdb_h, cxerrorcode_h, index_h, "]==========]")
print("return {}")
