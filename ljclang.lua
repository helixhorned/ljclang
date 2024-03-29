-- LuaJIT-based binding to libclang, modelled after
-- https://github.com/mkottman/luaclang-parser
--
-- See LICENSE for the Copyright Notice of LJClang.
-- License for LLVM: https://llvm.org/LICENSE.txt

local assert = assert
local error = error
local pairs = pairs
local require = require
local select = select
local setmetatable = setmetatable
local table = table
local tonumber = tonumber
local tostring = tostring
local type = type
local unpack = unpack

local ffi = require("ffi")
local C = ffi.C

local bit = require("bit")
local io = require("io")

local function lib(basename)
    return (ffi.os=="Windows" and "lib" or "")..basename
end

local check = require("error_util").check
local class = require("class").class
local util = require("util")

local clang = ffi.load(lib"clang")
local support = ffi.load("ljclang_support")

ffi.cdef[[
const char *ljclang_getLLVMVersion();
]]

local supportLLVMVersion = ffi.string(support.ljclang_getLLVMVersion()):gsub("git$","")

require("ljclang_Index_h")

local ExtractedEnums = require("ljclang_extracted_enums")
-- enum value -> name (i.e "reverse") mapping of cursor kinds:
local g_CursorKindName = ExtractedEnums.CursorKindName
ExtractedEnums.CursorKindName = nil

-------------------------------------------------------------------------

-- The table of externally exposed elements, returned at the end.
local api = ExtractedEnums
local cpuCount

api.hardwareConcurrency = function()
    if (cpuCount == nil) then
        cpuCount = 0
        for line in io.lines("/proc/cpuinfo") do
            cpuCount = cpuCount + (line:match("^processor\t: [0-9]+$") and 1 or 0)
        end
    end
    return cpuCount
end

-----=====

local CXCursor = ffi.typeof("CXCursor")
local CXCursorPtrAr = ffi.typeof("CXCursor *[1]")
local unsignedAr = ffi.typeof("unsigned [1]")

-- Give our structs names for nicer error messages.
ffi.cdef[[
// NOTE: CXCursor is a struct type by itself, but we wrap it to e.g. provide a
// kind() *method* (CXCursor contains a member of the same name).
struct LJClangCursor { CXCursor _cur; };
struct LJClangType { CXType _typ; };
]]

local TranslationUnit_t  -- class "forward-reference"
local Cursor_t = ffi.typeof "struct LJClangCursor"
local Type_t = ffi.typeof "struct LJClangType"

-- Our wrapping type Cursor_t is seen as raw CXCursor on the C++ side.
assert(ffi.sizeof(CXCursor) == ffi.sizeof(Cursor_t))

ffi.cdef([[
typedef enum CXChildVisitResult (*LJCX_CursorVisitor)(
    $ *cursor, $ *parent, CXClientData client_data);
]], Cursor_t, Cursor_t)

local LJCX_CursorVisitor = ffi.typeof("LJCX_CursorVisitor")

ffi.cdef[[
int ljclang_visitChildrenWith(CXCursor parent, LJCX_CursorVisitor visitor);
]]

-------------------------------------------------------------------------
-------------------------------- CXString -------------------------------
-------------------------------------------------------------------------

local CXString = ffi.typeof("CXString")

-- Convert from a libclang's encapsulated CXString to a plain Lua string and
-- dispose of the CXString afterwards.
local function getString(cxstr)
    assert(ffi.istype(CXString, cxstr))
    local cstr = clang.clang_getCString(cxstr)
    local str = cstr ~= nil and ffi.string(cstr) or nil
    clang.clang_disposeString(cxstr)
    return str
end

function api.clangVersion()
    return getString(clang.clang_getClangVersion())
end

do
    local libclangLLVMVersion = api.clangVersion()
    if (not libclangLLVMVersion:find(supportLLVMVersion, 1, true)) then
        error("Mismatching LLVM versions of 'libljclang_support' ("..libclangLLVMVersion..
                  ") and 'libclang' ("..supportLLVMVersion..")")
    end
end

-------------------------------------------------------------------------

local function HandleNumberOrStringTabOption(
        numOrTab, defaultValue, enumConstantPrefix)
    numOrTab = util.checkOptionsArgAndGetDefault(numOrTab, defaultValue)
    return util.handleTableOfOptionStrings(clang, enumConstantPrefix, numOrTab)
end

