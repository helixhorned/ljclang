#!/usr/bin/env luajit

-- NOTE: on Raspbian, we need to require ljclang before busted, otherwise we get
--  error "wrong number of type parameters" for ffi.cdef 'typedef enum CXChildVisitResult'.
local cl = require("ljclang")
local llvm_libdir_include = require("llvm_libdir_include")[1]
local posix = require("posix")
local symbol_index = require("symbol_index")
local SymbolIndex = symbol_index.SymbolIndex

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

local ffi = require("ffi")
local C = ffi.C

local io = require("io")
local os = require("os")
local math = require("math")
local string = require("string")

ffi.cdef[[
time_t time(time_t *);
]]

local nonExistentFileName = "/non_exisitent_file"
assert(io.open(nonExistentFileName) == nil)

----------

--== posix.lua

describe("posix.lua", function()
    it("tests Dir", function()
        local dir = posix.Dir("./test_data")

        local ExpectedFileCount = 4
        local haveFile = {}

        for i = 1, ExpectedFileCount + 2 do
            local fileName = dir:read()
            assert.is_true(type(fileName) == "string")
            assert.is_nil(haveFile[fileName])
            haveFile[fileName] = true
        end

        assert.is_nil(dir:read())

        assert.is_true(haveFile["."])
        assert.is_true(haveFile["simple.hpp"])
    end)

    it("tests fd_set_t", function()
        local MaxFdToTest = 65
        local FdsToTest = { 7, 8+1, 16+2, 24+3, 31, 32, 33, 63, 64, MaxFdToTest }

        local fdSet = posix.fd_set_t()
        local fds = {}  -- posix.Fd objects for anchoring

        repeat
            local i = C.open("/dev/zero", posix.O.RDONLY)
            -- POSIX says: "All functions that open one or more file descriptors shall (...)
            --  allocate the lowest numbered available (...) file descriptor (...)."
            assert(i >= 0 and i <= FdsToTest[#fds + 1])
            local fd = posix.Fd(i)

            if (i == FdsToTest[#fds + 1]) then
                fds[#fds + 1] = fd
                fdSet:set(i)
            end
        until (i == FdsToTest[#FdsToTest])

        assert(#fds, #FdsToTest)

        -- Close the file descriptors we do not care about.
        collectgarbage()

        local IsFdTested = {}
        for _, i in ipairs(FdsToTest) do
            IsFdTested[i] = true
        end

        for i = 0, MaxFdToTest+1 do
            assert.is_equal(fdSet:isSet(i), IsFdTested[i] or false)
        end

        local function getBitsSetCount()
            local setBitsCount = 0
            for i = 0, MaxFdToTest + 1 do
                if (fdSet:isSet(i)) then
                    setBitsCount = setBitsCount + 1
                    assert.is_true(IsFdTested[i])
                end
            end
            return setBitsCount
        end

        repeat
            local fdReadyCount = C.select(MaxFdToTest + 1, fdSet, nil, nil, nil)
            assert.is_equal(fdReadyCount, #fds)
            assert.is_equal(getBitsSetCount(), fdReadyCount)

            -- Exercise fdSet:clear()
            fdSet:clear(fds[#fds].fd)
            fds[#fds] = nil
        until (#fds == 0)

        -- Close the remaining file descriptors.
        fds = nil
        collectgarbage()
    end)
end)

describe("Symbol index", function()
    it("tests repeated creation and destruction", function()
        local CreateCount = 100

        for i = 1, CreateCount do
            local symIndex = SymbolIndex(4)
            symIndex = nil
            collectgarbage()
        end
    end)

    local LocalPageArrayCount = 4
    local LocalPageArrayIdx = 2
    assert(LocalPageArrayIdx <= LocalPageArrayCount)
    local LocalPageIdx = 3
    local EntryIdx = 45
    assert(EntryIdx < symbol_index.EntriesPerPage)
    local RefNum = 123000321

    local function testChildToParent()
        local symIndex = SymbolIndex(LocalPageArrayCount)
        local parentPage = symIndex.localPageArrays[LocalPageArrayIdx][LocalPageIdx]
        assert.is_equal(parentPage[EntryIdx].intFlags, 0)

        local whoami, pid = posix.fork()

        if (whoami == "child") then
            local page = symIndex.localPageArrays[LocalPageArrayIdx][LocalPageIdx]
            if (page[EntryIdx].intFlags ~= 0) then
                os.exit(1)
            end
            page[EntryIdx].intFlags = RefNum
            os.exit(0)
        else
            local status, exitCode = posix.waitpid(pid, 0)
            assert.is_equal(status, "exited")
            assert.is_equal(exitCode, 0)
            assert.is_equal(parentPage[EntryIdx].intFlags, RefNum)
        end

        return symIndex
    end

    it("tests that the parent can read a local page written to by the child", function()
        testChildToParent()
        collectgarbage()
    end)

    it("tests in addition that the parent can remap a local page to a global one", function()
        local symIndex = testChildToParent()

        local GlobalPageIdx = 6
        local gPage = symIndex.globalPageArray[GlobalPageIdx]

        assert.is_equal(gPage[EntryIdx].intFlags, 0)
        symIndex:remapLocalToGlobalPage(LocalPageArrayIdx, LocalPageIdx, GlobalPageIdx)
        assert.is_equal(gPage[EntryIdx].intFlags, RefNum)

        symIndex = nil
        collectgarbage()
    end)
end)

--== ljclang

local CreateTUFuncs = {
    -- NOTE: The varargs here are: srcfile, args, opts.
    --  (args: arguments passed to the compiler, used here only to pass Clang *options*,
    --   opts: 'CXTranslationUnit_*' flags.
    --  Yes, the terminology has the potential to confuse.)

    function(index, ...)
        return index:parse(...)
    end,

    function(index, ...)
        return index:createSession():indexSourceFile(
            cl.IndexerCallbacks{}, nil, ...)
    end,
}

local function describe2(title, func)
    for i, createTU in ipairs(CreateTUFuncs) do
        local tag = (i == 1) and "direct" or "session"
        describe(title.." ["..tag.."]", function()
            func(createTU)
        end)
    end
end

local clangOpts = { "-std=c++14", "-Wall", "-pedantic" }

local function GetTU(createTU, fileName,
                     -- optional:
                     expectedDiagCount, opts)
    local tu = createTU(cl.createIndex(),
                        fileName, (opts ~= nil) and opts or clangOpts)
    assert.is_not_nil(tu)
    local diags = tu:diagnosticSet()
    assert.are.equal(#diags, expectedDiagCount or 0)
    return tu
end

describe2("Attempting to parse a nonexistent file", function(createTU)
    local index = cl.createIndex()
    local tu, errorCode = createTU(index, nonExistentFileName, { "-std=c99" })
    assert.is_nil(tu)
    assert.are.not_equal(errorCode, cl.ErrorCode.Success)
end)

local function assertParseWasSuccess(tu, errorCode)
    assert.is_not_nil(tu)
    assert.are.equal(errorCode, cl.ErrorCode.Success)
end

local ASTFileName = "/tmp/ljclang_test_simple.hpp.ast"

describe2("Loading a cpp file without includes", function(createTU)
    local fileName = "test_data/simple.hpp"

    local tu, errorCode = createTU(cl.createIndex(), fileName, clangOpts)

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
            assert.is_true(C.time(nil) > modTime)
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

        it("tests obtaining and discarding diagnostics many times", function()
            collectgarbage()
            local memInUseBefore = collectgarbage("count")

            for i = 1, 1000 do
                tu:diagnosticSet()
            end

            collectgarbage()
            local memUsageGrowth = collectgarbage("count") / memInUseBefore - 1.0

            assert.is_true(memUsageGrowth < 0.02)
        end)

        it("tests loading a nonexistent translation unit", function()
            local newIndex = cl.createIndex()
            local newTU, status = newIndex:loadTranslationUnit(nonExistentFileName)
            assert.is_nil(newTU)
            assert.are.equal(status, cl.ErrorCode.Failure)
        end)

        it("tests saving and loading it", function()
            local saveError = tu:save(ASTFileName)
            assert.are.equal(saveError, cl.SaveError.None)

            local newIndex = cl.createIndex(true)
            local loadedTU, status = newIndex:loadTranslationUnit(ASTFileName)
            assert.is_not_nil(loadedTU)
            assert.are.equal(status, cl.ErrorCode.Success)
        end)
    end)

    describe("Collection of children", function()
        local tuCursor = tu:cursor()
        local expectedKinds = {
            "StructDecl", "FunctionDecl", "EnumDecl", "FunctionDecl", "EnumDecl", "ClassDecl"
        }

        it("tests the luaclang-parser convention", function()
            local kinds, isVariadic = {}, {}

            for i, cur in ipairs(tuCursor:children()) do
                kinds[i] = cur:kind()
                isVariadic[i] = cur:isVariadic()
            end

            assert.are.same(kinds, expectedKinds)
            assert.are.same(isVariadic, { false, false, false, true, false, false })
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
            local memUsageGrowth = collectgarbage("count") / memInUseBefore - 1.0

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
                { "int", "a", ffi.sizeof("int"), ffi.alignof("int") },
                { "long", "b", ffi.sizeof("long"), ffi.alignof("long") }
            }
            local expectedRefQuals = { "none", "lvalue", "rvalue" }

            local members, refQuals = {}, {}

            local visitor = cl.regCursorVisitor(
            function(cur)
                if (cur:haskind("StructDecl")) then
                    assert.is_equal(cur:name(), "First")
                    local ty = cur:type()
                    assert.is_equal(type(ty:size()), "number")
                    assert.is_equal(type(ty:alignment()), "number")
                    assert.is_equal(ty:byteOffsetOf("a"), 0)
                    assert.is_equal(ty:byteOffsetOf("b"), ffi.alignof("long"))
                    assert.is_equal(ty:bitOffsetOf("b"), 8*ffi.alignof("long"))
                    assert.is_equal(ty:bitOffsetOf(""), C.CXTypeLayoutError_InvalidFieldName)
                    return V.Recurse
                elseif (cur:haskind("ClassDecl")) then
                    assert.is_equal(cur:name(), "Incomplete")
                    assert.is_equal(cur:type():size(), C.CXTypeLayoutError_Incomplete)
                end

                if (cur:haskind("FieldDecl")) then
                    local ty = cur:type()
                    members[#members + 1] = {
                        ty:name(), cur:name(), ty:size(), ty:alignment()
                    }
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

describe2("Loading a file with includes", function(createTU)
    local fileName1 = "/tmp/ljclang_test_includes_simple.cpp"
    local fileName2 = "/tmp/ljclang_test_includes_enums.cpp"

    writeToFile(fileName1, '#include "simple.hpp"')
    writeToFile(fileName2, '#include "enums.hpp"')

    local additionalOpts = {"-Itest_data/"}
    local clangOpts = concatTables(clangOpts, additionalOpts)

    it("tests passing a single source file name", function()
        local tu, errorCode = createTU(cl.createIndex(), fileName1, clangOpts)
        assertParseWasSuccess(tu, errorCode)

        local callCount = 0

        local incs = tu:inclusions(function(includedFile, stack)
            callCount = callCount + 1

            assert.is_false(includedFile:isSystemHeader())
            assert.is_equal(#stack, callCount - 1)

            if (#stack > 0) then
                assert.is_false(stack[1]:isInSystemHeader())
                assert.is_true(stack[1]:isFromMainFile())
            end
        end)

        assert.is_equal(callCount, 2)
    end)

    local expectedError = (createTU == CreateTUFuncs[1]) and
        cl.ErrorCode.ASTReadError or cl.ErrorCode.Failure

    it("tests passing multiple source file names (1)", function()
        local clangOpts = concatTables(clangOpts, {fileName1, fileName2})
        local tu, errorCode = createTU(cl.createIndex(), "", clangOpts)
        assert.is_nil(tu)
        assert.are.equal(errorCode, expectedError)
    end)

    it("tests passing multiple source file names (2)", function()
        local clangOpts = concatTables(clangOpts, {fileName2})
        local tu, errorCode = createTU(cl.createIndex(), fileName1, clangOpts)
        assert.is_nil(tu)
        assert.are.equal(errorCode, expectedError)
    end)
end)

describe2("Enumerations", function(createTU)
    local tu = GetTU(createTU, "test_data/enums.hpp")
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

describe2("Virtual functions", function(createTU)
    local tu = GetTU(createTU, "test_data/virtual.hpp")
    local tuCursor = tu:cursor()

    local classDefs = tuCursor:children()
    assert.is.equal(#classDefs, 6)
    classDefs[5] = nil  -- EnumDecl for another test case
    classDefs[6] = nil  -- namespace

    local I, B, D, F = unpack(classDefs)
    local Ic, Bc, Dc, Fc = I:children(), B:children(), D:children(), F:children()

    it("tests the number of children of each class definition", function()
        assert.are.same({#Ic, #Bc, #Dc, #Fc}, {3, 3, 3, 3})
    end)

    -- Obtain the cursors for our reference function "getIt()".
    local Ir, Br, Dr, Fr = Ic[2], Bc[#Bc], Dc[#Dc], Fc[2]

    it("tests that the cursors refer to functions with identical signature", function()
        assert.are.same({Ir:kind(), Br:kind(), Dr:kind(), Fr:kind()},
                        {"CXXMethod", "CXXMethod", "CXXMethod", "CXXMethod"})
        local sig = Ir:displayName()
        assert.is_true(sig == "getIt()")
        assert.is.equal(sig, Br:displayName())
        assert.is.equal(sig, Dr:displayName())
        assert.is.equal(sig, Fr:displayName())
    end)

    it("tests Cursor:isDefinition()", function()
        for _, defCursor in ipairs(classDefs) do
            assert.is_true(defCursor:isDefinition())
        end
        for _, declCursor in ipairs({Ir, Br, Dr}) do
            assert.is_false(declCursor:isDefinition())
        end
        assert.is_true(Fr:isDefinition())
    end)

    -- NOTE: this thematically belongs to test case "Cross-referencing",
    -- but fits here test-implementation-wise.
    it("tests Cursor:referenced()", function()
        assert.is.equal(Dc[1]:kind(), "CXXBaseSpecifier")
        assert.is.equal(Dc[2]:kind(), "CXXBaseSpecifier")

        local typeRefs = {
            Dc[1]:children()[1],
            Dc[2]:children()[1]
        }

        for _, typeRef in ipairs(typeRefs) do
            assert.is_not_nil(typeRef)
            assert.is.equal(typeRef:kind(), "TypeRef")
            assert.is_not_nil(typeRef:referenced())
        end

        assert.is.equal(typeRefs[1]:referenced(), B)
        assert.is.equal(typeRefs[2]:referenced(), I)
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

describe2("Cross-referencing", function(createTU)
    local tuDef = GetTU(createTU, "test_data/enums.hpp")  -- contains definition of enum BigNumbers
    local tuDecl = GetTU(createTU, "test_data/simple.hpp", 1)  -- a declaration
    local tuMisDecl = GetTU(createTU, "test_data/virtual.hpp")  -- a mis-declaration (wrong underlying type)

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

local function testMangling(createTU)
    local tu = GetTU(createTU, "dev/empty.cpp", 0,
                     {"-std=c++11", "-include", "thread",
                      "-isystem", llvm_libdir_include},
                     {"Incomplete", "SkipFunctionBodies"})

    local V = cl.ChildVisitResult
    local mangling = nil

    tu:cursor():children(function(cur)
        if (cur:kind() == "Namespace" and cur:name() == "std") then
            return V.Recurse
        elseif (cur:kind() == "ClassDecl" and cur:name() == "thread") then
            return V.Recurse
        elseif (cur:kind() == "CXXMethod" and cur:name() == "hardware_concurrency") then
            mangling = cur:mangling()
        end

        return V.Continue
    end)

    assert.is_true(type(mangling) == "string")

    ffi.cdef(string.format("unsigned %s()", mangling))

    local support = ffi.load("ljclang_support")
    local func = support[mangling]

    assert.is_true(type(func) == "cdata")
end

if (os.getenv("LJCLANG_TESTS_NO_CXX_STDLIB") ~= "1") then
    describe2("Mangling", testMangling)
end

local function makeIndexerCallbacks(tab)
    tab._noGcCheck = true
    local callbacks = cl.IndexerCallbacks(tab)
    -- Exercise behavior mentioned in LUA_FUNC_INTO_CDATA_FPTR.
    -- (Seen if _noGcCheck above were not present.)
    collectgarbage()
    return callbacks
end

describe("Indexer callbacks", function()
    -- TODO: test indexing multiple source files with the within one session.

    local runIndexing = function(fileName, callbacks,
                                 -- optional:
                                 expectedDiagCount, opts)
        local createTU = function(index, ...)
            return index:createSession():indexSourceFile(
                callbacks, nil, ...)
        end

        GetTU(createTU, fileName, expectedDiagCount, opts)
    end

    for runIdx = 1, 2 do
        local infixStr = (runIdx == 1 and "out" or "")

        it("tests indexing with"..infixStr.." aborting", function()
            local ExpectedCallCount = 26
            local CallCountToAbortAt = 7

            local callCount = 0

            runIndexing("test_data/virtual.hpp", makeIndexerCallbacks{
                abortQuery = function()
                    callCount = callCount + 1
                    -- NOTE: an abort request may not be honored immediately,
                    --  hence '>='.
                    return runIdx == 2 and (callCount >= CallCountToAbortAt)
                end
            })

            local _ = (runIdx == 1) and
                assert.is_equal(callCount, ExpectedCallCount) or
                assert.is_true(callCount < ExpectedCallCount)
        end)
    end

    it("tests indexing with inclusion-related callbacks", function()
        local seqNum = 0

        local checkSeqNum = function(expectedSeqNum)
            assert.is_equal(seqNum, expectedSeqNum)
            seqNum = seqNum + 1
        end

        local FileName = "/tmp/ljclang_test_includes.cpp"
        writeToFile(FileName, [[
#include "virtual.hpp"
#include "enums.hpp"
]])
        local callbacks = makeIndexerCallbacks{
            importedASTFile = function(impASTFileInfo)
                checkSeqNum(0)

                assert.is_equal(seqNum, 1)

                assert.is_not_nil(impASTFileInfo.file)
                assert.is_nil(impASTFileInfo.module)
            end,

            startedTranslationUnit = function()
                -- TODO: why is this callback invoked twice?
                checkSeqNum((seqNum == 1) and 1 or 2)
            end,

            enteredMainFile = function(mainFile)
                checkSeqNum(3)

                assert.is_equal(mainFile:name(), FileName)
            end,

            ppIncludedFile = function(incFileInfo)
                checkSeqNum((seqNum == 4) and 4 or 5)

                assert.is_not_nil(incFileInfo.file)
                assert.is_false(incFileInfo.isImport)
                local _, hashLco = incFileInfo.hashLoc:fileSite()
                assert.is_equal(hashLco.line, seqNum - 4)
                assert.is_equal(incFileInfo.filename:sub(-4), ".hpp")
            end,
        }

        local additionalOpts = {"-Itest_data/", "-include-pch", ASTFileName}
        runIndexing(FileName, callbacks, 2, concatTables(clangOpts, additionalOpts))
    end)

    it("tests indexing with declaration and entity reference callbacks", function()
        local callCounts = {
            decl = 0,
            ref = 0,
            methodRef = 0,
        }

        local IdxEntity = cl.IdxEntity
        local FileName = "test_data/virtual.hpp"

        runIndexing(FileName, makeIndexerCallbacks{
            indexDeclaration = function(declInfo)
                callCounts.decl = callCounts.decl + 1

                assert.is_number(declInfo.numAttributes)

                assert.is_boolean(declInfo.isRedeclaration)
                assert.is_boolean(declInfo.isDefinition)
                assert.is_boolean(declInfo.isContainer)
                assert.is_boolean(declInfo.isImplicit)

                local cur = declInfo.cursor
                assert.is_false(declInfo.isRedeclaration)
                assert.is_true(not cur:haskind("ClassDecl") or declInfo.isDefinition)
                assert.is_true(not cur:haskind("ClassDecl") or declInfo.isContainer)
                assert.is_false(declInfo.isImplicit)

                local cCur = declInfo.lexicalContainer.cursor
                assert.is_true(
                    cCur:kind() == "Namespace" or
                    cCur:kind() == "TranslationUnit" or
                    cCur:kind() == "ClassDecl")

                local entInfo = declInfo.entityInfo
                assert.is_equal(entInfo.cursor, cur)
                assert.is_equal(entInfo.templateKind, IdxEntity.NonTemplate)
                assert.is_equal(cCur:name() == "Final", entInfo.attributes:has('CXXFinalAttr'))

                assert.is_equal(#declInfo.attributes, declInfo.numAttributes)
                assert.is_equal(#entInfo.attributes, declInfo.numAttributes)

                local isCXXEntity = (entInfo.name ~= "BigNumbers" and
                                     entInfo.name ~= "GetIt")  -- TODO: why?
                assert.is_equal(entInfo.lang,
                                isCXXEntity and cl.IdxEntityLang.CXX or cl.IdxEntityLang.C)
            end,

            indexEntityReference = function(entRefInfo)
                local SymbolRole = cl.SymbolRole

                callCounts.ref = callCounts.ref + 1

                local entInfo = entRefInfo.referencedEntity
                local isMethod = entInfo.cursor:haskind("CXXMethod")

                if (not isMethod) then
                    assert.is_equal(entRefInfo.role, SymbolRole.Reference)
                    assert.is_equal(entInfo.kind, IdxEntity.CXXClass)
                else
                    callCounts.methodRef = callCounts.methodRef + 1

                    assert.is_equal(
                        entRefInfo.role,
                        SymbolRole.Reference + SymbolRole.Call + SymbolRole.Dynamic)
                    assert.is_equal(entInfo.kind, IdxEntity.CXXInstanceMethod)
                end

                local file, lco = entRefInfo.loc:fileSite()
                assert.is_equal(file:name(), FileName)
                assert.is_true(lco.line > 0)
                assert.is_true(lco.column > 0)
                assert.is_true(lco.offset > 0)
            end,
        })

        assert.is_equal(callCounts.decl, 15)
        assert.is_equal(callCounts.ref, 5)
        assert.is_equal(callCounts.methodRef, 1)
    end)

    it("tests indexing combining includes, decsl/refs and *Site() functions", function()
        local FileName = "/tmp/ljclang_test_indexing.cpp"
        writeToFile(FileName, ([[
short FirstVar = 1;
// ^v^v NOTE [DECL_INC_ORDER]: the "included file" event comes first, before the declaration above!
#include "enums.hpp"
int ThirdVar = 3;
long FourthVar = 4;
// ^v^v NOTE DECL_INC_ORDER.
#include "defines.hpp"
// ^v^v Two consecutive includes with no decls or refs in between ^v^v
// (Relevant because: how do we detect a "left included file" event?)
#undef LITTLE
#undef MAKE_MUCH
#undef MAKE_VAR
#include "defines.hpp"
float SixthVar = 6;
double SeventhVar = 7;
enum Wow {
    Much = MAKE_MUCH(Orange),
    Little = LITTLE,
};
// NOTE [SITE_FUNCTIONS]: This is the *only* thing that exhibits different values for
//  different *Site() functions! Unexpectedly, the entities referenced via the macros
//  above do not show this behavior.
MAKE_VAR(long long, Ninth, Green);
]]):gsub("//[^\n]+\n", ""))
        local function makePlaceStr(file, lco)
            local prefix = (file:name() == FileName) and 'T' or 'O'  -- "[T]est" file or "[O]ther"?
            return prefix..":"..lco.line..":"..lco.column
        end

        local function makeFullPlaceStr(loc)
            local f = makePlaceStr(loc:fileSite())
            local s = makePlaceStr(loc:spellingSite())
            local e = makePlaceStr(loc:expansionSite())
            if (f == s and s == e) then
                return f
            else
                return f..','..s..','..e
            end
        end

        local function makeEventStr(eventKind, loc, suffix)
            return eventKind.." "..makeFullPlaceStr(loc)..": "..suffix
        end

        local function makeSuffix(entInfo)
            local shortCursorKind = entInfo.cursor:kind():gsub("[a-z]", "")
            return shortCursorKind.." "..tostring(entInfo.name)
        end

        local eventStrings = {}
        local lastFileChar

        local function pushEventStr(...)
            local eventStr = makeEventStr(...)
            local curFileChar = eventStr:sub(6,6)
            if (curFileChar == 'T' or lastFileChar == 'T') then
                eventStrings[#eventStrings + 1] = eventStr
            end
            lastFileChar = curFileChar
        end

        local callbacks = makeIndexerCallbacks{
            ppIncludedFile = function(incFileInfo)
                pushEventStr("#inc", incFileInfo.hashLoc, incFileInfo.filename)
            end,

            indexDeclaration = function(declInfo)
                local entInfo = declInfo.entityInfo
                pushEventStr("decl", declInfo.loc, makeSuffix(entInfo))
            end,

            indexEntityReference = function(entRefInfo)
                local entInfo = entRefInfo.referencedEntity
                pushEventStr("+ref", entRefInfo.loc, makeSuffix(entInfo))
            end,
        }

        local additionalOpts = {"-Itest_data/"}
        runIndexing(FileName, callbacks, 0, concatTables(clangOpts, additionalOpts))

        assert.are.same(eventStrings, {
            "#inc T:2:1: enums.hpp",
            -- ^v^v NOTE DECL_INC_ORDER.
            "decl T:1:7: VD FirstVar",
            "decl O:2:6: ED Fruits",
            "decl T:3:5: VD ThirdVar",
            "#inc T:5:1: defines.hpp",
            "#inc T:9:1: defines.hpp",
            -- ^v^v NOTE DECL_INC_ORDER.
            "decl T:4:6: VD FourthVar",
            "decl T:10:7: VD SixthVar",
            "decl T:11:8: VD SeventhVar",
            "decl T:12:6: ED Wow",
            "decl T:13:5: ECD Much",
            "+ref T:13:22: ECD Orange",
            "+ref T:13:12: ECD Trillion",
            "decl T:14:5: ECD Little",
            "+ref T:14:14: ECD Billion",
            "decl T:16:21,T:16:21,T:16:1: VD Ninth",
            "+ref T:16:28: ECD Green",  -- NOTE SITE_FUNCTIONS.
        })
    end)
end)
