
-- List of Clang compiler options relevant to precompiled headers. (That is, options
-- determining generation-use compatibility between precompiled headers.)

-- NOTE: false/true as default values refers to positive form of the -f* option, even if the
-- LangOption name (which is only kept for reference, but not in the code) is negated and
-- even if only the '-fno-*' form exists.
--
-- Examples:
--
-- 1. Negated LangOption name:
--    { "NoConstantCFStrings", "-fconstant-cfstrings", true },
-- means that -fconstant-cfstrings is true by default, not NoConstantCFStrings
-- (-fno-constant-cfstrings).
--
-- 2. Only '-fno-*' exists:
--    { "CXXOperatorNames", "-foperator-names", ONLY_NEGATIVE },
-- means that -fno-operator-names is not enabled by default (logically), but for our
-- purposes we say that (the nonexistent option) "-foperator-names" has default 'true'.

local assert = assert
local type = type

----------

local MAKE_NO_ASSUMPTION = {}

-- Tags for the option behavior.
local DEPENDENT = MAKE_NO_ASSUMPTION  -- Dependent on other options (and potentially something else)
local LANG = MAKE_NO_ASSUMPTION  -- Dependent on the language
local TRUE_IN_CXX = true  -- Always true in C++
-- Only the '-fno-*' form exists. Note: in the table below the argument is still
-- '-f<positive form>', for indexing purposes from the Lua code.
local ONLY_NEGATIVE = true
local UNKNOWN = MAKE_NO_ASSUMPTION  -- Could not determine default empirically
local EMPIRICAL_TRUE = true  -- Default is 'true' empirically, but that seems to contradict the code
local COMPUTED = MAKE_NO_ASSUMPTION  -- Default value is computed. (Not "constant" in a trivial way.)

----------

