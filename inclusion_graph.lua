
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

local function identity(x)
    return x
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

    addEdgeTo = function(self, includedFileName)
        SVTableAddOrGet(self.edgeTo, includedFileName, true)
    end,

    getKey = function(self)
        return self.key
    end,

    getEdgeCount = function(self)
        return #self.edgeTo
    end,

    iEdges = function(self, mapKey)
        if (mapKey == nil) then
            mapKey = identity
        end
        checktype(mapKey, 2, "function", 2)

        local nextEdge = function(_, i)
            i = i + 1

            if (i <= self:getEdgeCount()) then
                return i, mapKey(self.key), mapKey(self.edgeTo[i])
            end
        end

        return nextEdge, nil, 0
    end
}

-- Private InclusionGraph functions
local IG = {
    addOrGetNode = function(self, filename)
        return SVTableAddOrGet(self._nodes, filename, Node(filename))
    end,
}

api.InclusionGraph = class
{
    function()
        return {
            _nodes = SVTable()
        }
    end,

    addInclusion = function(self, fromFile, toFile)
        checktype(fromFile, 1, "string", 2)
        checktype(toFile, 2, "string", 2)

        local fromNode = IG.addOrGetNode(self, fromFile)
        local toNode = IG.addOrGetNode(self, toFile)

        fromNode:addEdgeTo(toFile)
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

    -- Get an InclusionGraph with the edges of `self` reversed.
    getDual = function(self)
        local dual = api.InclusionGraph()

        -- TODO: have convenience function to return iterator over all edges?
        -- (With optional 'mapKey' function, as for node:edges().)
        for _, fileName in self:iFileNames() do
            for _, fromFile, toFile in self:getNode(fileName):iEdges() do
                dual:addInclusion(toFile, fromFile)
            end
        end

        return dual
    end,
}

-- Done!
return api
