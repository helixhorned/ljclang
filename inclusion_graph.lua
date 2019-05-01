
local error_util = require("error_util")
local class = require("class").class
local math = require("math")
local string = require("string")
local table = require("table")

local check = error_util.check
local checktype = error_util.checktype

local assert = assert
local ipairs = ipairs

----------

local api = {}

-- Helper function to manipulate "Set+Vector" tables: tables which have
--  { <key> = <value>, ... } to be used like sets and
--  { [1] = <key>, ... } (uniq'd) to be used like vectors.
--
-- Note: this cannot be a 'class' since the keys are strings. (So, a member function name
-- may conflict with a key.)
local function SVTableAddOrGet(tab, key, value)
    checktype(tab, 1, "table", 2)
    checktype(key, 1, "string", 2)
    check(value ~= nil, "argument #3 must be non-nil", 2)

    if (tab[key] == nil) then
        tab[#tab + 1] = key
        tab[key] = value
    end

    return tab[key]
end

-- Merely for marking "Set+Vector tables".
local function SVTable()
    return {}
end

local Node = class
{
    function(key)
        checktype(key, 1, "string", 2)

        return {
            key = key,
            edgeTo = SVTable(),
        }
    end,

    addEdgeTo = function(self, key, value)
        SVTableAddOrGet(self.edgeTo, key, value)
    end,

    getKey = function(self)
        return self.key
    end,

    getEdgeCount = function(self)
        return #self.edgeTo
    end,

    iEdges = function(self)
        return ipairs(self.edgeTo)
    end
}

-- Private InclusionGraph functions

local function addOrGetNode(self, filename)
    return SVTableAddOrGet(self._nodes, filename, Node(filename))
end

local function dot_quote(str)
    checktype(str, 1, "string", 2)
    -- Graphviz docs ("The DOT language") say:
    --  In quoted strings in DOT, the only escaped character is double-quote (").
    --  (...)
    --  As another aid for readability, dot allows double-quoted strings to span multiple physical lines using the standard C
    --  convention of a backslash immediately preceding a newline character^2.
    return str:gsub('"', '\\"'):gsub('\n', '\\\n')
end

local function quote(str)
    return '"'..dot_quote(str)..'"'
end

-- Public API

local function SerializeGraph(self)
    local tab = {}

    for _, filename in self:iFileNames() do
        for _, otherFileName in self:getNode(filename):iEdges() do
            -- TODO: could store 'filename' only once and have a count of edges.

            assert(not (filename:find('%z') or otherFileName:find('%z')))
            tab[#tab + 1] = filename..'\0'..otherFileName
        end
    end

    return table.concat(tab, '\0\0')..'\0\0'
end

local InclusionGraph  -- "forward-declare"
local InvalidStringMsg = "passed string that is not a graph serialization"

api.Deserialize = function(graphStr)
    checktype(graphStr, 1, "string", 2)
    check(#graphStr >= 2, "argument #1 must have length of at least two")
    check(graphStr:sub(-2) == "\0\0", InvalidStringMsg, 2)

    local graph = InclusionGraph()

    for filename, otherFileName in graphStr:gmatch("([^%z]+)%z([^%z]+)") do
        graph:addInclusion(filename, otherFileName)
    end

    local totalEdgeCount = 0
    local doubleZeroCount = 0

    for _, filename in graph:iFileNames() do
        totalEdgeCount = totalEdgeCount + graph:getNode(filename):getEdgeCount()
    end

    for _ in graphStr:gmatch("%z%z") do
        doubleZeroCount = doubleZeroCount + 1
    end

    check(totalEdgeCount == doubleZeroCount - ((totalEdgeCount == 0) and 1 or 0),
          InvalidStringMsg..", or INTERNAL ERROR", 2)

    return graph
end

InclusionGraph = class
{
    function()
        return {
            _nodes = SVTable()
        }
    end,

    -- Edge in the graph will point from a to b.
    -- Interpretation is up to the user.
    addInclusion = function(self, aFile, bFile)
        checktype(aFile, 1, "string", 2)
        checktype(bFile, 2, "string", 2)

        check(not aFile:find('%z'), "argument #1 must not contain NUL bytes", 2)
        check(not bFile:find('%z'), "argument #2 must not contain NUL bytes", 2)

        local aNode = addOrGetNode(self, aFile)
        local bNode = addOrGetNode(self, bFile)

        aNode:addEdgeTo(bFile, bNode)
    end,

    getNodeCount = function(self)
        return #self._nodes
    end,

    getNode = function(self, filename)
        return self._nodes[filename]
    end,

    iFileNames = function(self)
        return ipairs(self._nodes)
    end,

    merge = function(self, other)
        for _, filename in other:iFileNames() do
            for _, otherFileName in other:getNode(filename):iEdges() do
                self:addInclusion(filename, otherFileName)
            end
        end
    end,

    serialize = SerializeGraph,

    printAsGraphvizDot = function(self, title, reverse, commonPrefix, edgeCountLimit, printf)
        checktype(title, 1, "string", 2)
        reverse = (reverse ~= nil) and reverse or false
        checktype(reverse, 2, "boolean", 2)
        checktype(commonPrefix, 3, "string")
        edgeCountLimit = (edgeCountLimit ~= nil) and edgeCountLimit or math.huge
        checktype(edgeCountLimit, 4, "number", 2)
        checktype(printf, 5, "function", 2)

        local strip = function(fn)
            return (fn:sub(1, #commonPrefix) == commonPrefix) and
                fn:sub(#commonPrefix + 1) or
                fn
        end

        printf("strict digraph %s {", quote(title))
        printf("rankdir=LR")

        local qs = function(fn)
            return quote(strip(fn))
        end

        -- Nodes.
        for i, filename in self:iFileNames() do
            printf('%s [shape=box];', qs(filename))
        end

        printf('')

        -- Edges.
        for _, filename in self:iFileNames() do
            local node = self:getNode(filename)
            local edgeCount = node:getEdgeCount()

            if (edgeCount > edgeCountLimit) then
                assert(not reverse)
                local placeholderNodeName = string.format(
                    '"(%d edges from %s)"', edgeCount, dot_quote(strip(filename)))
                printf('%s;', placeholderNodeName)
                printf('%s -> %s;', qs(filename), placeholderNodeName)
            else
                for _, filename2 in node:iEdges() do
                    local left = (not reverse) and filename or filename2
                    local right = (not reverse) and filename2 or filename
                    printf('%s -> %s;', qs(left), qs(right))
                end
            end
        end

        printf("}")
    end
}

api.InclusionGraph = InclusionGraph

-- Done!
return api
