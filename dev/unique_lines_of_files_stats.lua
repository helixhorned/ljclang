#!/usr/bin/env luajit

local bit = require("bit")
local io = require("io")
local os = require("os")

local ffi = require("ffi")

local pairs = pairs
local tonumber = tonumber

local arg = arg

----------

local filesFileName = arg[1]
if (filesFileName == nil) then
	io.stderr:write("Usage: "..arg[0].." <file-containing-file-names>\n")
	os.exit(1)
end

local uint32_t = ffi.typeof("uint32_t")
local uint64_t = ffi.typeof("uint64_t")
local function FNV1a_64_lo(str)
	local len = #str
	local hash = uint64_t(0xcbf29ce484222325)

	for i = 1, len do
		local byte = str:byte(i)
		hash = bit.bxor(hash, byte)
		hash = hash * 0x100000001b3
	end

	return tonumber(uint32_t(hash))
end

local fileCount = 0
local totalLineCount = 0
local totalLineLength = 0

local allLines = {}
local hashCounts = {}
local successors = {}
local edgeAlreadySeenCount = 0

local function handleEdge(prev, cur)
	local nextOfPrev = successors[prev]
	if (nextOfPrev == nil) then
		successors[prev] = cur
	elseif (type(nextOfPrev) ~= "table") then
		if (nextOfPrev ~= cur) then
			successors[prev] = { [nextOfPrev]=true, [cur]=true }
		else
			edgeAlreadySeenCount = edgeAlreadySeenCount + 1
		end
	else
		nextOfPrev[cur] = true
	end
end

for fileName in io.lines(filesFileName) do
	local lineCount = 0
	local lineLength = 0
	local prevLine = "\x01"
	local prevHash = 0

	for line in io.lines(fileName) do
		lineCount = lineCount + 1
		lineLength = lineLength + #line

--		allLines[line] = true

		local hash = FNV1a_64_lo(line)
--		local hashCount = hashCounts[hash]
--		hashCounts[hash] = hashCount and (hashCount + 1) or 1

		handleEdge(prevLine, line)
--		handleEdge(prevHash, hash)
		prevLine = line
		prevHash = hash
	end

	handleEdge(prevLine, "\xff")
--	handleEdge(prevHash, 0xffffffff)

	fileCount = fileCount + 1
	totalLineCount = totalLineCount + lineCount
	totalLineLength = totalLineLength + lineLength
--	io.stdout:write(("%s: %s\n"):format(fileCount, lineCount))
end

io.stdout:write(("Lines processed.....: %d, total length %d bytes (avg length among all = %.1f)\n")
	:format(totalLineCount, totalLineLength, totalLineLength / totalLineCount))

--[[
local uniqueLineCount = 0
for _ in pairs(allLines) do
	uniqueLineCount = uniqueLineCount +1
end

local uniqueHashCount = 0
for _ in pairs(hashCounts) do
	uniqueHashCount = uniqueHashCount +1
end

io.stdout:write(("...unique lines: %d (truly), %d (by hash)\n"):format(uniqueLineCount, uniqueHashCount))
--]]

local function getOutdegree(nexts)
	local degree = 1
	for _ in pairs(nexts) do
		degree = degree + 1
	end
	return degree
end

local nodeCount = 0
local multipleOutCount = 0
local totalMultiOutdegree = 0

for _, nexts in pairs(successors) do
	nodeCount = nodeCount + 1
	if (type(nexts) == "table") then
		multipleOutCount = multipleOutCount + 1
		totalMultiOutdegree = totalMultiOutdegree + getOutdegree(nexts)
	end
end

io.stdout:write(("Nodes (unique lines): %d (truly), %d with outdegree >1 (avg outdegree among those = %.1f)\n")
	:format(nodeCount - 1, multipleOutCount, totalMultiOutdegree / multipleOutCount))

local edgeCount =
	(nodeCount - multipleOutCount) +  -- those with outdegree 1
	totalMultiOutdegree

io.stdout:write(("Edges(l.transitions): %d, number of times an already known edge was seen: %d\n"):
	format(edgeCount, edgeAlreadySeenCount))
