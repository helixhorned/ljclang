-- LuaJIT-based binding to libclang, modelled after
-- https://github.com/mkottman/luaclang-parser
--
-- See COPYRIGHT.TXT for the Copyright Notice of LJClang.
-- LICENSE_LLVM.TXT is the license for libclang.

local ffi = require("ffi")

local bit = require("bit")
local io = require("io")

local clang = ffi.load("clang")
require("ljclang_Index_h")

local assert = assert
local error = error
local setmetatable = setmetatable
local type = type
local unpack = unpack


--==========##########==========--


-- The table of externally exposed elements, returned at the end.
local api = {}


-- CXIndex is a pointer type, wrap it to be able to define a metatable.
local Index_t = ffi.typeof "struct { CXIndex _idx; }"
local TranslationUnit_t = ffi.typeof "struct { CXTranslationUnit _tu; }"
-- NOTE: CXCursor is a struct type by itself, but we wrap it to e.g. provide a
-- kind() *method* (CXCursor contains a member of the same name).
local Cursor_t = ffi.typeof "struct { CXCursor _cur; }"

-- A table mapping Index_t cdata objects to sequences (tables indexed by 1, 2,
-- ... some N) containing TranslationUnit_t objects.
local IndexTUs = setmetatable({}, {__mode="v"})

-- Metatable for our Index_t.
local Index_mt = {
    __index = {},

    __gc = function(self)
        local tunits = IndexTUs[self]
        IndexTUs[self] = nil
        -- "The index must not be destroyed until all of the translation units created
        --  within that index have been destroyed."
        for i=1,#tunits do
            tunits[i]:_cleanup()
        end
        clang.clang_disposeIndex(self._idx)
    end,
}

local function check_tu_valid(self)
    if (self._tu == nil) then
        error("Attempt to access freed TranslationUnit", 3)
    end
end

-- Convert from a libclang's encapsulated CXString to a plain Lua string and
-- dispose of the CXString afterwards.
local function getString(cxstr)
    local cstr = clang.clang_getCString(cxstr)
    assert(cstr ~= nil)
    local str = ffi.string(cstr)
    clang.clang_disposeString(cxstr)
    return str
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
                clang.clang_disposeTranslationUnit(self._tu)
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
            assert(type(filename)=="string", "<filename> must be a string")
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
                                         diag, clang.clang_defaultDiagnosticDisplayOptions()))
                }
                clang.clang_disposeDiagnostic(diag)
            end

            return tab
        end,
    },
}

TranslationUnit_mt.__gc = TranslationUnit_mt.__index._cleanup

-- Metatable for our Cursor_t.
local Cursor_mt = {
    __eq = function(cur1, cur2)
        return (clang.clang_equalCursors(cur1._cur, cur2._cur) ~= 0)
    end,

    __index = {
        parent = function(self)
            return getCursor(clang.clang_getSemanticParent(self._cur))
        end,

        name = function(self)
            return getString(clang.clang_getCursorSpelling(self._cur))
        end,

        displayName = function(self)
            return getString(clang.clang_getCursorDisplayName(self._cur))
        end,

        referenced = function(self)
            return getCursor(clang.clang_getCursorReferenced(self._cur))
        end,

        definition = function(self)
            return getCursor(clang.clang_getCursorDefinition(self._cur))
        end,

        isVirtual = function(self)
            return clang.clang_CXXMethod_isVirtual(self._cur)
        end,

        isStatic = function(self)
            return clang.clang_CXXMethod_isStatic(self._cur)
        end,

        --== LJClang-specific ==--

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
    },
}

Cursor_mt.__tostring = Cursor_mt.__index.name


--| index = clang.createIndex([excludeDeclarationsFromPCH [, displayDiagnostics]])
function api.createIndex(excludeDeclarationsFromPCH, displayDiagnostics)
    local cxidx = clang.clang_createIndex(excludeDeclarationsFromPCH, displayDiagnostics)
    if (cxidx == nil) then
        return nil
    end

    local index = Index_t(cxidx)
    IndexTUs[index] = {}

    return index
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
        assert(iscellstr(tab), name.." must be a string sequence when a table")
    end
end

--| tunit = index:parse([srcfile, ] args [, opts])
--|
--| <args>: string or sequence of strings
--| <opts>: number or sequence of strings (CXTranslationUnit_* enum members,
--|  without the prefix)
function Index_mt.__index.parse(self, srcfile, args, opts)
    if (type(args) ~= "string" and type(args) ~= "table") then
        -- Called us like index:parse(args [, opts]), shift input arguments
        opts = args
        args = srcfile
        srcfile = nil
    end

    -- Input argument type checking.

    assert(srcfile==nil or type(srcfile)=="string", "<srcfile> must be a string")

    assert(type(args)=="string" or type(args)=="table", "<args> must be a string or table")
    check_iftab_iscellstr(args, "<args>")

    if (opts == nil) then
        opts = 0
    else
        assert(type(opts)=="number" or type(opts)=="table")
        check_iftab_iscellstr(args, "<opts>")
    end

    -- Input argument handling.

    if (type(args)=="string") then
        local argstab = {}
        -- Split delimited by whitespace.
        for str in args:gmatch("[^%s]+") do
            argstab[#argstab+1] = str
        end
        args = argstab
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

    -- Register this TranslationUnit_t with its Index_t.
    local len = #IndexTUs[self]
    IndexTUs[self][len+1] = tunit

    return tunit
end


-- Register the metatables for the custom ctypes.
ffi.metatype(Index_t, Index_mt)
ffi.metatype(TranslationUnit_t, TranslationUnit_mt)
ffi.metatype(Cursor_t, Cursor_mt)

-- Done!
return api
