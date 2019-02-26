#!/usr/bin/env luajit

require 'busted.runner'()

local assert = assert
local describe = describe
local it = it

local collectgarbage = collectgarbage
local ipairs = ipairs
local type = type
local tostring = tostring

local cl = require("ljclang")

local ffi = require("ffi")

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

describe("Loading a cpp file without includes", function()
    local fileName = "test_data/simple.hpp"
    local astFileName = "/tmp/ljclang_test_simple.hpp.ast"

    local tu, errorCode = cl.createIndex():parse(fileName, clangOpts)

    -- Test that we don't need to keep the index (from createIndex()) around:
    collectgarbage()

    assert.is_not_nil(tu)
    assert.are.equal(errorCode, cl.ErrorCode.Success)

    describe("Translation unit", function()
        it("tests tu:file()", function()
            local absFileName, modTime = tu:file(fileName)
            assert.is_not_nil(absFileName:find(fileName, 1, true))
            assert.is_true(ffi.C.time(nil) > modTime)
        end)

        -- TODO: location in a system header, location outside a system header but not in
        -- the main file either.

        it("tests tu:location()", function()
            assert.is_nil(tu:location(nonExistentFileName, 1, 1))

            local loc = tu:location(fileName, 5, 4)
            assert.is_not_nil(loc)
            assert.is_false(loc:isInSystemHeader())
            assert.is_true(loc:isFromMainFile())
        end)

        it("tests tu:locationFromOffset()", function()
            assert.is_nil(tu:locationForOffset(nonExistentFileName, 1))

            local loc = tu:locationForOffset(fileName, 10)
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

        it("tests diagnostics from it", function()
            local diags = tu:diagnostics()
            assert.is_table(diags)
            assert.are.equal(#diags, 1)

            local diag = diags[1]
            assert.is_table(diag)

            assert.are.equal(diag.severity, cl.DiagnosticSeverity.Warning)
            assert.are.equal(diag.category, "Semantic Issue")
            assert.is_string(diag.text)
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
            "StructDecl", "FunctionDecl", "EnumDecl", "FunctionDecl"
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
            local expectedMembers = {
                { "int", "a" }, { "long", "b" }
            }

            local members = {}

            local visitor = cl.regCursorVisitor(
            function(cur)
                if (cur:haskind("StructDecl")) then
                    assert.is_equal(cur:name(), "First")
                    return V.Recurse
                end

                if (cur:haskind("FieldDecl")) then
                    members[#members + 1] = { cur:type():name(), cur:name() }
                end

                return V.Continue
            end)

            tuCursor:children(visitor)
            assert.are.same(members, expectedMembers)
        end)
    end)
end)

describe("Enumerations", function()
    local fileName = "test_data/enums.hpp"

    local tu = cl.createIndex():parse(fileName, clangOpts)
    assert.is_not_nil(tu)
    assert.are.same(tu:diagnostics(), {})

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
