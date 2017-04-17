-- LuaJIT-based binding to libclang, modelled after
-- https://github.com/mkottman/luaclang-parser
--
-- See COPYRIGHT.TXT for the Copyright Notice of LJClang.
-- LICENSE_LLVM.TXT is the license for libclang.

local assert = assert
local error = error
local print = print
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

local clang = ffi.load(lib"clang")
require("ljclang_Index_h")
local support = ffi.load(lib"ljclang_support")
local g_CursorKindName = require("ljclang_cursor_kind").name

ffi.cdef("const char *ljclang_getLLVMVersion();")
local supportLLVMVersion = ffi.string(support.ljclang_getLLVMVersion())

-------------------------------------------------------------------------

-- The table of externally exposed elements, returned at the end.
local api = {}

--[[
local function debugf(fmt, ...)
    print(string.format("ljclang: "..fmt, ...))
end
--[=[]]
local function debugf() end
--]=]

-- Wrap 'error' in assert-like call to write type checks in one line instead of
-- three.
local function check(pred, msg, level)
    if (not pred) then
        error(msg, level+1)
    end
end

-- CXIndex is a pointer type, wrap it to be able to define a metatable.
local Index_t = ffi.typeof "struct { CXIndex _idx; }"
local TranslationUnit_t_ = ffi.typeof "struct { CXTranslationUnit _tu; }"
-- NOTE: CXCursor is a struct type by itself, but we wrap it to e.g. provide a
-- kind() *method* (CXCursor contains a member of the same name).
local Cursor_t = ffi.typeof "struct { CXCursor _cur; }"
local Type_t = ffi.typeof "struct { CXType _typ; }"

-- CompilationDatabase types
local CompilationDatabase_t = ffi.typeof "struct { CXCompilationDatabase _ptr; }"
local CompileCommands_t = ffi.typeof "struct { CXCompileCommands _ptr; const double numCommands; }"
local CompileCommand_t = ffi.typeof[[
struct {
    CXCompileCommand _ptr;
    const double numArgs, numSources;
}
]]

-- [<address of CXTranslationUnit as string>] = count
local TUCount = {}

local function getCXTUaddr(cxtu)
    return tostring(cxtu):gsub(".*: 0x", "")
end

local function TranslationUnit_t(cxtu)
    local addr = getCXTUaddr(cxtu)
    TUCount[addr] = (TUCount[addr] or 0) + 1
    return TranslationUnit_t_(cxtu)
end

-- Our wrapping type Cursor_t is seen as raw CXCursor on the C side.
assert(ffi.sizeof("CXCursor") == ffi.sizeof(Cursor_t))

ffi.cdef([[
typedef enum CXChildVisitResult (*LJCX_CursorVisitor)(
    $ *cursor, $ *parent, CXClientData client_data);
]], Cursor_t, Cursor_t)

