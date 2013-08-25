#!/usr/bin/env luajit

assert(arg[1], "Usage: "..arg[0].." <filename> ...")

local cl = require("ljclang")

local index = cl.createIndex(true,true)

arg[0] = nil
local tu = index:parse(arg)
if (tu == nil) then
    print('TU is nil')
    os.exit(1)
end

local cur = tu:cursor()
assert(cur==cur)
assert(cur:kindnum() == "CXCursor_TranslationUnit")
assert(cur:haskind("TranslationUnit"))

print("TU: "..cur:name()..", "..cur:displayName())
print("Index.h in TU: "..tu:file("Index.h"))

local diags = tu:diagnostics()
for i=1,#diags do
    local d = diags[i]
    print("diag "..i..": "..d.category..", "..d.text)
end
