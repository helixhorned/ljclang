#!/usr/bin/env luajit

local arg = arg

local assert = assert
local print = print
local require = require
local tostring = tostring

local string = require("string")
local os = require("os")

----------

assert(arg[1], "Usage: "..arg[0].." <filename> ...")

local cl = require("ljclang")

local index = cl.createIndex(true,false)

arg[0] = nil
local tu = index:parse(arg, {"DetailedPreprocessingRecord"})
if (tu == nil) then
    print('TU is nil')
    os.exit(1)
end

local cur = tu:cursor()
assert(cur==cur)
assert(cur ~= nil)
assert(cur:kindnum() == "CXCursor_TranslationUnit")
assert(cur:haskind("TranslationUnit"))

print("TU: "..cur:name()..", "..cur:displayName())
print("Index.h in TU: "..tu:file("Index.h"))

local diags = tu:diagnostics()
for i=1,#diags do
    local d = diags[i]
    print("diag "..i..": "..d.category..", "..d.text)
end

local V = cl.ChildVisitResult

local visitor = cl.regCursorVisitor(
function(cur, parent)
    if (cur:haskind("EnumConstantDecl")) then
        print(string.format("%s: %d", cur:name(), cur:enumval()))
    end

--    print(string.format("[%3d] %50s <- %s", tonumber(cur:kindnum()), tostring(cur), tostring(parent)))
    print(string.format("[%12s] %50s <- %s", cur:kind(), tostring(cur), tostring(parent)))
    return V.Recurse
end)

cur:children(visitor)
