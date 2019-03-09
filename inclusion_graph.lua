
local error_util = require("error_util")
local class = require("class").class

local check = error_util.check
local checktype = error_util.checktype

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

    iEdges = function(self, mapKey)
        return ipairs(self.edgeTo)
    end
}

-- Private InclusionGraph functions

local function addOrGetNode(self, filename)
    return SVTableAddOrGet(self._nodes, filename, Node(filename))
end

local function quote(str)
    checktype(str, 1, "string", 2)
    -- Graphviz docs ("The DOT language") say:
    --  In quoted strings in DOT, the only escaped character is double-quote (").
    --  (...)
    --  As another aid for readability, dot allows double-quoted strings to span multiple physical lines using the standard C
    --  convention of a backslash immediately preceding a newline character^2.
    return '"'..str:gsub('"', '\\"'):gsub('\n', '\\\n')..'"'
end

-- Public API

api.InclusionGraph = class
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

    printAsGraphvizDot = function(self, title, reverse, commonPrefix, printf)
        checktype(title, 1, "string", 2)
        reverse = (reverse ~= nil) and reverse or false
        checktype(reverse, 2, "boolean", 2)
        checktype(printf, 4, "function", 2)

        local strip = function(fn)
            return (fn:sub(1, #commonPrefix) == commonPrefix) and
                fn:sub(#commonPrefix + 1) or
                fn
        end

        printf("strict digraph %s {", quote(title))
        printf("rankdir=LR")

        -- Nodes.
        for i, filename in self:iFileNames() do
            printf('%s [shape=box];', quote(strip(filename)))
        end

        printf('')

        -- Edges.
        for _, filename in self:iFileNames() do
            for _, filename2 in self:getNode(filename):iEdges() do
                local left = (not reverse) and filename or filename2
                local right = (not reverse) and filename2 or filename
                printf('%s -> %s;', quote(strip(left)), quote(strip(right)))
            end
        end

        printf("}")
    end
}

-- Done!
return api
