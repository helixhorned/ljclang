#!/usr/bin/env luajit

require 'busted.runner'()

local cl = require("ljclang")

local ffi = require("ffi")

ffi.cdef[[
time_t time(time_t *);
]]

describe("Loading a single cpp file", function()
    local fileName = "test_data/simple.cpp"

    local tu = cl.createIndex(true):parse(fileName, { "-std=c++11", "-Wall", "-pedantic" })
    -- Test that we don't need to keep the index (from createIndex()) around:
    collectgarbage()

    assert.is_not_nil(tu)

    it("tests the translation unit", function()
        local absFileName, modTime = tu:file(fileName)
        assert.is_not_nil(absFileName:find(fileName, 1, true))
        assert.is_true(ffi.C.time(nil) > modTime)
    end)

    it("tests the translation unit cursor", function()
        local tuCursor = tu:cursor()
        assert.is_true(tuCursor:haskind("TranslationUnit"))
        assert.are.equal(tuCursor, tuCursor)
    end)

    it("tests diagnostics", function()
        local diags = tu:diagnostics()
        assert.is_table(diags)
        assert.are.equal(#diags, 1)

        local diag = diags[1]
        assert.is_table(diag)

        assert.are.equal(diag.severity, cl.DiagnosticSeverity.Warning)
        assert.are.equal(diag.category, "Semantic Issue")
        assert.is_string(diag.text)
    end)

    describe("Collection of children", function()
        local tuCursor = tu:cursor()
        local expectedKinds = { "StructDecl", "FunctionDecl", "FunctionDecl" }

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
    end)
end)
