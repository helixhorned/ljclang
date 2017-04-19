#!/usr/bin/env luajit

require 'busted.runner'()

local assert = assert
local describe = describe
local it = it

local ipairs = ipairs
local type = type
local tostring = tostring

local cl = require("ljclang")

local ffi = require("ffi")

ffi.cdef[[
time_t time(time_t *);
]]

describe("Loading a cpp file without includes", function()
    local fileName = "test_data/simple.cpp"
    local astFileName = "/tmp/ljclang_test_simple.cpp.ast"
    local nonExistentFileName = "/non_exisitent_file"

    assert(io.open(nonExistentFileName) == nil)

    it("tests attempting to parse a nonexistent file", function()
        local index = cl.createIndex()
        local tu, errorCode = index:parse(nonExistentFileName, { "-std=c99" })
        assert.is_nil(tu)
        assert.are.not_equal(errorCode, cl.ErrorCode.Success)
    end)

    local tu, errorCode = cl.createIndex(true):parse(
        fileName, { "-std=c++14", "-Wall", "-pedantic" })

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

        it("tests its cursor", function()
            local tuCursor = tu:cursor()
            assert.is_true(tuCursor:haskind("TranslationUnit"))
            assert.are.equal(tuCursor, tuCursor)
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
            "StructDecl", "FunctionDecl", "EnumDecl", "EnumDecl",
            "StaticAssert", "FunctionDecl"
        }

        it("tests the luaclang-parser convention", function()
            local cursors = tuCursor:children()

            assert.is_table(cursors)
            assert.are.equal(#cursors, #expectedKinds)

            for i, cur in ipairs(cursors) do
                assert.is_true(cur:haskind(expectedKinds[i]))
            end
        end)

        local V = cl.ChildVisitResult

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
                assert.is_true(cur:haskind(expectedKinds[i]))
                assert.are.equal(cl.Cursor(cur), cur)
                return V.Continue
            end)

            tuCursor:children(visitor)
        end)

        it("tests the ljclang convention: Continue + Recurse; enums", function()
            local s, u = "ctype<int64_t>", "ctype<uint64_t>"

            local expectedEnums = {
                -- From 'enum Fruits':
                { "Apple", 0, s },
                { "Pear", -4, s },
                { "Orange", -3, s },

                -- From 'enum BigNumbers':
                { "Billion", 1000000000, u },
                { "Trillion", 1000000000000, u },
            }

            local enums = {}

            local visitor = cl.regCursorVisitor(
            function(cur)
                if (cur:haskind("EnumDecl")) then
                    return V.Recurse
                end

                if (cur:haskind("EnumConstantDecl")) then
                    local val = cur:enumval()
                    local value = cur:enumValue()

                    assert.is_number(val)
                    assert.is_true(type(value) == "cdata")
                    assert.are_equal(value, val)

                    enums[#enums + 1] = { cur:name(), val, tostring(ffi.typeof(value)) }
                end

                return V.Continue
            end)

            tuCursor:children(visitor)
            assert.are_same(expectedEnums, enums)
        end)
    end)
end)