local function PrepareParse(srcfile, args, opts)
    check(type(srcfile)=="string", "<srcfile> must be a string", 3)
    check(type(args)=="string" or type(args)=="table", "<args> must be a string or table", 3)
    util.check_iftab_iscellstr(args, "<args>", 3)

    if (srcfile == "") then
        srcfile = nil
    end

    -- Input argument handling.

    if (type(args)=="string") then
        args = api.splitAtWhitespace(args)
    end

    opts = HandleNumberOrStringTabOption(
        opts, C.CXTranslationUnit_None, "CXTranslationUnit_")

    local argsptrs = ffi.new("const char * [?]", #args, args)  -- ARGS_FROM_TAB

    -- Create the CXTranslationUnit.
    local tuAr = ffi.new("CXTranslationUnit [1]")

    return srcfile, args, opts, argsptrs, tuAr
end

local function FinishParse(tuAr, errorCode, parent)
    -- NOTE: 0 is 'CXError_Success', but we cannot write that because 'errorCode' may be a
    --  CXErrorCode or an int.
    assert((tuAr[0] ~= nil) == (tonumber(errorCode) == 0))

    if (tuAr[0] == nil) then
        return nil, errorCode
    end

    -- Wrap it in a TranslationUnit_t.
    return TranslationUnit_t(tuAr[0], parent, true), errorCode
end

local function WrappedArrayType(elementCType, elementWrapFunc, methods)
    return class{
        ffi.typeof("struct { const $ *_ptr; double _length; }", elementCType),

        __len = function(self)
            return self._length
        end,

        __index = function(self, i)
            if (methods ~= nil and type(i) == "string") then
                return methods[i]
            end

            check(type(i) == "number", "<i> must be a number", 2)
            check(i >= 1 and i <= self._length, "<i> must be in [1, #self]", 2)

            return elementWrapFunc(self._ptr[i - 1])
        end,
    }
end

-------------------------------------------------------------------------
------------------------------ IndexSession -----------------------------
-------------------------------------------------------------------------

local CXFile = ffi.typeof("CXFile")
local SingleCXFileArray = ffi.typeof("CXFile [1]")
local SourceLocation  -- class "forward-reference"

-- File and SourceLocation are circularly referential. "Forward-declare" the former.
local File

local CXTypes = {
    {
        ffi.typeof("CXCursor"),
        function (cxcur, parent)
            -- CAUTION: 'parent' lost.
            return Cursor_t(cxcur)
        end
    },

    {
        -- TODO?
        ffi.typeof("void *"),  -- CXFile, CXModule
        function (voidPtr, _)
            return (voidPtr ~= nil) and true or nil
        end
    },

    {
        ffi.typeof("CXIdxLoc"),
        function(cxidxloc, parent)
            local cxsrcloc = clang.clang_indexLoc_getCXSourceLocation(cxidxloc)
            return SourceLocation(cxsrcloc, parent)
        end
    },
}

local CXIdxObjectWrapper  -- class "forward-reference"

local CXIdxAttrInfoPtr = ffi.typeof("const CXIdxAttrInfo *")
local CXIdxAttrInfoPtrPtr = ffi.typeof("$ const *", CXIdxAttrInfoPtr)

local WrappedAttrInfoArray = WrappedArrayType(CXIdxAttrInfoPtr, function(cxIdxAttrInfoPtr)
    return CXIdxObjectWrapper(cxIdxAttrInfoPtr)
end, {
    has = function(self, attrKind)
        check(type(attrKind) == "string", "attribute #2 must be a string", 2)

        local attr = C['CXCursor_'..attrKind]

        for i = 1, #self do
            local kindNum = self[i].cursor:kindnum()
            assert(kindNum >= 'CXCursor_FirstAttr' and kindNum <= 'CXCursor_LastAttr')
            if (kindNum == attr) then
                return true
            end
        end

        return false
    end,
})

local CXIdxPtrTypes = {
    ContainerInfo = ffi.typeof("const CXIdxContainerInfo *"),
    DeclInfo = ffi.typeof("const CXIdxDeclInfo *"),
    EntityInfo = ffi.typeof("const CXIdxEntityInfo *"),
    EntityRefInfo = ffi.typeof("const CXIdxEntityRefInfo *"),
    ImportedAstFileInfo = ffi.typeof("const CXIdxImportedASTFileInfo *"),
    IncludedFileInfo = ffi.typeof("const CXIdxIncludedFileInfo *"),
}

local const_char_ptr_t = ffi.typeof("const char *")

local function checkCXIdxObject(expectedCType, cxIdxObjPtr)
    assert(ffi.istype(expectedCType, cxIdxObjPtr))
    assert(cxIdxObjPtr ~= nil)
end

CXIdxObjectWrapper = class
{
    function(cxIdxObjPtr)
        assert(cxIdxObjPtr ~= nil)

        return {
            _obj = cxIdxObjPtr[0],
        }
    end,

    __index = function(self, key)
        check(type(key) == "string", "key must be a string", 2)

        local value = self._obj[key]

        -- CAUTION: make sure that this wrapping covers all cases of the types in the
        --  'CX*Types' tables above as well as types reachable from them.

        if (key:sub(1,2) == "is") then
            -- 'int' on the C side -> boolean
            return (value ~= 0)
        elseif (type(value) == "number") then
            return value
        end

        -- Try members of struct type.
        for i = 1, #CXTypes do
            local typeDescTab = CXTypes[i]
            if (ffi.istype(typeDescTab[1], value)) then
                local ourType = typeDescTab[2]
                return ourType(value, self)
            end
        end

        -- Try members of type "pointer to const CXIdx<Thing>".
        for _, ctype in pairs(CXIdxPtrTypes) do
            if (ffi.istype(ctype, value)) then
                -- NOTE: potentially recurse!
                return (value ~= nil) and CXIdxObjectWrapper(value) or nil
            end
        end

        -- Try types with special handling.
        if (ffi.istype(const_char_ptr_t, value)) then
            return (value ~= nil) and ffi.string(value) or nil
        elseif (ffi.istype(CXIdxAttrInfoPtrPtr, value)) then
            assert(key == "attributes")
            return WrappedAttrInfoArray(value, self._obj.numAttributes)
        end

        -- TODO: functions like clang_index_getCXXClassDeclInfo().

        -- Expect an enum value.
        assert(type(value) == "cdata")
        assert(tostring(value):sub(1, 11) == "cdata<enum ")
        return value
    end
}

local function WrapIndexerCallback(funcName, userCallback)
    assert(type(funcName) == "string")
    assert(type(userCallback) == "function")

    local wrappers = {
        abortQuery = function(_, _)
            local shouldAbort = userCallback()
            check(type(shouldAbort) == "boolean", "return value must be boolean", 2)
            return (shouldAbort and 1 or 0)
        end,

        -- NOTE: callback 'diagnostic' not exposed.
        -- TODO: in callbacks returning 'CXIdxClient<Thing>', allow returning client value
        --  and attach it to Lua objects somehow?

        enteredMainFile = function(_, mainFile, _)
            assert(ffi.istype(CXFile, mainFile))
            -- NOTE: dummy parent.
            userCallback(File(mainFile, {}))
            return nil
        end,

        ppIncludedFile = function(_, cxIdxIncFileInfo)
            checkCXIdxObject(CXIdxPtrTypes.IncludedFileInfo, cxIdxIncFileInfo)
            userCallback(CXIdxObjectWrapper(cxIdxIncFileInfo))
            return nil
        end,

        importedASTFile = function(_, cxIdxImpASTFileInfo)
            checkCXIdxObject(CXIdxPtrTypes.ImportedAstFileInfo, cxIdxImpASTFileInfo)
            userCallback(CXIdxObjectWrapper(cxIdxImpASTFileInfo))
            return nil
        end,

        startedTranslationUnit = function(_, _)
            userCallback()
            return nil
        end,

        indexDeclaration = function(_, cxIdxDeclInfo)
            checkCXIdxObject(CXIdxPtrTypes.DeclInfo, cxIdxDeclInfo)
            userCallback(CXIdxObjectWrapper(cxIdxDeclInfo))
            return nil
        end,

        indexEntityReference = function(_, cxIdxEntityRefInfo)
            checkCXIdxObject(CXIdxPtrTypes.EntityRefInfo, cxIdxEntityRefInfo)
            userCallback(CXIdxObjectWrapper(cxIdxEntityRefInfo))
            return nil
        end,
    }

    local wrapper = wrappers[funcName]
    check(wrapper ~= nil,
          "unknown or unsupported indexer callback '"..funcName.."'", 3)
    return wrapper
end

local allIndexerCallbackFuncs = {}

function api.IndexerCallbacks(tab)
    check(type(tab) == "table", "argument must be a table", 2)

    local callbacks = ffi.new("IndexerCallbacks")
    local noGcCheck = false
    local isEmpty = true

    for funcName, func in pairs(tab) do
        check(type(funcName) == "string", "argument table must contain string keys", 2)

        if (funcName == "diagnostic") then
            -- do nothing
        elseif (funcName == "_noGcCheck") then
            noGcCheck = true
        else
            check(type(func) == "function", "argument table must contain function values", 2)
            -- TODO [LUA_FUNC_INTO_CDATA_FPTR]: without anchoring the Lua function here, the
            --  returned 'IndexerCallbacks' cdata value *does* get GC-collected! Why?
            allIndexerCallbackFuncs[#allIndexerCallbackFuncs + 1] = func
            -- NOTE: permanently anchors FFI callback.
            --  However, uncertain about exact intended LuaJIT behavior, see TODO above.
            callbacks[funcName] = WrapIndexerCallback(funcName, func)
            isEmpty = false
        end
    end

    return (isEmpty or noGcCheck) and callbacks or ffi.gc(callbacks, function(_)
        -- Force lifetime to the end of the program to prevent discarding of a temporary.
        -- (After freeing of the cdata, the anchored FFI callbacks would get leaked).
        error("Indexer callbacks are not supposed to be garbage-collected")
    end)
end

local IndexSession = class
{
    function(cxidxact, parent)
        assert(ffi.istype("CXIndexAction", cxidxact))
        assert(cxidxact ~= nil)
        assert(ffi.istype("CXIndex", parent._idx))

        return {
            _idxact = ffi.gc(cxidxact, clang.clang_IndexAction_dispose),
            _parent = parent,
        }
    end,

    indexSourceFile = function(self, callbacks, indexOpts,
                               srcfile, args, opts)
        local srcfile, args, opts, argsptrs, tuAr = PrepareParse(srcfile, args, opts)

        indexOpts = HandleNumberOrStringTabOption(
            indexOpts, C.CXIndexOpt_None, "CXIndexOpt_")

        check(ffi.istype("IndexerCallbacks", callbacks),
              "<callback> must be a an object obtained with IndexerCallbacks()", 2)

        local errorCode = clang.clang_indexSourceFile(
            self._idxact,
            nil, -- CXClientData client_data,
            callbacks, ffi.sizeof(callbacks),
            indexOpts,
            srcfile,
            argsptrs, #args,
            nil, 0,
            tuAr, opts)

        return FinishParse(tuAr, errorCode, self)
    end,
}

-------------------------------------------------------------------------
--------------------------------- Index ---------------------------------
-------------------------------------------------------------------------

local Index = class
{
    function(cxidx)
        assert(ffi.istype("CXIndex", cxidx))
        assert(cxidx ~= nil)
        return { _idx = ffi.gc(cxidx, clang.clang_disposeIndex) }
    end,

    createSession = function(self)
        return IndexSession(clang.clang_IndexAction_create(self._idx), self)
    end,

    loadTranslationUnit = function(self, filename)
        check(type(filename) == "string", "<filename> must be a string", 2)

        local cxtuAr = ffi.new("CXTranslationUnit [1]")
        local cxErrorCode = clang.clang_createTranslationUnit2(
            self._idx, filename, cxtuAr)

        if (cxErrorCode == 'CXError_Success') then
            return TranslationUnit_t(cxtuAr[0], self, true), cxErrorCode
        else
            return nil, cxErrorCode
        end
    end,

    -- #### `translationUnit, errorCode = index:parse(sourceFileName, cmdLineArgs [, opts])`
    --
    -- [`clang_parseTranslationUnit2`]:
    --  http://clang.llvm.org/doxygen/group__CINDEX__TRANSLATION__UNIT.html#ga494de0e725c5ae40cbdea5fa6081027d
    --
    -- [`CXTranslationUnit_*`]:
    --  http://clang.llvm.org/doxygen/group__CINDEX__TRANSLATION__UNIT.html#enum-members
    --
    -- Binding for [`clang_parseTranslationUnit2`]. This will parse a given source
    -- file named `sourceFileName` with the command line arguments `cmdLineArgs` given
    -- to the compiler, containing e.g. include paths or defines. If `sourceFile` is
    -- the empty string, the source file is expected to be named in `cmdLineArgs`.
    --
    -- The optional argument `opts` is expected to be a sequence containing
    -- [`CXTranslationUnit_*`] enum names without the `"CXTranslationUnit_"` prefix,
    -- for example `{ "DetailedPreprocessingRecord", "SkipFunctionBodies" }`.
    --
    -- NOTE: Both `cmdLineArgs` and `opts` (if given) must not contain an element at index 0.
    --
    -- On failure, `translationUnit` is `nil` and `errorCode` (comparable against
    -- values in `clang.ErrorCode`) can be examined.
    parse = function(self, srcfile, args, opts)
        local srcfile, args, opts, argsptrs, tuAr = PrepareParse(srcfile, args, opts)

        local errorCode = clang.clang_parseTranslationUnit2(
            self._idx, srcfile, argsptrs, #args, nil, 0, opts, tuAr)

        return FinishParse(tuAr, errorCode, self)
    end,
}

-------------------------------------------------------------------------
---------------------------- SourceLocation -----------------------------
-------------------------------------------------------------------------

local CXSourceLocation = ffi.typeof("CXSourceLocation")

local LineCol = ffi.metatype([[
union {
    struct { unsigned line, column; };
    unsigned ar[2];
}
]], {
    __eq = function(self, other)
        return self.line == other.line and self.column == other.column
    end
})

local LineColOfs = ffi.metatype([[
union {
    struct { unsigned line, column, offset; };
    unsigned ar[3];
}
]], {
    __eq = function(self, other)
        local isEqual = (self.offset == other.offset)
        assert((self.line == other.line and self.column == other.column) == isEqual)
        return isEqual
    end
})

-- Private SourceLocation functions
local SL = {
    getSite = function(self, clangFunction)
        local cxfilear = SingleCXFileArray()
        local lco = LineColOfs()
        clangFunction(self._loc, cxfilear, lco.ar, lco.ar+1, lco.ar+2)
        return File(cxfilear[0], self), lco
    end,

    getSiteOnlyLineCol = function(self, clangFunction)
        local cxstr = CXString()
        local lc = LineCol()
        clangFunction(self._loc, cxstr, lc.ar, lc.ar+1)
        return getString(cxstr), lc
    end
}

SourceLocation = class
{
    function(cxloc, parent)
        assert(ffi.istype(CXSourceLocation, cxloc))

        -- type(parent) can be: TODO?, TranslationUnit_t
        assert(type(parent) == "table")

        if (clang.clang_equalLocations(cxloc, clang.clang_getNullLocation()) ~= 0) then
            -- Return nil (and not a SourceLocation object) on invalid (null) location.
            return nil
        end

        return {
            _loc = cxloc,
            _parent = parent
        }
    end,

    __eq = function(self, other)
        -- NOTE: Lua 5.1 docs say (on the "eq"/"==" operation):
        --  A metamethod only is selected when both objects being compared have the same
        --  type and the same metamethod for the selected operation.
        -- Hence, we know that 'other' is a SourceLocation, too.
        assert(type(other) == "table")
        return (clang.clang_equalLocations(self._loc, other._loc) ~= 0)
    end,

    isInSystemHeader = function(self)
        return (clang.clang_Location_isInSystemHeader(self._loc) ~= 0)
    end,

    isFromMainFile = function(self)
        return (clang.clang_Location_isFromMainFile(self._loc) ~= 0)
    end,

    -- SourceLocation -> File + line/column/offset mapping functions.
    -- NOTE: compared to libclang, the suffix "Location" is replaced with "Site".

    -- libclang says:
    --  If the location refers into a macro expansion, retrieves the location of the macro
    --  expansion.
    expansionSite = function(self)
        return SL.getSite(self, clang.clang_getExpansionLocation)
    end,

    -- libclang says:
    --  If the location refers into a macro instantiation, return where the location was
    --  originally spelled in the source file.
    spellingSite = function(self)
        return SL.getSite(self, clang.clang_getSpellingLocation)
    end,

    -- libclang says:
    --  If the location refers into a macro expansion, return where the macro was expanded
    --  or where the macro argument was written, if the location points at a macro argument.
    fileSite = function(self)
        return SL.getSite(self, clang.clang_getFileLocation)
    end,

    -- libclang says:
    --  Retrieve the file, line and column represented by the given source location, as
    --  specified in a # line directive.
    --
    -- NOTE: what's returned is a *file name* (as opposed to a File like with the other
    --  three "Site" functions), plus a line+column object (without offset).
    presumedSite = function(self)
        return SL.getSiteOnlyLineCol(self, clang.clang_getPresumedLocation)
    end,
}

-------------------------------------------------------------------------
------------------------------- Diagnostic ------------------------------
-------------------------------------------------------------------------

local DiagnosticSet

-- TODO: have "safe enum" instead? Meaning: supported operations are:
--  * <safe-enum-value> == <string>: comparison with suffix (e.g. "Warning"), error if not
--    an enum constant
--  * tostring(<safe-enum-value>): returns suffix as string
--  * to/from number?
--  * relational comparison?
local SeverityEnumToString = {
    [tonumber(C.CXDiagnostic_Ignored)] = "ignored",
    [tonumber(C.CXDiagnostic_Note)] = "note",
    [tonumber(C.CXDiagnostic_Warning)] = "warning",
    [tonumber(C.CXDiagnostic_Error)] = "error",
    [tonumber(C.CXDiagnostic_Fatal)] = "fatal",
}

function api.defaultDiagnosticDisplayOptions()
    return clang.clang_defaultDiagnosticDisplayOptions()
end

local Diagnostic = class
{
    function(cxdiag, parent)
        assert(ffi.istype("CXDiagnostic", cxdiag))
        assert(cxdiag ~= nil)
        assert(type(parent) == "table")

        return {
            -- NOTE: since at least LLVM 7, disposal of a diagnostic is a no-op.
            -- (See libclang's CIndexDiagnostic.cpp.)
            -- So, do not attach a GC finalizer.
            _diag = cxdiag,
            _parent = parent
        }
    end,

    childDiagnostics = function(self)
        local cxdiagset = clang.clang_getChildDiagnostics(self._diag)
        return DiagnosticSet(cxdiagset, self)
    end,

    format = function(self, opts)
        opts = HandleNumberOrStringTabOption(
            opts, api.defaultDiagnosticDisplayOptions(), "CXDiagnostic_")
        return getString(clang.clang_formatDiagnostic(self._diag, opts))
    end,

    severity = function(self)
        local severityEnumValue = clang.clang_getDiagnosticSeverity(self._diag)
        return SeverityEnumToString[tonumber(severityEnumValue)]
    end,

    location = function(self)
        local cxsrcloc = clang.clang_getDiagnosticLocation(self._diag)
        return SourceLocation(cxsrcloc, self)
    end,

    spelling = function(self)
        return getString(clang.clang_getDiagnosticSpelling(self._diag))
    end,

    option = function(self)
        local disabledOptionCXString = CXString()
        local enabledOptionCXString = clang.clang_getDiagnosticOption(self._diag, disabledOptionCXString)
        -- TODO: test: what if there is no "option that disables this diagnostic" (from libclang doc)?
        --       Will we assert in getString() then?
        return getString(enabledOptionCXString), getString(disabledOptionCXString)
    end,

    category = function(self)
        return getString(clang.clang_getDiagnosticCategoryText(self._diag))
    end,

    -- TODO: ranges()?
    -- TODO: fixIts()?
}

-------------------------------------------------------------------------
----------------------------- DiagnosticSet -----------------------------
-------------------------------------------------------------------------

DiagnosticSet = class
{
    function(cxdiagset, parent)
        assert(ffi.istype("CXDiagnosticSet", cxdiagset))

        -- type(parent) can be: TODO?, TranslationUnit_t
        assert(type(parent) == "table")

        -- NOTE: do not attach a finalizer (which would be clang_disposeDiagnosticSet()):
        -- all our uses create "non-externally managed" CXDiagnosticSetImpl objects (see
        -- libclang's CIndexDiagnostic.h) which are not deleted on disposal -- the TU
        -- owns the diagnostics. In fact, doing so would be potentially harmful.
        --
        -- TODO: research GC order anomalies that were observed with the finalizer in place.

        local tab = { _parent = parent }

        if (cxdiagset ~= nil) then
            for i = 1, clang.clang_getNumDiagnosticsInSet(cxdiagset) do
                local cxdiag = clang.clang_getDiagnosticInSet(cxdiagset, i-1)
                tab[i] = Diagnostic(cxdiag, tab)
            end
        end

        return tab
    end,
}

-------------------------------------------------------------------------
---------------------------------- File ---------------------------------
-------------------------------------------------------------------------

local haveClangGetFileTime = false
local function setupClangGetFileTime()
    if (not haveClangGetFileTime) then
        -- CAUTION: problematic with mkapp.lua
        require("posix_types")
        ffi.cdef"time_t clang_getFileTime(CXFile SFile)"
        haveClangGetFileTime = true
    end
end

File = class
{
    function(cxfile, parent)
        check(ffi.istype(CXFile, cxfile), "<cxfile> must be a CXFile object", 2)
        assert(cxfile ~= nil) -- TODO: handle?

        -- table can be: SourceLocation, TranslationUnit_t
        -- TODO: clean this up.
        assert(type(parent) == "table")

        return {
            _cxfile = cxfile,
            _parent = parent
        }
    end,

    __eq = function(self, other)
        assert(type(other) == "table")
        return (clang.clang_File_isEqual(self._cxfile, other._cxfile) ~= 0)
    end,

    name = function(self)
        return getString(clang.clang_getFileName(self._cxfile))
    end,

    realPathName = function(self)
        return getString(clang.clang_File_tryGetRealPathName(self._cxfile))
    end,

    time = function(self)
        setupClangGetFileTime()
        return tonumber(clang.clang_getFileTime(self._cxfile))
    end,

    location = function(self, line, column)
        -- TODO: assert that _parent is a TU, or allow SourceLocation _parent
        local cxloc = clang.clang_getLocation(self._parent._tu, self._cxfile, line, column)
        return SourceLocation(cxloc, self)
    end,

    locationForOffset = function(self, offset)
        -- TODO: assert that _parent is a TU, or allow SourceLocation _parent
        local cxloc = clang.clang_getLocationForOffset(self._parent._tu, self._cxfile, offset)
        return SourceLocation(cxloc, self)
    end,

    -- Convenience functions

    isSystemHeader = function(self)
        return self:locationForOffset(0):isInSystemHeader()
    end,

    isMainFile = function(self)
        return self:locationForOffset(0):isFromMainFile()
    end,
}

-------------------------------------------------------------------------
---------------------------- TranslationUnit ----------------------------
-------------------------------------------------------------------------

-- TODO: remove?
local function check_tu_valid(self)
    assert(self._tu ~= nil)
end

-- Construct a Cursor_t from a libclang's CXCursor <cxcur>. If <cxcur> is the
-- NULL cursor, return nil.
local function getCursor(cxcur)
    return (clang.clang_Cursor_isNull(cxcur) == 0) and Cursor_t(cxcur) or nil
end

local function getFile(tu, filename)
    check(type(filename) == "string", "<filename> must be a string", 3)
    return clang.clang_getFile(tu, filename)
end

local WrappedSourceLocArray = WrappedArrayType(CXSourceLocation, function(cxsrcloc)
    -- NOTE/XXX: passing dummy parent as anchor. This is sort of OK in the specific
    -- usage context.
    return SourceLocation(cxsrcloc, {})
end)

TranslationUnit_t = class
{
    function(cxtu, parent, needsDisposal)
        assert(ffi.istype("CXTranslationUnit", cxtu))
        assert(cxtu ~= nil)
        assert(parent ~= nil) -- TODO: more precise?
        assert(type(needsDisposal) == "boolean")

        return {
            _tu = ffi.gc(cxtu, needsDisposal and clang.clang_disposeTranslationUnit or nil),
            _parent = parent,
        }
    end,

    save = function(self, filename)
        check_tu_valid(self)
        check(type(filename) == "string", "<filename> must be a string", 2)
        local intRes = clang.clang_saveTranslationUnit(self._tu, filename, 0)
        local res = ffi.new("enum CXSaveError", intRes)
        assert(res ~= 'CXSaveError_InvalidTU')
        return res
    end,

    cursor = function(self)
        check_tu_valid(self)
        local cxcur = clang.clang_getTranslationUnitCursor(self._tu)
        -- NOTE: no anchoring!
        return getCursor(cxcur)
    end,

    -- Incompatible with luaclang-parser: returns a File object (a wrapped CXFile).
    file = function(self, filename)
        check_tu_valid(self)
        check(type(filename) == "string", "<filename> must be a string", 3)
        local cxfile = clang.clang_getFile(self._tu, filename)
        return (cxfile ~= nil) and File(cxfile, self) or nil
    end,

    inclusions = function(self, visitor)
        check_tu_valid(self)
        check(type(visitor) == "function", "<visitor> must be a Lua function", 2)

        -- Create a "loose" translation unit from us, that is, one that is not associated
        -- with a finalizer. If we were to pass 'self' instead of 'looseTU', we would never
        -- be garbage-collected: it appears that crossing the boundary to the C++ side
        -- anchors the cdata object with a finalizer association.
        local looseCXTU = ffi.new("CXTranslationUnit", self._tu)
        local looseTU = TranslationUnit_t(looseCXTU, {}, false)

        local clangInclusionVisitor = function(includedFile, inclusionStackPtr, includeLength, _)
            local wrappedInclusionStack = WrappedSourceLocArray(inclusionStackPtr, includeLength)
            visitor(File(includedFile, looseTU), wrappedInclusionStack)
        end

        clang.clang_getInclusions(self._tu, clangInclusionVisitor, nil)
    end,

    diagnosticSet = function(self)
        check_tu_valid(self)
        local cxdiagset = clang.clang_getDiagnosticSetFromTU(self._tu)
        return DiagnosticSet(cxdiagset, self)
    end,
}

-------------------------------------------------------------------------
--------------------------------- Cursor --------------------------------
-------------------------------------------------------------------------

local LanguageEnumToString = {
    [tonumber(C.CXLanguage_Invalid)] = "invalid",
    [tonumber(C.CXLanguage_C)] = "c",
    [tonumber(C.CXLanguage_ObjC)] = "objc",
    [tonumber(C.CXLanguage_CPlusPlus)] = "c++",
}

local RefQualEnumToString = {
    [tonumber(C.CXRefQualifier_None)] = "none",
    [tonumber(C.CXRefQualifier_LValue)] = "lvalue",
    [tonumber(C.CXRefQualifier_RValue)] = "rvalue",
}

local function getType(cxtyp)
    return (cxtyp.kind ~= 'CXType_Invalid') and Type_t(cxtyp) or nil
end

-- Get line number, column number and offset for a given CXSourceRange
local function getLineColOfs(cxsrcrange, cxfile, clang_rangefunc)
    local cxsrcloc = clang[clang_rangefunc](cxsrcrange)
    local lco = LineColOfs()
    clang.clang_getSpellingLocation(cxsrcloc, cxfile, lco.ar, lco.ar+1, lco.ar+2)
    return lco
end

-- Returns a LineColOfs for the beginning and end of a range. Also, the file name.
local function getBegEndFilename(cxsrcrange)
    local cxfilear = SingleCXFileArray()
    local Beg = getLineColOfs(cxsrcrange, cxfilear, "clang_getRangeStart")
    local filename = getString(clang.clang_getFileName(cxfilear[0]))
    local End = getLineColOfs(cxsrcrange, cxfilear, "clang_getRangeEnd")
    return Beg, End, filename
end

local function getPresumedLineCol(cxsrcrange, clang_rangefunc)
    local cxsrcloc = clang[clang_rangefunc](cxsrcrange)
    local linecol = LineCol()
    local file = CXString()
    clang.clang_getPresumedLocation(cxsrcloc, file, linecol.ar, linecol.ar+1)
    return linecol, getString(file)
end

local function getSourceRange(cxcur)
    local cxsrcrange = clang.clang_getCursorExtent(cxcur)
    return (clang.clang_Range_isNull(cxsrcrange) == 0) and cxsrcrange or nil
end

-------------------------------- Visitation --------------------------------

-- #### `visitorHandle = clang.regCursorVisitor(visitorFunc)`
--
-- Registers a child visitor callback function `visitorFunc` with LJClang,
-- returning a handle which can be passed to `Cursor:children()`. The callback
-- function receives two input arguments, `(cursor, parent)` -- with the cursors
-- of the currently visited entity as well as its parent, and must return a value
-- from the `ChildVisitResult` enumeration to indicate whether or how libclang
-- should carry on AST visiting.
--
-- CAUTION: The `cursor` passed to the visitor callback is only valid during one
-- particular callback invocation. If it is to be used after the function has
-- returned, it **must** be copied using the `Cursor` constructor mentioned below.
local function wrapCursorVisitor(visitorFunc)
    check(type(visitorFunc)=="function", "<visitorfunc> must be a Lua function", 2)
    return LJCX_CursorVisitor(visitorFunc)
end

api.regCursorVisitor = wrapCursorVisitor

local Cursor_ptr_t = ffi.typeof("$ *", Cursor_t)

-- #### `permanentCursor = clang.Cursor(cursor)`
--
-- Creates a permanent cursor from one received by the visitor callback.
function api.Cursor(cur)
    check(ffi.istype(Cursor_ptr_t, cur), "<cur> must be a cursor as passed to the visitor callback", 2)
    return Cursor_t(cur[0])
end

-- Support for legacy luaclang-parser API collecting direct descendants of a
-- cursor: this will be the table where they go.
local collectTab

local CollectDirectChildren = wrapCursorVisitor(
function(cur)
    collectTab[#collectTab+1] = Cursor_t(cur[0])
    return 'CXChildVisit_Continue'
end)

----------------------------------------------------------------------------

class
{
    Cursor_t,

    -- NOTE: yes, 'other' is not necessarily a Cursor_t! LuaJIT seems to behave
    -- differently than plain Lua ("only called with identical metatables").
    __eq = function(self, other)
        if (ffi.istype(Cursor_t, self) and ffi.istype(Cursor_t, other)) then
            return (clang.clang_equalCursors(self._cur, other._cur) ~= 0)
        else
            return false
        end
    end,

    children = function(self, visitor)
        if (visitor ~= nil) then
            -- LJClang way of visiting
            local isFunction = (type(visitor) == "function")

            if (isFunction) then
                visitor = wrapCursorVisitor(visitor)
            else
                check(ffi.istype(LJCX_CursorVisitor, visitor),
                      "<visitor> must be a handle obtained with regCursorVisitor() or a Lua function", 2)
            end

            local ret = support.ljclang_visitChildrenWith(self._cur, visitor)

            if (isFunction) then
                visitor:free()
            end

            return (ret ~= 0)
        else
            -- luaclang-parser way
            assert(collectTab == nil, "children() must not be called while another invocation is active")

            collectTab = {}
            support.ljclang_visitChildrenWith(self._cur, CollectDirectChildren)
            local tab = collectTab
            collectTab = nil
            return tab
        end
    end,

    parent = function(self)
        return getCursor(clang.clang_getCursorSemanticParent(self._cur))
    end,

    __tostring = "name",

    name = function(self)
        return getString(clang.clang_getCursorSpelling(self._cur))
    end,

    displayName = function(self)
        return getString(clang.clang_getCursorDisplayName(self._cur))
    end,

    USR = function(self)
        return getString(clang.clang_getCursorUSR(self._cur))
    end,

    kind = function(self)
        local kindnum = tonumber(self:kindnum())
        local kindstr = g_CursorKindName[kindnum]
        return kindstr or "Unknown"
    end,

    language = function(self)
        local cxlanguagekind = clang.clang_getCursorLanguage(self._cur)
        return LanguageEnumToString[tonumber(cxlanguagekind)]
    end,

    templateKind = function(self)
        local kindnum = tonumber(clang.clang_getTemplateCursorKind(self._cur))
        local kindstr = g_CursorKindName[kindnum]
        return kindstr or "Unknown"
    end,

    arguments = function(self)
        local tab = {}
        local numargs = clang.clang_Cursor_getNumArguments(self._cur)
        for i=1,numargs do
            tab[i] = getCursor(clang.clang_Cursor_getArgument(self._cur, i-1))
        end
        return tab
    end,

    overloadedDecls = function(self)
        local tab = {}
        local numdecls = clang.clang_getNumOverloadedDecls(self._cur)
        for i=1,numdecls do
            tab[i] = getCursor(clang.clang_getOverloadedDecl(self._cur, i-1))
        end
        return tab
    end,

    overriddenCursors = function(self)
        local ptrAr = CXCursorPtrAr()
        local countAr = unsignedAr()
        clang.clang_getOverriddenCursors(self._cur, ptrAr, countAr)

        local count = countAr[0]
        local cursors = ptrAr[0]
        assert((count == 0) or (cursors ~= nil))

        local tab = {}
        for i=1,count do
            tab[i] = getCursor(cursors[i - 1])
        end

        clang.clang_disposeOverriddenCursors(cursors)

        return tab
    end,

    -- deprecate?
    location = function(self, linesfirst)
        local cxsrcrange = getSourceRange(self._cur)
        if (cxsrcrange == nil) then
            return nil
        end

        local Beg, End, filename = getBegEndFilename(cxsrcrange)

        if (linesfirst == 'offset') then
            return filename, Beg.offset, End.offset
        elseif (linesfirst) then
            -- LJClang order -- IMO you're usually more interested in the
            -- line number
            return filename, Beg.line, End.line, Beg.column, End.column, Beg.offset, End.offset
        else
            -- luaclang-parser order (offset: undocumented)
            return filename, Beg.line, Beg.column, End.line, End.column, Beg.offset, End.offset
        end
    end,

    referenced = function(self)
        return getCursor(clang.clang_getCursorReferenced(self._cur))
    end,

    definition = function(self)
        return getCursor(clang.clang_getCursorDefinition(self._cur))
    end,

    isDeleted = function(self)
        return clang.clang_CXX_isDeleted(self._cur) ~= 0
    end,

    isMutable = function(self)
        return clang.clang_CXXField_isMutable(self._cur) ~= 0
    end,

    isDefaulted = function(self)
        return clang.clang_CXXMethod_isDefaulted(self._cur) ~= 0
    end,

    isPureVirtual = function(self)
        return clang.clang_CXXMethod_isPureVirtual(self._cur) ~= 0
    end,

    isVirtual = function(self)
        return clang.clang_CXXMethod_isVirtual(self._cur) ~= 0
    end,

    isVirtualBase = function(self)
        check(self:haskind("CXXBaseSpecifier"), "cursor must have kind CXXBaseSpecifier", 2)
        return clang.clang_isVirtualBase(self._cur) ~= 0
    end,

    isOverride = function(self)
        return clang.clang_CXXMethod_isOverride(self._cur) ~= 0
    end,

    isStatic = function(self)
        return clang.clang_CXXMethod_isStatic(self._cur) ~= 0
    end,

    isConst = function(self)
        return clang.clang_CXXMethod_isConst(self._cur) ~= 0
    end,

    type = function(self)
        return getType(clang.clang_getCursorType(self._cur))
    end,

    resultType = function(self)
        return getType(clang.clang_getCursorResultType(self._cur))
    end,

    access = function(self)
        local spec = clang.clang_getCXXAccessSpecifier(self._cur);

        if (spec == 'CX_CXXPublic') then
            return "public"
        elseif (spec == 'CX_CXXProtected') then
            return "protected"
        elseif (spec == 'CX_CXXPrivate') then
            return "private"
        else
            assert(spec == 'CX_CXXInvalidAccessSpecifier')
            return nil
        end
    end,

    --== LJClang-specific ==--

    translationUnit = function(self)
        local cxtu = clang.clang_Cursor_getTranslationUnit(self._cur)
        -- NOTE: only invalid cursors have a nullptr TU. See libclang's CXCursor.cpp's
        -- MakeCXCursor() functions and MakeCXCursorInvalid() function.
        return TranslationUnit_t(cxtu, self, false)
    end,

    -- NOTE: Used to sometimes return one token too much:
    --   http://llvm.org/bugs/show_bug.cgi?id=9069
    -- TODO: is it good enough now?
    _tokens = function(self)
        local tu = self:translationUnit()
        local cxtu = tu._tu

        local _, b, e = self:location('offset')
        local cxsrcrange = getSourceRange(self._cur)
        if (cxsrcrange == nil) then
            return nil
        end

        local ntoksar = ffi.new("unsigned [1]")
        local tokensar = ffi.new("CXToken *[1]")
        clang.clang_tokenize(cxtu, cxsrcrange, tokensar, ntoksar)
        local numtoks = ntoksar[0]
        local tokens = tokensar[0]

        local tab = {}
        local tabextra = {}

        local kinds = {
            [tonumber(C.CXToken_Punctuation)] = 'Punctuation',
            [tonumber(C.CXToken_Keyword)] = 'Keyword',
            [tonumber(C.CXToken_Identifier)] = 'Identifier',
            [tonumber(C.CXToken_Literal)] = 'Literal',
            [tonumber(C.CXToken_Comment)] = 'Comment',
        }

        for i=0,numtoks-1 do
            if (clang.clang_getTokenKind(tokens[i]) ~= 'CXToken_Comment') then
                local sourcerange = clang.clang_getTokenExtent(cxtu, tokens[i])
                local Beg, End, filename = getBegEndFilename(sourcerange)
                local tb, te = Beg.offset, End.offset

                if (tb >= b and te <= e) then
                    local kind = clang.clang_getTokenKind(tokens[i])
                    local extent = getString(clang.clang_getTokenSpelling(cxtu, tokens[i]))
                    tab[#tab+1] = extent
                    tabextra[#tabextra+1] = {
                        extent = extent,
                        kind = kinds[tonumber(kind)],
                        b = b, e = e,
                        tb = tb, te = te
                    }
                end
            end
        end

        clang.clang_disposeTokens(cxtu, tokens, numtoks)

        return tab, tabextra
    end,

    lexicalParent = function(self)
        return getCursor(clang.clang_getCursorLexicalParent(self._cur))
    end,

    mangling = function(self)
        return getString(clang.clang_Cursor_getMangling(self._cur))
    end,

    baseTemplate = function(self)
        return getCursor(clang.clang_getSpecializedCursorTemplate(self._cur))
    end,

    -- Returns an enumeration constant, which in LuaJIT can be compared
    -- against a *string*, too. Even using arithmetic relational operators.
    kindnum = function(self)
        return clang.clang_getCursorKind(self._cur)
    end,

    haskind = function(self, kind)
        if (type(kind) == "string") then
            return self:kindnum() == C["CXCursor_"..kind]
        else
            return self:kindnum() == kind
        end
    end,

    enumIntegerType = function(self)
        check(self:haskind("EnumDecl"), "cursor must have kind EnumDecl", 2)
        local type = getType(clang.clang_getEnumDeclIntegerType(self._cur))
        assert(type ~= nil)
        return type
    end,

    enumValue = function(self)
        check(self:haskind("EnumConstantDecl"), "cursor must have kind EnumConstantDecl", 2)

        local type = self:parent():enumIntegerType()
        local obtainAsUnsigned = type:haskind("ULongLong")
            or (ffi.sizeof("long") == 8 and type:haskind("ULong"))

        if (obtainAsUnsigned) then
            return clang.clang_getEnumConstantDeclUnsignedValue(self._cur)
        else
            return clang.clang_getEnumConstantDeclValue(self._cur)
        end
    end,

    enumval = function(self)
        return tonumber(self:enumValue())
    end,

    isDefinition = function(self)
        return (clang.clang_isCursorDefinition(self._cur) ~= 0)
    end,

    isVariadic = function(self)
        return (clang.clang_Cursor_isVariadic(self._cur) ~= 0)
    end,

    typedefType = function(self)
        return getType(clang.clang_getTypedefDeclUnderlyingType(self._cur))
    end,
}

-------------------------------------------------------------------------
---------------------------------- Type ---------------------------------
-------------------------------------------------------------------------

local CXTypeLayoutError = ffi.typeof("enum CXTypeLayoutError")
local function TypeLayoutResult(llnum)
    return llnum >= 0 and tonumber(llnum) or CXTypeLayoutError(llnum)
end

class
{
    Type_t,

    __eq = function(typ1, typ2)
        if (ffi.istype(Type_t, typ1) and ffi.istype(Type_t, typ2)) then
            return (clang.clang_equalTypes(typ1._typ, typ2._typ) ~= 0)
        else
            return false
        end
    end,

    __tostring = "name",

    name = function(self)
        return getString(clang.clang_getTypeSpelling(self._typ))
    end,

    canonical = function(self)
        -- NOTE: no dispatching to getPointeeType() for pointer types like
        -- luaclang-parser.
        return getType(clang.clang_getCanonicalType(self._typ))
    end,

    pointee = function(self)
        return getType(clang.clang_getPointeeType(self._typ))
    end,

    resultType = function(self)
        return getType(clang.clang_getResultType(self._typ))
    end,

    arrayElementType = function(self)
        return getType(clang.clang_getArrayElementType(self._typ))
    end,

    arraySize = function(self)
        return tonumber(clang.clang_getArraySize(self._typ))
    end,

    isConst = function(self)
        return (clang.clang_isConstQualifiedType(self._typ) ~= 0);
    end,

    isConstQualified = "isConst",

    isPod = function(self)
        return (clang.clang_isPODType(self._typ) ~= 0);
    end,

    isFinal = function(self)
        return (clang.clang_isFinalType(self._typ) ~= 0);
    end,

    isAbstract = function(self)
        return (clang.clang_isAbstractType(self._typ) ~= 0);
    end,

    declaration = function(self)
        return getCursor(clang.clang_getTypeDeclaration(self._typ))
    end,

    --== LJClang-specific ==--

    -- Returns an enumeration constant.
    kindnum = function(self)
        return self._typ.kind
    end,

    haskind = function(self, kind)
        if (type(kind) == "string") then
            return self:kindnum() == "CXType_"..kind
        else
            return self:kindnum() == kind
        end
    end,

    size = function(self)
        return TypeLayoutResult(clang.clang_Type_getSizeOf(self._typ))
    end,

    alignment = function(self)
        return TypeLayoutResult(clang.clang_Type_getAlignOf(self._typ))
    end,

    bitOffsetOf = function(self, member)
        check(type(member) == "string", "argument must be a string", 2)
        return TypeLayoutResult(clang.clang_Type_getOffsetOf(self._typ, member))
    end,

    byteOffsetOf = function(self, member)
        local bitOffset = self:bitOffsetOf(member)
        -- NOTE: this may return a fractional value.
        return bitOffset < 0 and bitOffset or bitOffset / 8
    end,

    refQualifier = function(self)
        -- TODO: restrict the cursor kind?
        local cxxrefqual = clang.clang_Type_getCXXRefQualifier(self._typ)
        return RefQualEnumToString[tonumber(cxxrefqual)]
    end,

    templateArguments = function(self)
        local tab = {}
        local numargs = clang.clang_Type_getNumTemplateArguments(self._typ)
        for i=1,numargs do
            tab[i] = getType(clang.clang_Type_getTemplateArgumentAsType(self._typ, i-1))
        end
        return tab
    end,
}

-------------------------------------------------------------------------

-- #### `index = clang.createIndex([excludeDeclarationsFromPCH [, displayDiagnostics]])`
--
-- [`clang_createIndex`]:
--  http://clang.llvm.org/doxygen/group__CINDEX.html#ga51eb9b38c18743bf2d824c6230e61f93
--
-- Binding for [`clang_createIndex`]. Will create an `Index` into which you can
-- parse `TranslationUnit`s. Both input arguments are optional and default to
-- **false**.
function api.createIndex(excludeDeclarationsFromPCH, displayDiagnostics)
    local cxidx = clang.clang_createIndex(excludeDeclarationsFromPCH or false,
                                          displayDiagnostics or false)
    return Index(cxidx)
end

----------

api.splitAtWhitespace = util.splitAtWhitespace

-- NOTE: This is unsupported.
api.TranslationUnit_t = TranslationUnit_t
api.Cursor_t = Cursor_t
api.Type_t = Type_t

-- Done!
return api
