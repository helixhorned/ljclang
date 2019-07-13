#!/usr/bin/env luajit

-- This is a development utility program: it parses LLVM's LangOptions.def and produces the
-- precursor of a list of PCH-relevant options that need to be handled in addition to the
-- handling of selected options in compile_commands_util.lua's sanitize_args().
--
-- After manually looking at the dependency semantics of the various options (default value,
-- is it self-contained or dependent on others?, ...), PchRelevantLangOptions.lua results.

local io = require("io")
local os = require("os")

local string = require("string")
local format = string.format

local ipairs = ipairs
local arg = arg

----------

local function errprint(str)
    io.stderr:write(str.."\n")
end

local function errprintf(fmt, ...)
    errprint(format(fmt, ...))
end

----------

local filename = arg[1]

if (filename == nil) then
    errprintf("Usage: %s path/to/<llvm>/clang/include/clang/Basic/LangOptions.def", arg[0])
    os.exit(1)
end

local f, msg = io.open(filename)

if (f == nil) then
    errprintf("Error opening %s: %s", filename, msg)
    os.exit(1)
end

local IgnoredLangOptPatterns = {
    -- Already handled by '-std=...'.
    "^CPlusPlus",

    -- Not C++.
    -- TODO: might some be PCH-relevant even in C++ after all?
    "^ObjC", "^OpenCL", "^CUDA", "^OpenMP",
    "^NativeHalf",
}

local IsIgnoredLangOpt = {
    -- Not C++.
    ["GC"] = true,
    ["HIP"] = true,

    -- Already handled.
    ["Optimize"] = true,
    ["OptimizeSize"] = true,
    ["PICLevel"] = true,
    ["PIE"] = true,

    -- Strictly language-dependent.
    ["C99"] = true,
    ["C11"] = true,
    ["C17"] = true,
    ["LineComment"] = true,
    ["Bool"] = true,
    ["Half"] = true,
    ["WChar"] = true,

    ["GNUMode"] = true,
    ["GNUInline"] = true,

    ["LaxVectorConversions"] = true,  -- OpenCL only (and then conditional)
    ["DoubleSquareBracketAttributes"] = true,  -- always true in C++11+

    -- Not applicable to C++.
    ["HalfArgsAndReturns"] = true,
    ["RenderScript"] = true,
    ["GPURelocatableDeviceCode"] = true,

    -- Gave errors for C++ in my (admittedly not exhaustive) testing.

    -- May be partly because not applicable to C++, and partly because of incomplete
    -- understanding. (E.g. similar to: there is no -pic-level: it is handled by -fPIC etc.)
    ["AddressSpaceMapMangling"] = true,
    ["AlignedAllocationUnavailable"] = true,
    ["BlocksRuntimeOptional"] = true,
    ["ConceptsTS"] = true,
    ["ConstStrings"] = true,
    ["Deprecated"] = true,
    ["DefaultCallingConv"] = true,
    ["DllExportInlines"] = true,
    ["ExternCNoUnwind"] = true,
    ["FakeAddressSpaceMap"] = true,
    ["FunctionAlignment"] = true,
    ["IncludeDefaultHeader"] = true,
    ["NoBitFieldTypeAlign"] = true,
    ["NoMathBuiltin"] = true,
    ["Static"] = true,
    ["VtorDispMode"] = true,
    ["WCharSize"] = true,
    ["WCharIsSigned"] = true,

    -- Always false for C++, see LLVM's clang/lib/Frontend/CompilerInvocation.cpp
    ["FixedPoint"] = true,
    ["PaddingOnUnsignedFixedPoint"] = true,
}

while (true) do
    local l = f:read("*l")

    if (l == nil) then
        break
    end

    local langoptType, langoptName = l:match("^([A-Z_]+)%(([A-Za-z_][A-Za-z_0-9]*)")

    if (langoptType == nil) then
        goto next
    end

    if (langoptType:match("BENIGN")) then
        goto next
    end

    for _, pattern in ipairs(IgnoredLangOptPatterns) do
        if (langoptName:match(pattern)) then
            goto next
        end
    end

    if (IsIgnoredLangOpt[langoptName]) then
        goto next
    end

    io.stdout:write(langoptName, '\n')

::next::
end
