#!/usr/bin/env luajit

require 'busted.runner'()

local assert = assert
local describe = describe
local it = it

local collectgarbage = collectgarbage
local ipairs = ipairs
local rawequal = rawequal
local type = type
local tostring = tostring
local unpack = unpack

local cl = require("ljclang")

local ffi = require("ffi")

local io = require("io")
local math = require("math")

ffi.cdef[[
time_t time(time_t *);
]]

local nonExistentFileName = "/non_exisitent_file"
assert(io.open(nonExistentFileName) == nil)

----------

local clangOpts = { "-std=c++14", "-Wall", "-pedantic" }

describe("Attempting to parse a nonexistent file", function()
    local index = cl.createIndex()
    local tu, errorCode = index:parse(nonExistentFileName, { "-std=c99" })
    assert.is_nil(tu)
    assert.are.not_equal(errorCode, cl.ErrorCode.Success)
end)

local function assertParseWasSuccess(tu, errorCode)
    assert.is_not_nil(tu)
    assert.are.equal(errorCode, cl.ErrorCode.Success)
end

describe("Loading a cpp file without includes", function()
    local fileName = "test_data/simple.hpp"
    local astFileName = "/tmp/ljclang_test_simple.hpp.ast"

    local tu, errorCode = cl.createIndex():parse(fileName, clangOpts)

    -- Test that we don't need to keep the index (from createIndex()) around:
    collectgarbage()

    assertParseWasSuccess(tu, errorCode)

    describe("Translation unit", function()
        it("tests tu:file()", function()
            local file = tu:file(fileName)
            local obtainedFileName, modTime = file:name(), file:time()
            local absoluteFileName = file:realPathName()

            assert.is_true(type(obtainedFileName) == "string")
            assert.is_true(type(absoluteFileName) == "string")
            assert.is_true(type(modTime) == "number")

            assert.is_true(file:isMainFile())
            assert.is_false(file:isSystemHeader())

            assert.is_true(obtainedFileName == fileName)
            assert.is_true(absoluteFileName:sub(1,1) == "/")
            assert.is_not_nil(absoluteFileName:match("/.+/"..fileName.."$"))
            assert.is_true(ffi.C.time(nil) > modTime)
        end)

        -- TODO: location in a system header, location outside a system header but not in
        -- the main file either.

        -- TODO: SourceLocation:__eq

        -- TODO: SourceLocation:*Site() functions, also documenting their differences by
        -- test code.

        it("tests tu:location()", function()
            assert.is_nil(tu:file(nonExistentFileName))

            local file = tu:file(fileName)
            local loc = file:location(5, 4)
            assert.is_not_nil(loc)
            assert.is_false(loc:isInSystemHeader())
            assert.is_true(loc:isFromMainFile())
        end)

        it("tests tu:locationFromOffset()", function()
            assert.is_nil(tu:file(nonExistentFileName))

            local file = tu:file(fileName)
            local loc = file:locationForOffset(10)
            assert.is_not_nil(loc)
            assert.is_false(loc:isInSystemHeader())
            assert.is_true(loc:isFromMainFile())
        end)

        it("tests its cursor", function()
            local tuCursor = tu:cursor()
            assert.are.equal(tuCursor, tuCursor)
            -- Test that the following two forms are equivalent:
            assert.is_true(tuCursor:haskind("TranslationUnit"))
            assert.are.equal(tuCursor:kind(), "TranslationUnit")
        end)

        it("tests diagnostics from it using tu:diagnosticSet()", function()
            local diags = tu:diagnosticSet()
            assert.are.equal(#diags, 1)

            local diag = diags[1]

            assert.are.equal(diag:severity(), "warning")
            assert.are.equal(diag:category(), "Semantic Issue")
            assert.is_string(diag:spelling())
        end)

        it("tests loading a nonexistent translation unit", function()
            local newIndex = cl.createIndex()
            local newTU, status = newIndex:loadTranslationUnit(nonExistentFileName)
            assert.is_nil(newTU)
            assert.are.equal(status, cl.ErrorCode.Failure)
        end)

        it("tests saving and loading it", function()
            local saveError = tu:save(astFileName)
            assert.are.equal(saveError, cl.SaveError.None)

            local newIndex = cl.createIndex(true)
            local loadedTU, status = newIndex:loadTranslationUnit(astFileName)
            assert.is_not_nil(loadedTU)
            assert.are.equal(status, cl.ErrorCode.Success)
        end)
    end)

    describe("Collection of children", function()
        local tuCursor = tu:cursor()
        local expectedKinds = {
            "StructDecl", "FunctionDecl", "EnumDecl", "FunctionDecl", "EnumDecl"
        }

        it("tests the luaclang-parser convention", function()
            local kinds = {}
            for i, cur in ipairs(tuCursor:children()) do
                kinds[i] = cur:kind()
            end
            assert.are.same(kinds, expectedKinds)
        end)

        local V = cl.ChildVisitResult

        it("tests the ljclang convention: passing a Lua function to cursor:children(),"..
               " checking that visitor callback objects are freed", function()
            -- From http://luajit.org/ext_ffi_semantics.html#callback_resources
            --
            -- "Callbacks take up resources -- you can only have a limited number
            -- of them at the same time (500 - 1000, depending on the
            -- architecture)."
            local numLoops = 490

            collectgarbage()
            local memInUseBefore = collectgarbage("count")

            for i = 1, numLoops do
                local a, b = math.random(), math.random()

                tuCursor:children(function()
                    return (a + b >= 1) and V.Recurse or V.Continue
                end)
            end

            collectgarbage()
            local memUsageGrowth = collectgarbage("count") / memInUseBefore - 1

            -- As determined experimentally, that value is very permissive: it was
            -- rather around one permille. Without freeing the callbacks, the
            -- memory usage grew by around 7 percent though.
            --
            -- Note that we do leak memory though, even if only a small amount. Is
            -- this because the Lua functions are not collected?
            -- From http://luajit.org/ext_ffi_semantics.html#callback_resources
            --
            --  "The associated Lua functions are anchored to prevent garbage
            --  collection, too."
            assert.is_true(memUsageGrowth < 0.01)
        end)

        it("tests the ljclang convention: Break", function()
            local i = 0
            local visitor = cl.regCursorVisitor(
                function() i = i+1; return V.Break; end)

            tuCursor:children(visitor)
            assert.is_equal(i, 1)
        end)

        it("tests the ljclang convention: Continue + cursor copying", function()
            local i = 0

            local visitor = cl.regCursorVisitor(
            function(cur)
                i = i + 1
                assert.are.equal(cur:kind(), expectedKinds[i])
                assert.are.equal(cl.Cursor(cur), cur)
                return V.Continue
            end)

            tuCursor:children(visitor)
        end)

        it("tests the ljclang convention: Recurse", function()
            local expectedMembers = {{ "int", "a" }, { "long", "b" }}
            local expectedRefQuals = { "none", "lvalue", "rvalue" }

            local members, refQuals = {}, {}

            local visitor = cl.regCursorVisitor(
            function(cur)
                if (cur:haskind("StructDecl")) then
                    assert.is_equal(cur:name(), "First")
                    return V.Recurse
                end

                if (cur:haskind("FieldDecl")) then
                    members[#members + 1] = { cur:type():name(), cur:name() }
                elseif (cur:haskind("CXXMethod")) then
                    refQuals[#refQuals + 1] = cur:type():refQualifier()
                end

                return V.Continue
            end)

            tuCursor:children(visitor)
            assert.are.same(members, expectedMembers)
            assert.are.same(refQuals, expectedRefQuals)
        end)
    end)
end)

local function writeToFile(fileName, string)
    local f = io.open(fileName, 'w')
    f:write(string..'\n')
    f:close()
end

local function concatTables(...)
    local sourceTables = {...}
    local tab = {}

    for ti=1,#sourceTables do
        local sourceTab = sourceTables[ti]
        assert(type(sourceTab) == "table")

        for i=1,#sourceTab do
            tab[#tab + 1] = sourceTab[i]
        end
    end

    return tab
end

describe("Loading a file with includes", function()
    local fileName1 = "/tmp/ljclang_test_includes_simple.cpp"
    local fileName2 = "/tmp/ljclang_test_includes_enums.cpp"

    writeToFile(fileName1, '#include "simple.hpp"')
    writeToFile(fileName2, '#include "enums.hpp"')

    local additionalOpts = {"-Itest_data/"}
    local clangOpts = concatTables(clangOpts, additionalOpts)

    it("tests passing a single source file name", function()
        local tu, errorCode = cl.createIndex():parse(fileName1, clangOpts)
        assertParseWasSuccess(tu, errorCode)
    end)

    it("tests passing multiple source file names (1)", function()
        local clangOpts = concatTables(clangOpts, {fileName1, fileName2})
        local tu, errorCode = cl.createIndex():parse("", clangOpts)
        assert.is_nil(tu)
        assert.are.equal(errorCode, cl.ErrorCode.ASTReadError)
    end)

    it("tests passing multiple source file names (2)", function()
        local clangOpts = concatTables(clangOpts, {fileName2})
        local tu, errorCode = cl.createIndex():parse(fileName1, clangOpts)
        assert.is_nil(tu)
        assert.are.equal(errorCode, cl.ErrorCode.ASTReadError)
    end)
end)

local function GetTU(fileName, expectedDiagCount)
    local tu = cl.createIndex():parse(fileName, clangOpts)
    assert.is_not_nil(tu)
    local diags = tu:diagnosticSet()
    assert.are.equal(#diags, expectedDiagCount or 0)
    return tu
end

describe("Enumerations", function()
    local tu = GetTU("test_data/enums.hpp")
    local tuCursor = tu:cursor()

    it("tests various queries on enumerations", function()
        local s, u = "ctype<int64_t>", "ctype<uint64_t>"

        local expectedEnums = {
            { Name = "Fruits",
              IntType = "int",
              { "Apple", 0, s },
              { "Pear", -4, s },
              { "Orange", -3, s }
            },

            { Name = "BigNumbers",
              IntType = "unsigned long long",
              { "Billion", 1000000000, u },
              { "Trillion", 1000000000000, u }
            },

            { Name = "",
              IntType = "short",
              { "Red", 0, s },
              { "Green", 1, s },
              { "Blue", 2, s }
            }
        }

        local enums = {}

        for _, enumDeclCur in ipairs(tuCursor:children()) do
            assert.are.equal(enumDeclCur:kind(), "EnumDecl")

            local integerType = enumDeclCur:enumIntegerType()
            assert.is_not_nil(integerType)

            enums[#enums + 1] = {
                Name = enumDeclCur:name(),
                IntType = integerType:name(),
            }

            for _, cur in ipairs(enumDeclCur:children()) do
                assert.are.equal(cur:kind(), "EnumConstantDecl")

                local val = cur:enumval()
                local value = cur:enumValue()

                assert.is_number(val)
                assert.is_true(type(value) == "cdata")
                assert.are_equal(value, val)

                local enumTable = enums[#enums]
                enumTable[#enumTable + 1] = { cur:name(), val, tostring(ffi.typeof(value)) }
            end
        end

        assert.are_same(expectedEnums, enums)
    end)
end)

describe("Virtual functions", function()
    local tu = GetTU("test_data/virtual.hpp")
    local tuCursor = tu:cursor()

    local classDefs = tuCursor:children()
    assert.is.equal(#classDefs, 5)
    classDefs[5] = nil  -- EnumDecl for another test case

    local I, B, D, F = unpack(classDefs)
    local Ic, Bc, Dc, Fc = I:children(), B:children(), D:children(), F:children()

    it("tests the number of children of each class definition", function()
        assert.are.same({#Ic, #Bc, #Dc, #Fc}, {2, 3, 3, 3})
    end)

    -- Obtain the cursors for our reference function "getIt()".
    local Ir, Br, Dr, Fr = Ic[1], Bc[#Bc], Dc[#Dc], Fc[2]

    it("tests that the cursors refer to functions with identical signature", function()
        assert.are.same({Ir:kind(), Br:kind(), Dr:kind(), Fr:kind()},
                        {"CXXMethod", "CXXMethod", "CXXMethod", "CXXMethod"})
        local sig = Ir:displayName()
        assert.is_true(sig == "getIt()")
        assert.is.equal(sig, Br:displayName())
        assert.is.equal(sig, Dr:displayName())
        assert.is.equal(sig, Fr:displayName())
    end)

    it("tests Cursor:virtualBase()", function()
        assert.has_error(function() tuCursor:isVirtualBase() end,
                         "cursor must have kind CXXBaseSpecifier")
        assert.is.equal(Dc[1]:displayName(), "class Base")
        assert.is_false(Dc[1]:isVirtualBase())
        assert.is.equal(Dc[2]:displayName(), "class Interface")
        assert.is_true(Dc[2]:isVirtualBase())
    end)

    it("tests Cursor:overriddenCursors()", function()
        assert.are.same(Ir:overriddenCursors(), {})
        assert.are.same(Br:overriddenCursors(), {})

        local Do = Dr:overriddenCursors()
        assert.is_true(type(Do) == "table")
        assert.are.same(Do, {Br, Ir})

        assert.are.same(Fr:overriddenCursors(), {Dr})
    end)
end)

describe("Cross-referencing", function()
    local tuDef = GetTU("test_data/enums.hpp")  -- contains definition of enum BigNumbers
    local tuDecl = GetTU("test_data/simple.hpp", 1)  -- a declaration
    local tuMisDecl = GetTU("test_data/virtual.hpp")  -- a mis-declaration (wrong underlying type)

    local USRs = {}
    local declCursors, defCursors = {}, {}

    for i, tu in ipairs({tuDef, tuDecl, tuMisDecl}) do
        tu:cursor():children(function(cur)
            if (cur:haskind("EnumDecl") and cur:name() == "BigNumbers") then
                USRs[#USRs + 1] = cur:USR()
                declCursors[i] = cl.Cursor(cur)
                defCursors[i] = cur:definition()
            end
            return cl.ChildVisitResult.Continue
        end)
    end

    it("tests USRs", function()
        assert.is_true(#USRs == 3)
        assert.is.equal(USRs[1], USRs[2])
        -- The underlying type of an enum is not part of its mangling.
        assert.is.equal(USRs[1], USRs[3])
    end)

    it("tests Cursor:definition()", function()
        assert.are.same(defCursors, {declCursors[1], nil, nil})
    end)
end)