-- { <name>, <argument name(s)>, <behavior/defaultValue>, <abbrev> [computed] }
--
-- NOTE: argument names for one given LangOption may not be exhaustive. In particular, if
-- one option depends on an argument name that another option also depends on, it is listed
-- only once.
local LangOptions = {
    { "MSVCCompat", "-fms-compatibility", false },
    { "MicrosoftExt", "-fms-extensions", DEPENDENT },
    { "AsmBlocks", "-fasm-blocks", DEPENDENT },
    { "Borland", "-fborland-extensions", false },
    { "AppExt", "-fapplication-extension", false },
    { "Trigraphs", "-ftrigraphs", DEPENDENT },
    { "Char8", "-fchar8_t", LANG },
    { "DeclSpecKeyword", "-fdeclspec", DEPENDENT },
    --<
    { "GNUKeywords", "-fgnu-keywords", LANG },
    { "GNUKeywords", "-fasm", LANG },
    -->
    { "Digraphs", "-fdigraphs", TRUE_IN_CXX },
    { "CXXOperatorNames", "-foperator-names", ONLY_NEGATIVE },
    { "AppleKext", "-fapple-kext", false },
    { "WritableStrings", "-fwritable-string", false },
    { "AltiVec", "-maltivec", UNKNOWN },
    { "ZVector", "-fzvector", false },
    { "Exceptions", "-fexceptions", EMPIRICAL_TRUE },
    { "CXXExceptions", "-fcxx-exceptions", EMPIRICAL_TRUE },
    { "DWARFExceptions", "-fdwarf-exceptions", false },
    { "SjLjExceptions", "-fsjlj-exceptions", false },
    { "SEHExceptions", "-fseh-exceptions", false },
    { "TraditionalCPP", "-traditional-cpp", false },
    { "RTTI", "-frtti", true },
    { "RTTIData", "-frtti-data", ONLY_NEGATIVE },
    { "MSBitfields", "-mms-bitfields", false },
    { "Freestanding", "-ffreestanding", false },
    { "NoBuiltin", "-fbuiltin", DEPENDENT },
    { "GNUAsm", "-fgnu-inline-asm", true },
    { "CoroutinesTS", "-fcoroutines-ts", false },
    { "RelaxedTemplateTemplateArgs", "-frelaxed-template-template-args", false },
    { "POSIXThreads", "-pthread", false },
    { "Blocks", "-fblocks", false },  -- dependent, but only on OpenCL
    { "MathErrno", "-fmath-errno", true },
    { "Modules", "-fmodules", DEPENDENT },
    { "ModulesTS", "-fmodules-ts", false },
    { "ModulesDeclUse", "-fmodules-decluse", DEPENDENT },
    { "ModulesStrictDeclUse", "-fmodules-strict-decluse", false },
    { "ModulesLocalVisibility", "-fmodules-local-submodule-visibility", DEPENDENT },
    { "PackStruct", "-fpack-struct=", 0 },
    { "MaxTypeAlign", "-fmax-type-align=", 0 },
    { "AlignDouble", "-malign-double", UNKNOWN },
    -- PIC-related options are parsed in the driver and passed down to the compiler frontend by
    -- what appear to be internal options (such as -pic-level). See LLVM's
    --  clang/lib/Driver/ToolChains/CommonArgs.cpp
    -- and its uses in
    --  clang/lib/Driver/ToolChains/Clang.cpp
    -- So, do not attempt any smartness at our side, just collect them as they are.
    -- Note that we cannot just strip them: for example, __PIC__ is defined when PIC is enabled.
    { "", "-fPIC", DEPENDENT },
    { "", "-fpic", DEPENDENT },
    { "", "-fPIE", DEPENDENT },
    { "", "-fpie", DEPENDENT },
    --<
    { "NoInlineDefine", "-finline", DEPENDENT },
    { "NoInlineDefine", "-finline-functions", DEPENDENT },
    { "NoInlineDefine", "-finline-hint-functions", DEPENDENT },
    -->
    { "FastMath", "-ffast-math", DEPENDENT },
    { "FiniteMathOnly", "-ffinite-math-only", DEPENDENT },
    --<
    { "UnsafeFPMath", "-menable-unsafe-fp-math", DEPENDENT },
    { "UnsafeFPMath", "-cl-unsafe-math-optimizations", DEPENDENT },
    -->
    { "CharIsSigned", "-fsigned-char", TRUE_IN_CXX },
    { "MSPointerToMemberRepresentationMethod", "-fms-memptr-rep=", UNKNOWN },
    { "ShortEnums", "-fshort-enums", false },
    { "SizedDeallocation", "-fsized-deallocation", false },
    { "AlignedAllocation", "-faligned-allocation", EMPIRICAL_TRUE },
    { "NewAlignOverride", "-fnew-alignment=", 0 },
    { "NoConstantCFStrings", "-fconstant-cfstrings", true },
    { "GlobalAllocationFunctionVisibilityHidden", "-fvisibility-global-new-delete-hidden", false },
    { "SinglePrecisionConstants", "-cl-single-precision-constant", false },
    { "FastRelaxedMath", "-cl-fast-relaxed-math", false },
    { "DefaultFPContractMode", "-ffp-contract=", "off" },
    { "HexagonQdsp6Compat", "-mqdsp6_compat", UNKNOWN },
    --< NOTE: duplicate name, once as a flag and once as an option with value.
    { "CFProtectionBranch", "-fcf-protection", false },
    { "CFProtectionBranch", "-fcf-protection=", UNKNOWN },
    -->
    { "ValueVisibilityMode", "-fvisibility=", "default" },
    { "TypeVisibilityMode", "-ftype-visibility", DEPENDENT },
    { "StackProtector", "-fstack-protector", false },
    { "TrivialAutoVarInit", "-ftrivial-auto-var-init=", "uninitialized" },
    --<
    { "SignedOverflowBehavior", "-ftrapv", false },
    { "SignedOverflowBehavior", "-fwrapv", false },
    -->
    { "MSCompatibilityVersion", "-fms-compatibility-version=", 0 },
    { "ApplePragmaPack", "-fapple-pragma-pack", false },
    { "RetainCommentsFromSystemHeaders", "-fretain-comments-from-system-headers", false },
    { "SanitizeAddressFieldPadding", "-fsanitize-address-field-padding=", UNKNOWN },
    { "XRayInstrument", "-fxray-instrument", false },
    { "XRayAlwaysEmitCustomEvents", "-fxray-always-emit-customevents", UNKNOWN },
    { "XRayAlwaysEmitTypedEvents", "-fxray-always-emit-typedevents", UNKNOWN },
    { "ForceEmitVTables", "-fforce-emit-vtables", false },
    { "ClangABICompat", "-fclang-abi-compat=", COMPUTED },
    { "RegisterStaticDestructors", "-fno-c++-static-destructors", false },
}

-- Generate abbreviated argument names

-- [<abbrev>] = nil or count
local abbrevCount = {}

for i = 1, #LangOptions do
    local triple = LangOptions[i]
    local carg = triple[2]

    -- CAUTION LUA_PATTERN: in a Lua pattern, '-' is in general a magic character, *unless*
    -- (it seems) when its interpretation as such would be meaningless. (At least, this is
    -- the case when it is not preceded by a character class).
    --
    -- So, patterns of the form "^-" (as opposed to the more proper "^%-") do match a
    -- literal '-' at the beginning of a string.

    assert(carg:match("^-[a-z]+"))
    -- Check expectations that are relied on at the usage site.
    assert(not carg:match('=') or carg:match("^-f"))  -- only 'f' args have '='
    assert(not carg:match("^-.no%-") or carg:match("^-fno-"))  -- only 'f' args have negation

    local abbrevPrefix = carg:match('^%-([a-z]+)')
    local abbrev

    if (abbrevCount[abbrevPrefix] == nil) then
        abbrev = abbrevPrefix
        abbrevCount[abbrevPrefix] = 1
    else
        abbrev = abbrevPrefix .. abbrevCount[abbrevPrefix]
        abbrevCount[abbrevPrefix] = abbrevCount[abbrevPrefix] + 1
    end

    triple[4] = abbrev
end

-- Generate map of compiler argument ("key") to index into LangOptions.
local ArgToOptIdx = {}

for i = 1, #LangOptions do
    local quad = LangOptions[i]
    local carg, behavior = quad[2], quad[3]
    assert(type(carg) == "string")
    ArgToOptIdx[carg] = i
end

-- Done!
return { Opts = LangOptions, ArgToOptIdx = ArgToOptIdx }