ffi.cdef[[
int ljclang_regCursorVisitor(LJCX_CursorVisitor visitor, enum CXCursorKind *kinds, int numkinds);
int ljclang_visitChildren(CXCursor parent, int visitoridx);
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
    assert(cstr ~= nil)
    local str = ffi.string(cstr)
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
-------------------------- CompilationDatabase --------------------------
-------------------------------------------------------------------------

-- newargs = api.stripArgs(args, pattern, num)
function api.stripArgs(args, pattern, num)
    assert(args[0] == nil)
    local numArgs = #args

    for i=1,numArgs do
        if (args[i] and args[i]:find(pattern)) then
            for j=0,num-1 do
                args[i+j] = nil
            end
        end
    end

    local newargs = {}
    for i=1,numArgs do
        newargs[#newargs+1] = args[i]
    end
    return newargs
end

local CompDB_Error_Ar = ffi.typeof[[
CXCompilationDatabase_Error [1]
]]

local CompileCommand_mt = {
    __index = {
        -- args = cmd:getArgs([alsoCompilerExe])
        -- args: sequence table. If <alsoCompilerExe> is true, args[0] is the
        --  compiler executable.
        getArgs = function(self, alsoCompilerExe)
            local args = {}
            for i = (alsoCompilerExe and 0 or 1), self.numArgs-1 do
                local cxstr = clang.clang_CompileCommand_getArg(self._ptr, i)
                args[i] = getString(cxstr)
            end

            return args
        end,

        -- dir = cmd:getDirectory()
        getDirectory = function(self)
            local cxstr = clang.clang_CompileCommand_getDirectory(self._ptr)
            return getString(cxstr)
        end,

        -- paths = cmd:getSourcePaths()
        -- paths: sequence table.
        getSourcePaths = function(self)
            -- XXX: This is a workaround implementation due to a missing
            -- clang_CompileCommand_getMappedSourcePath symbol in libclang.so,
            -- see commented out code below.
            local args = self:getArgs()
            for i=1,#args do
                if (args[i] == '-c' and args[i+1]) then
                    local sourceFile = args[i+1]
                    if (sourceFile:sub(1,1) ~= "/") then  -- XXX: Windows
                        sourceFile = self:getDirectory() .. "/" .. sourceFile
                    end
                    return { sourceFile }
                end
            end

            print(table.concat(args, ' '))
            check(false, "Did not find -c option (workaround for missing "..
                      "clang_CompileCommand_getMappedSourcePath symbol)")
--[[
            local paths = {}
            for i=0,self.numSources-1 do
                -- XXX: for me, the symbol is missing in libclang.so:
                local cxstr = clang.clang_CompileCommand_getMappedSourcePath(self._ptr, i)
                paths[i] = getString(cxstr)
            end
            return paths
--]]
        end,
    },
}

local CompileCommands_mt = {
    -- #commands: number of commands
    __len = function(self)
        return self.numCommands
    end,

    -- commands[i]: get the i'th CompileCommand object (i is 1-based)
    __index = function(self, i)
        check(type(i) == "number", "<i> must be a number", 2)
        check(i >= 1 and i <= self.numCommands, "<i> must be in [1, numCommands]", 2)
        local cmdPtr = clang.clang_CompileCommands_getCommand(self._ptr, i-1)
        local numArgs = clang.clang_CompileCommand_getNumArgs(cmdPtr)
        local numSources = 0 --clang.clang_CompileCommand_getNumMappedSources(cmdPtr)
        return CompileCommand_t(cmdPtr, numArgs, numSources)
    end,

    __gc = function(self)
        clang.clang_CompileCommands_dispose(self._ptr)
    end,
}

local CompilationDatabase_mt = {
    __index = {
        getCompileCommands = function(self, completeFileName)
            check(type(completeFileName) == "string", "<completeFileName> must be a string", 2)
            local cmdsPtr = clang.clang_CompilationDatabase_getCompileCommands(
                self._ptr, completeFileName)
            local numCommands = clang.clang_CompileCommands_getSize(cmdsPtr)
            return CompileCommands_t(cmdsPtr, numCommands)
        end,

        getAllCompileCommands = function(self)
            local cmdsPtr = clang.clang_CompilationDatabase_getAllCompileCommands(self._ptr)
            local numCommands = clang.clang_CompileCommands_getSize(cmdsPtr)
            return CompileCommands_t(cmdsPtr, numCommands)
        end,
    },

    __gc = function(self)
        clang.clang_CompilationDatabase_dispose(self._ptr)
    end,
}

-- compDB = api.CompilationDatabase(buildDir)
function api.CompilationDatabase(buildDir)
    check(type(buildDir) == "string", "<buildDir> must be a string", 2)

    local errAr = CompDB_Error_Ar()
    local ptr = clang.clang_CompilationDatabase_fromDirectory(buildDir, errAr)
    assert(ptr ~= nil or errAr[0] ~= 'CXCompilationDatabase_NoError')

    return ptr ~= nil and CompilationDatabase_t(ptr) or nil
end

-------------------------------------------------------------------------
--------------------------------- Index ---------------------------------
-------------------------------------------------------------------------

-- Metatable for our Index_t.
local Index_mt = {
    __index = {},

    __gc = function(self)
        -- "The index must not be destroyed until all of the translation units created
        --  within that index have been destroyed."
        for i=1,#self._tus do
            self._tus[i]:_cleanup()
        end
        clang.clang_disposeIndex(self._idx)
    end,
}

local function NewIndex(cxidx)
    assert(ffi.istype("CXIndex", cxidx))
    -- _tus is a list of the Index_t's TranslationUnit_t objects.
    local index = { _idx=cxidx, _tus={} }
    return setmetatable(index, Index_mt)
end

-------------------------------------------------------------------------
---------------------------- TranslationUnit ----------------------------
-------------------------------------------------------------------------

local function check_tu_valid(self)
    if (self._tu == nil) then
        error("Attempt to access freed TranslationUnit", 3)
    end
end

-- Construct a Cursor_t from a libclang's CXCursor <cxcur>. If <cxcur> is the
-- NULL cursor, return nil.
local function getCursor(cxcur)
    return (clang.clang_Cursor_isNull(cxcur) == 0) and Cursor_t(cxcur) or nil
end

-- Metatable for our TranslationUnit_t.
local TranslationUnit_mt = {
    __index = {
        _cleanup = function(self)
            if (self._tu ~= nil) then
                local addr = getCXTUaddr(self._tu)
                TUCount[addr] = TUCount[addr]-1
                if (TUCount[addr] == 0) then
                    clang.clang_disposeTranslationUnit(self._tu)
                    TUCount[addr] = nil
                end
                self._tu = nil
            end
        end,

        cursor = function(self)
            check_tu_valid(self)
            local cxcur = clang.clang_getTranslationUnitCursor(self._tu)
            return getCursor(cxcur)
        end,

        file = function(self, filename)
            check_tu_valid(self)
            if (type(filename) ~= "string") then
                error("<filename> must be a string", 2)
            end
            local cxfile = clang.clang_getFile(self._tu, filename)
            return getString(clang.clang_getFileName(cxfile))  -- NYI: modification time
        end,

        diagnostics = function(self)
            check_tu_valid(self)

            local numdiags = clang.clang_getNumDiagnostics(self._tu)
            local tab = {}

            for i=0,numdiags-1 do
                local diag = clang.clang_getDiagnostic(self._tu, i)
                tab[i+1] = {
                    category = getString(clang.clang_getDiagnosticCategoryText(diag)),
                    text = getString(clang.clang_formatDiagnostic(
                                         diag, clang.clang_defaultDiagnosticDisplayOptions())),
                    severity = clang.clang_getDiagnosticSeverity(diag),
                }
                clang.clang_disposeDiagnostic(diag)
            end

            return tab
        end,
    },
}

TranslationUnit_mt.__gc = TranslationUnit_mt.__index._cleanup

-------------------------------------------------------------------------
--------------------------------- Cursor --------------------------------
-------------------------------------------------------------------------

local function getType(cxtyp)
    return cxtyp.kind ~= 'CXType_Invalid' and Type_t(cxtyp) or nil
end

local CXFileAr = ffi.typeof("CXFile [1]")

local LineCol = ffi.typeof[[
union {
    struct { unsigned line, col; };
    unsigned ar[2];
}
]]

local LineColOfs = ffi.typeof[[
union {
    struct { unsigned line, col, offset; };
    unsigned ar[3];
}
]]

-- Get line number, column number and offset for a given CXSourceRange
local function getLineColOfs(cxsrcrange, cxfile, clang_rangefunc)
    local cxsrcloc = clang[clang_rangefunc](cxsrcrange)
    local lco = LineColOfs()
    clang.clang_getSpellingLocation(cxsrcloc, cxfile, lco.ar, lco.ar+1, lco.ar+2)
    return lco
end

-- Returns a LineColOfs for the beginning and end of a range. Also, the file name.
local function getBegEndFilename(cxsrcrange)
    local cxfilear = CXFileAr()
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

-- Metatable for our Cursor_t.
local Cursor_mt = {
    __eq = function(cur1, cur2)
        if (ffi.istype(Cursor_t, cur1) and ffi.istype(Cursor_t, cur2)) then
            return (clang.clang_equalCursors(cur1._cur, cur2._cur) ~= 0)
        else
            return false
        end
    end,

    __index = {
        parent = function(self)
            return getCursor(clang.clang_getCursorSemanticParent(self._cur))
        end,

        name = function(self)
            return getString(clang.clang_getCursorSpelling(self._cur))
        end,

        displayName = function(self)
            return getString(clang.clang_getCursorDisplayName(self._cur))
        end,

        kind = function(self)
            local kindnum = tonumber(self:kindnum())
            local kindstr = g_CursorKindName[kindnum]
            return kindstr or "Unknown"
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
                return filename, Beg.line, End.line, Beg.col, End.col, Beg.offset, End.offset
            else
                -- luaclang-parser order (offset: XXX)
                return filename, Beg.line, Beg.col, End.line, End.col, Beg.offset, End.offset
            end
        end,

        presumedLocation = function(self, linesfirst)
            local cxsrcrange = getSourceRange(self._cur)
            if (cxsrcrange == nil) then
                return nil
            end

            local Beg, filename = getPresumedLineCol(cxsrcrange, "clang_getRangeStart")
            local End = getPresumedLineCol(cxsrcrange, "clang_getRangeEnd")

            if (linesfirst) then
                return filename, Beg.line, End.line, Beg.col, End.col
            else
                return filename, Beg.line, Beg.col, End.line, End.col
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
            return TranslationUnit_t(clang.clang_Cursor_getTranslationUnit(self._cur))
        end,

        -- XXX: Should be a TranslationUnit_t method instead.
        --
        -- NOTE: *Sometimes* returns one token too much, see
        --   http://clang-developers.42468.n3.nabble.com/querying-information-about-preprocessing-directives-in-libclang-td2740612.html
        -- Related bug report:
        --   http://llvm.org/bugs/show_bug.cgi?id=9069
        -- Also, see TOKENIZE_WORKAROUND in extractdecls.lua
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

        baseTemplate = function(self)
            return getCursor(clang.clang_getSpecializedCursorTemplate(self._cur))
        end,

        -- Returns an enumeration constant, which in LuaJIT can be compared
        -- against a *string*, too.
        kindnum = function(self)
            return clang.clang_getCursorKind(self._cur)
        end,

        haskind = function(self, kind)
            if (type(kind) == "string") then
                return self:kindnum() == "CXCursor_"..kind
            else
                return self:kindnum() == kind
            end
        end,

        enumValue = function(self, unsigned)
            if (not self:haskind("EnumConstantDecl")) then
                error("cursor must have kind EnumConstantDecl", 2)
            end

            if (unsigned) then
                return clang.clang_getEnumConstantDeclUnsignedValue(self._cur)
            else
                return clang.clang_getEnumConstantDeclValue(self._cur)
            end
        end,

        enumval = function(self, unsigned)
            return tonumber(self:enumValue(unsigned))
        end,

        isDefinition = function(self)
            return (clang.clang_isCursorDefinition(self._cur) ~= 0)
        end,

        typedefType = function(self)
            return getType(clang.clang_getTypedefDeclUnderlyingType(self._cur))
        end,
    },
}

Cursor_mt.__tostring = Cursor_mt.__index.name

-------------------------------------------------------------------------
---------------------------------- Type ---------------------------------
-------------------------------------------------------------------------

-- Metatable for our Type_t.
local Type_mt = {
    __eq = function(typ1, typ2)
        if (ffi.istype(Type_t, typ1) and ffi.istype(Type_t, typ2)) then
            return (clang.clang_equalTypes(typ1._typ, typ2._typ) ~= 0)
        else
            return false
        end
    end,

    __index = {
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

        templateArguments = function(self)
            local tab = {}
            local numargs = clang.clang_Type_getNumTemplateArguments(self._typ)
            for i=1,numargs do
                tab[i] = getType(clang.clang_Type_getTemplateArgumentAsType(self._typ, i-1))
            end
            return tab
        end,
    },
}

-- Aliases
local Type__index = Type_mt.__index
Type__index.isConstQualified = Type__index.isConst

Type_mt.__tostring = Type__index.name

-------------------------------------------------------------------------

--| index = clang.createIndex([excludeDeclarationsFromPCH [, displayDiagnostics]])
function api.createIndex(excludeDeclarationsFromPCH, displayDiagnostics)
    local cxidx = clang.clang_createIndex(excludeDeclarationsFromPCH or false,
                                          displayDiagnostics or false)
    if (cxidx == nil) then
        return nil
    end

    return NewIndex(cxidx)
end

-- argstab = clang.splitAtWhitespace(args)
function api.splitAtWhitespace(args)
    assert(type(args) == "string")
    local argstab = {}
    -- Split delimited by whitespace.
    for str in args:gmatch("[^%s]+") do
        argstab[#argstab+1] = str
    end
    return argstab
end

-- Is <tab> a sequence of strings?
local function iscellstr(tab)
    for i=1,#tab do
        if (type(tab[i]) ~= "string") then
            return false
        end
    end

    -- We require this because in ARGS_FROM_TAB below, an index 0 would be
    -- interpreted as the starting index.
    return (tab[0] == nil)
end

local function check_iftab_iscellstr(tab, name)
    if (type(tab)=="table") then
        if (not iscellstr(tab)) then
            error(name.." must be a string sequence when a table with no element at [0]", 3)
        end
    end
end

--| tunit = index:parse(srcfile, args [, opts])
--|
--| <args>: string or sequence of strings
--| <opts>: number or sequence of strings (CXTranslationUnit_* enum members,
--|  without the prefix)
function Index_mt.__index.parse(self, srcfile, args, opts)
    check(type(srcfile)=="string", "<srcfile> must be a string", 2)
    check(type(args)=="string" or type(args)=="table", "<args> must be a string or table", 2)
    check_iftab_iscellstr(args, "<args>")

    if (srcfile == "") then
        srcfile = nil
    end

    if (opts == nil) then
        opts = 0
    else
        check(type(opts)=="number" or type(opts)=="table", 2)
        check_iftab_iscellstr(args, "<opts>")
    end

    -- Input argument handling.

    if (type(args)=="string") then
        args = api.splitAtWhitespace(args)
    end

    if (type(opts)=="table") then
        local optflags = {}
        for i=1,#opts do
            optflags[i] = clang["CXTranslationUnit_"..opts[i]]  -- look up the enum
        end
        opts = bit.bor(unpack(optflags))
    end

    local argsptrs = ffi.new("const char * [?]", #args, args)  -- ARGS_FROM_TAB

    -- Create the CXTranslationUnit.
    local tunitptr = clang.clang_parseTranslationUnit(
        self._idx, srcfile, argsptrs, #args, nil, 0, opts)

    if (tunitptr == nil) then
        return nil
    end

    -- Wrap it in a TranslationUnit_t.
    local tunit = TranslationUnit_t(tunitptr)

    -- Add this TranslationUnit_t to the list of its Index_t's TUs.
    self._tus[#self._tus+1] = tunit

    return tunit
end


-- enum CXChildVisitResult constants
api.ChildVisitResult = ffi.new[[struct{
    static const int Break = 0;
    static const int Continue = 1;
    static const int Recurse = 2;
}]]

function api.regCursorVisitor(visitorfunc)
    check(type(visitorfunc)=="function", "<visitorfunc> must be a Lua function", 2)

    local ret = support.ljclang_regCursorVisitor(visitorfunc, nil, 0)
    if (ret < 0) then
        error("failed registering visitor function, code "..ret, 2)
    end

    return ret
end

local Cursor_ptr_t = ffi.typeof("$ *", Cursor_t)

function api.Cursor(cur)
    check(ffi.istype(Cursor_ptr_t, cur), "<cur> must be a cursor as passed to the visitor callback", 2)
    return Cursor_t(cur[0])
end

-- Support for legacy luaclang-parser API collecting direct descendants of a
-- cursor: this will be the table where they go.
local collectTab

local function collectDirectChildren(cur)
    debugf("collectDirectChildren: %s, child cursor kind: %s", tostring(collectTab), cur:kind())
    collectTab[#collectTab+1] = Cursor_t(cur[0])
    return 1  -- Continue
end

local cdc_visitoridx = api.regCursorVisitor(collectDirectChildren)

function Cursor_mt.__index.children(self, visitoridx)
    if (visitoridx ~= nil) then
        -- LJClang way of visiting
        local ret = support.ljclang_visitChildren(self._cur, visitoridx)
        return (ret ~= 0)
    else
        -- luaclang-parser way
        if (collectTab ~= nil) then
            error("children() must not be called while another invocation is active", 2)
            collectTab = nil
        end

        collectTab = {}
        -- XXX: We'll be blocked if the visitor callback errors.
        support.ljclang_visitChildren(self._cur, cdc_visitoridx)
        local tab = collectTab
        collectTab = nil
        return tab
    end
end


-- Register the metatables for the custom ctypes.
ffi.metatype(Index_t, Index_mt)
ffi.metatype(TranslationUnit_t_, TranslationUnit_mt)
ffi.metatype(Cursor_t, Cursor_mt)
ffi.metatype(Type_t, Type_mt)

ffi.metatype(CompileCommand_t, CompileCommand_mt)
ffi.metatype(CompileCommands_t, CompileCommands_mt)
ffi.metatype(CompilationDatabase_t, CompilationDatabase_mt)

api.Index_t = Index_t
api.TranslationUnit_t = TranslationUnit_t_
api.Cursor_t = Cursor_t
api.Type_t = Type_t

-- Done!
return api
