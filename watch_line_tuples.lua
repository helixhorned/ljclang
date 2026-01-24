#!/usr/bin/env luajit

-- luacheck: ignore 581

local bit = require("bit")
local ffi = require("ffi")
local math = require("math")
local io = require("io")
local os = require("os")
local table = require("table")

local assert = assert
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local unpack = unpack

local arg = arg

----------

local pendingOutput = {}

local function printf_later(fmt, ...)
	pendingOutput[#pendingOutput + 1] = fmt:format(...)
	pendingOutput[#pendingOutput + 1] = "\n"
end

local function finish_printf_later()
	if (#pendingOutput > 0) then
		io.stdout:write(table.concat(pendingOutput))
		io.stdout:flush()
		pendingOutput = {}
	end
end

local function errprint(str)
	io.stderr:write(str, "\n")
end

local function errprintf(fmt, ...)
	errprint(fmt:format(...))
	return true
end

local function abort(fmt, ...)
	errprintf("ERROR: "..fmt, ...)
	os.exit(1)
end

local function usage(hline)
	if (hline) then
		errprint("ERROR: "..hline)
	end

	errprint([===[
Usage:
  watch_line_tuples.lua <context-line-counts> <files-file> [<max-query-result-lines> [<tag-pattern>]]
  watch_line_tuples.lua -h

  <context-line-counts> must be a comma-separated lines of
    increasing integers from 0 to 9, e.g. '0' or '1,3,5,7'

  <files-file> must contain unique lines of file names which
    - are absolute, i.e. start with '/'
   and in normal form:
    - not contain '//'
    - not end in '/'
    - not contain '.' or '..' between two '/' or at the end

  <max-query-result-lines> must be a nonnegative integer or 'inf' (no limit, default)
    - 0 means to exit immediately after indexing
]===])
	os.exit(1)
end

if (arg[1] == "-h") then
	usage()
end

local arg_contextLineCountsStr = arg[1]
local arg_filesFileName = arg[2]
local opt_maxQueryResultLines = arg[3]
local opt_tagPattern = arg[4]

if (arg_contextLineCountsStr == nil or arg_filesFileName == nil) then
	usage "too few arguments"
elseif (opt_maxQueryResultLines and opt_maxQueryResultLines ~= "0" and
		opt_maxQueryResultLines ~= "inf" and
		not opt_maxQueryResultLines:match("^[1-9][0-9]*$")) then
	usage "<max-query-result-lines> must be a nonnegative integer or 'inf'"
elseif (opt_tagPattern and opt_tagPattern == '') then
	usage "<tag-line-pattern> must be nonempty"
elseif (arg[5]) then
	usage "too many arguments"
end

local TagIdxBits = opt_tagPattern and 16 or 0
local LineNumShift = 26 - TagIdxBits / 2
local FileIdxMask = bit.lshift(1ull, LineNumShift) - 1
local LineNumMask = FileIdxMask
local MaxTags = math.ldexp(1, TagIdxBits)
local MaxFilesOrLines = math.ldexp(1, LineNumShift)
local TwiceLineNumShift = 2 * LineNumShift
local MaxFilesOrLinesSquared = MaxFilesOrLines * MaxFilesOrLines

local g_contextLineCounts = {}

do
	local str = arg_contextLineCountsStr
	local counts = g_contextLineCounts

	if (str == "" or str:find"^," or str:find",," or str:find",^") then
		usage "<context-line-counts> must be a comma-separated list of integers"
	end

	for elementStr in str:gmatch("[^,]+") do
		if (not elementStr:match("^[0-9]$")) then
			usage "<context-line-counts> elements must be integers between 0 and 9"
		end

		local val = tonumber(elementStr)
		assert(val ~= nil)
		local lastVal = counts[#counts]

		if (lastVal ~= nil and not (val > lastVal)) then
			usage "<context-line-counts> elements must be increasing"
		end

		counts[#counts + 1] = val
	end
end

local function IsFileNameNormal(path)
	assert(type(path) == "string")

	if (not (path:match"^/" and
			 not path:match"//" and
			 not path:match"/$")) then
		return false
	end

	for component in path:gmatch"/([^/]+)" do
		if (component == "." or component == "..") then
			return false
		end
	end

	return true
end

local function New_LinesOf(fileName, linesFailPrefix)
	assert(type(fileName) == "string")
	assert(type(linesFailPrefix) == "string")

	local file, msg = io.open(fileName)
	if (file == nil) then
		abort("%s", msg)
	end

	local called = false

	local readLine = function(_, _)
		if (not called) then
			local res = {pcall(file.read, file, "*l")}
			called = true

			if (not res[1]) then
				abort("%s: failed reading line from '%s': %s", linesFailPrefix, fileName, res[2])
			end

			return unpack(res, 2)
		end

		return file:read("*l")
	end

	return {
		iterate = function()
			return readLine, nil, nil
		end,

		close = function()
			file:close()
		end,
	}
end

local function GetFileNames()
	local fns = {}
	local curLine = 0
	local iter = New_LinesOf(arg_filesFileName, "argument <files-file>")

	for fn in iter:iterate() do
		curLine = curLine + 1
		if (not IsFileNameNormal(fn)) then
			abort("%s:%d: file name '%s' is not absolute and in normal form.",
				  arg_filesFileName, curLine, fn)
		elseif (fns[fn] ~= nil) then
			abort("%s:%d: duplicate file name '%s'.", arg_filesFileName, curLine, fn)
		end

		fns[#fns + 1] = fn
		fns[fn] = true
	end

	iter:close()

	if (#fns > MaxFilesOrLines) then
		abort("too many files (max = %d)", MaxFilesOrLines)
	end

	return fns
end

local g_fileNames = GetFileNames()
local g_maxQueryResultLines = tonumber(opt_maxQueryResultLines) or math.huge

----------

local Max53 = 0x1fFFFFffffFFFF

local function ToTableKey(low53, preExp)
	assert(type(low53) == "number")
	assert(type(preExp) == "number")

	assert(low53 >= 0 and low53 <= Max53)
	assert(preExp >= 0 and preExp <= 1023)

	-- NOTE: low53 == 0 -> returns 0
	local res = math.ldexp(low53, preExp - 53)
	assert(res == res)
	return res
end

assert(ToTableKey(1, 0) ~= ToTableKey(2, 0))
assert(ToTableKey(Max53, 1023) ~= ToTableKey(Max53 - 1, 1023))
-- Unfortunate, but we choose simplicity:
assert(ToTableKey(0, 0) == ToTableKey(0, 1023))

local uint64_t = ffi.typeof(0ull)

-- Fowler-Noll-Vo hash, 64-bit variant
local function New_FNV1a64_State(hash)
	assert(hash == nil or type(hash) == "cdata" and ffi.typeof(hash) == uint64_t)

	return {
		hash = hash or 0xCBF29CE484222325ull,

		_add = function(self, str, b, e)
			assert(type(str) == "string")
			assert(b == nil or type(b) == "number")
			assert(e == nil or type(e) == "number")

			b = b or 1
			e = e or #str

			for i = b, e do
				local byte = str:byte(i)
				self.hash = bit.bxor(self.hash, byte)
				self.hash = self.hash * 0x100000001B3ull
			end
		end,

		addLine = function(self, str, b, e)
			self:_add(str, b, e)
			self:_add("\n")
			return self
		end,

		toNumber = function(self)
			return ToTableKey(
				tonumber(bit.band(self.hash, 0x1fFFFFffffFFFFull)),
				tonumber(bit.rshift(self.hash, 54)))
		end,
	}
end

---------- Construction of the index ----------

-- Inputs:
--  * the file index and line number are one-based
--  * the tag index is one-based but may be zero
local function ToIndexValue(fileIdx, lineNum, tagIdx)
	assert(type(fileIdx) == "number")
	assert(fileIdx >= 1 and fileIdx <= MaxFilesOrLines)
	assert(type(lineNum) == "number")
	assert(lineNum >= 1)
	assert(type(tagIdx) == "number")
	assert(tagIdx >= 0 and tagIdx < MaxTags)

	if (lineNum > MaxFilesOrLines) then
		abort("%s: too many lines (max = %d)", g_fileNames[fileIdx], MaxFilesOrLines)
	end

	return (fileIdx - 1) + MaxFilesOrLines * (lineNum - 1) + MaxFilesOrLinesSquared * tagIdx
end

local function UnpackIndexValue(val)
	assert(type(val) == "number")
	assert(val >= 0 and val < MaxFilesOrLines * MaxFilesOrLines * MaxTags)
	local fileIdx = tonumber(bit.band(val, FileIdxMask))
	local preLNum = bit.rshift(val + 0ull, LineNumShift)
	local lineNum = tonumber(bit.band(preLNum, LineNumMask))
	local tag = tonumber(bit.rshift(val + 0ull, TwiceLineNumShift))
	return fileIdx + 1, lineNum + 1, tag
end

local function New_Index()
	local map = {}

	return {
		add = function(_, key, val)
			assert(type(key) == "number")

			local cur = map[key]

			if (cur == nil) then
				map[key] = val
			elseif (type(cur) == "number") then
				map[key] = {cur, val}
			else
				assert(type(cur) == "table")
				cur[#cur + 1] = val
			end
		end,

		get = function(_, key)
			assert(type(key) == "number")
			return map[key]
		end,

		keyCount = function()
			local count = 0
			for _ in pairs(map) do
				count = count + 1
			end
			return count
		end,
	}
end

local Backward = -1
local maxContextLineCount = g_contextLineCounts[#g_contextLineCounts]

local function New_StreamState(fileIdx, indexes)
	assert(type(fileIdx) == "number")
	assert(fileIdx >= 1 and fileIdx <= MaxFilesOrLines)
	assert(type(indexes) == "table")

	local firstStartLineNum = -maxContextLineCount + 1

	-- [<startLineNum>] = FNV1a64_State of lines from <startLineNum> to the current line
	local partialStates = {}

	do
		local hashState = New_FNV1a64_State()

		for startLineNum = 0, firstStartLineNum, Backward do
			hashState:addLine("")
			partialStates[startLineNum] = New_FNV1a64_State(hashState.hash)
		end
	end

	return {
		handleLine = function(_, lineNum, str, b, e, tagIdx)
			assert(lineNum >= 1)
			assert(tagIdx >= 0)

			for startLineNum = lineNum - 2 * maxContextLineCount, lineNum - 1 do
				local hashState = partialStates[startLineNum]
				assert((hashState ~= nil) == (startLineNum >= firstStartLineNum))

				if (hashState ~= nil) then
					hashState:addLine(str, b, e)
				end
			end

			partialStates[lineNum] = New_FNV1a64_State():addLine(str, b, e)

			for _, contextLineCount in ipairs(g_contextLineCounts) do
				local centerLineNum = lineNum - contextLineCount

				if (centerLineNum >= 1) then
					local startLineNum = lineNum - 2 * contextLineCount
					local hashState = partialStates[startLineNum]
					assert(hashState ~= nil)

					local key = hashState:toNumber()
					local val = ToIndexValue(fileIdx, centerLineNum, tagIdx)

					-- NOTE: the tag is only accurate for 'contextLineCount == 0'.
					indexes[contextLineCount]:add(key, val)
				end
			end

			partialStates[lineNum - 2 * maxContextLineCount] = nil
		end,
	}
end

local function New_Tags()
	local tags = { [0] = "" }

	return {
		-- static
		_check = function(line)
			return opt_tagPattern and line:match(opt_tagPattern)
		end,

		_add = function(_, tag)
			assert(type(tag) == "string")
			local idx = #tags + 1
			if (idx >= MaxTags) then
				abort("too many tags (max = %d)", MaxTags - 1)
			end
			tags[idx] = tag
			return idx
		end,

		add = function(self, line)
			local tag = self._check(line)
			return tag and self:_add(tag)
		end,

		get = function(_, idx)
			assert(type(idx) == "number")
			assert(idx >= 0 and idx <= #tags)
			return tags[idx]
		end,

		size = function(_)
			return #tags
		end,
	}
end

local function GetRelevantBounds(line)
	local firstRelevantPos = line:find"[^ \t\r]"

	if (firstRelevantPos == nil) then
		-- The line is empty or contains only whitespace.
		return 1, 0
	end

	local firstIgnoredTailPos = line:find"[ \t\r]+$"

	return firstRelevantPos,
		(firstIgnoredTailPos ~= nil) and firstIgnoredTailPos - 1 or #line
end

local g_indexes = {}
local g_contextLineCountsReverse = {}
local g_tags = New_Tags()

for i, contextLineCount in ipairs(g_contextLineCounts) do
	g_indexes[contextLineCount] = New_Index()
	g_contextLineCountsReverse[#g_contextLineCounts + 1 - i] = contextLineCount
end

do
	local fileIdx = 0
	local totalLineCount = 0

	for _, fileName in ipairs(g_fileNames) do
		fileIdx = fileIdx + 1

		local iter = New_LinesOf(fileName, ("%s:%d"):format(arg_filesFileName, fileIdx))
		local state = New_StreamState(fileIdx, g_indexes)
		local curTagIdx = 0
		local lineNum = 0

		for line in iter:iterate() do
			lineNum = lineNum + 1
			local b, e = GetRelevantBounds(line)
			local tagIdx = g_tags:add(line)
			curTagIdx = tagIdx or curTagIdx
			state:handleLine(lineNum, line, b, e, curTagIdx)
		end

		iter:close()

		totalLineCount = totalLineCount + lineNum

		if (lineNum > 0) then
			for offset = 1, maxContextLineCount do
				state:handleLine(lineNum + offset, "", nil, nil, curTagIdx)
			end
		end
	end

	printf_later("total: %d lines in %d files; %d tags", totalLineCount, #g_fileNames, g_tags:size())
	printf_later("unique")

	for _, contextLineCount in ipairs(g_contextLineCountsReverse) do
		local lineSpan = 1 + 2 * contextLineCount
		local what = (lineSpan == 1) and "lines" or lineSpan.."-line tuples"
		printf_later(" %s: %d", what, g_indexes[contextLineCount]:keyCount())
	end

	finish_printf_later()
end

if (g_maxQueryResultLines == 0) then
	os.exit(0)
end

---------- Handling of queries from stdin ----------

local function FilteredSequence(seq, hasValue)
	assert(type(seq) == "table")
	assert(type(hasValue) == "table")

	local res = {}

	for _, v in ipairs(seq) do
		if (not hasValue[v]) then
			res[#res + 1] = v
		end
	end

	return res
end

local maxLineSpan = 1 + 2 * maxContextLineCount
local expectedQueryCommand = "q"..maxLineSpan
local HeaderLineFormat = "==> matches with %d context lines: total %d, output %d"

while (true) do
	local cmd = io.stdin:read("*l")

	if (cmd == "exit" or cmd == nil) then
		os.exit(0)
	elseif (cmd ~= expectedQueryCommand) then
		abort("stdin: expected command '%s'", expectedQueryCommand)
	end

	local lines = {}

	for i = 1, maxLineSpan do
		local line = io.stdin:read("*l")
		if (line == nil) then
			abort("stdin: expected more input, got EOF")
		end
		lines[i] = line
	end

	local centerLineIdx = 1 + maxContextLineCount
	local seen = {
		-- [<Index value>] = true
	}

	for clcrIdx, contextLineCount in ipairs(g_contextLineCountsReverse) do
		local state = New_FNV1a64_State()

		for i = centerLineIdx - contextLineCount, centerLineIdx + contextLineCount do
			local line = lines[i]
			local b, e = GetRelevantBounds(line)
			state:addLine(line, b, e)
		end

		local key = state:toNumber()
		local val = g_indexes[contextLineCount]:get(key)

		if (val == nil) then
			printf_later(HeaderLineFormat, contextLineCount, 0, 0)
		else
			local values = (type(val) == "number") and {val} or val
			assert(type(values) == "table")
			local newValues = (clcrIdx == 1) and values or FilteredSequence(values, seen)
			local toSeeCount = math.min(#newValues, g_maxQueryResultLines)

			printf_later(HeaderLineFormat, contextLineCount, #newValues, toSeeCount)

			local seenCount = 0

			for _, v in ipairs(newValues) do
				if (not seen[v]) then
					seen[v] = true
					local fileIdx, lineNum, tagIdx = UnpackIndexValue(v)
					local fileName = g_fileNames[fileIdx]
					assert(fileName ~= nil)
					local tag = g_tags:get(tagIdx)
					assert(tag ~= nil)
					local spcOpt = (tag == "") and "" or " "
					printf_later("%s:%d:%s%s", fileName, lineNum, spcOpt, tag)

					seenCount = seenCount + 1

					if (seenCount == toSeeCount) then
						break
					end
				end
			end

			assert(seenCount == toSeeCount)
		end
	end

	finish_printf_later()
end
