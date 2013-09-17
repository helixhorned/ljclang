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

arg[0] = nil
local tu = cl.createIndex():parse(arg, {"DetailedPreprocessingRecord"})

-- NOTE: we don't need to keep the Index_t reference around, test this.
collectgarbage()

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
local fn = arg[1]:gsub(".*/","")
print(fn.." in TU: "..tu:file(fn)..", "..tu:file(arg[1]))

local diags = tu:diagnostics()
for i=1,#diags do
    local d = diags[i]
    print("diag "..i..": "..d.category..", "..d.text)
end

local V = cl.ChildVisitResult

local ourtab = {}

local visitor = cl.regCursorVisitor(
function(cur, parent)
    ourtab[#ourtab+1] = cl.Cursor(cur)

    if (cur:haskind("EnumConstantDecl")) then
        print(string.format("%s: %d", cur:name(), cur:enumval()))
    end

    local isdef = (cur:haskind("FunctionDecl")) and cur:isDefinition()

--    print(string.format("[%3d] %50s <- %s", tonumber(cur:kindnum()), tostring(cur), tostring(parent)))
    print(string.format("%3d [%12s%s] %50s <- %s", #ourtab, cur:kind(),
                        isdef and " (def)" or "", tostring(cur), tostring(parent)))

    if (cur:haskind("CXXMethod")) then
        print("("..cur:access()..")")
    end

    return V.Continue
end)

cur:children(visitor)

local tab = cur:children()
print("TU has "..#tab.." direct descendants:")
for i=1,#tab do
    print(i..": "..tab[i]:kind()..": "..tab[i]:displayName())
    assert(tab[i] == ourtab[i])
end
