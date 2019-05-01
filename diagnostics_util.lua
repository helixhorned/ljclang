
local string = require("string")
local table = require("table")

local format = string.format

local assert = assert
local ipairs = ipairs
local type = type
local unpack = unpack

local checktype = require("error_util").checktype
local class = require("class").class

local Col = require("terminal_colors")
local encode_color = Col.encode

----------

local api = {}

local function GetColorizeTripleFunc(severityTextColor, colorizeMainText)
    return function(pre, tag, post)
        return
            encode_color(pre, Col.Bold..Col.White)..
            encode_color(tag, Col.Bold..severityTextColor)..
            (colorizeMainText and encode_color(post, Col.Bold..Col.White) or post)
    end
end

local ColorizeErrorFunc = GetColorizeTripleFunc(Col.Red, true)
local ColorizeWarningFunc = GetColorizeTripleFunc(Col.Purple, true)
local ColorizeNoteFunc = GetColorizeTripleFunc(Col.Black, false)

local ColorSubstitutions = {
    { "(.*)(fatal error: )(.*)", ColorizeErrorFunc },
    { "(.*)(error: )(.*)", ColorizeErrorFunc },
    { "(.*)(warning: )(.*)", ColorizeWarningFunc },
    { "(.*)(note: )(.*)", ColorizeNoteFunc },
}

-----===== Diagnostic formatting =====-----

local function getIndented(indentation, str)
    return format("%s%s", string.rep(" ", indentation), str)
end

local FormattedDiag = class
{
    function(useColors)
        -- self: sequence table of lines constituting the diagnostic
        return {
            usingColors = useColors,
        }
    end,

    addIndentedLine = function(self, indentation, str)
        self[#self + 1] = getIndented(indentation, str)
    end,

    getString = function(self, keepColorsIfPresent)
        checktype(keepColorsIfPresent, 1, "boolean", 2)

        local str = table.concat(self, '\n')

        return
            (not self.usingColors) and str or
            keepColorsIfPresent and Col.colorize(str) or
            Col.strip(str)
    end,
}

local FormattedDiagSet = class
{
    function(useColors)
        return {
            diags = {},  -- list of FormattedDiag objects
            info = nil,

            usingColors = useColors,
        }
    end,

    isEmpty = function(self)
        return (#self:getDiags() == 0 and self:getInfo() == nil)
    end,

    getDiags = function(self)
        return self.diags
    end,

    getInfo = function(self)
        return self.info
    end,

    newDiag = function(self)
        return FormattedDiag(self.usingColors)
    end,

    appendDiag = function(self, fDiag)
        self.diags[#self.diags + 1] = fDiag
    end,

    setInfo = function(self, info)
        checktype(info, 1, "string", 2)

        self.info = self:newDiag()
        self.info:addIndentedLine(0, info)
    end,

    getString = function(self, keepColorsIfPresent)
        checktype(keepColorsIfPresent, 1, "boolean", 2)

        local fDiags = {}

        for _, fDiag in ipairs(self.diags) do
            fDiags[#fDiags + 1] = fDiag:getString(keepColorsIfPresent)
        end

        return table.concat(fDiags, '\n\n') ..
            (self.info ~= nil and '\n'..self.info:getString(keepColorsIfPresent) or "")
    end,
}

local function FormatDiagnostic(diag, useColors, indentation,
                                --[[out--]] fDiag)
    local text = diag:format()
    local printCategory = (indentation == 0)

    if (useColors) then
        for i = 1, #ColorSubstitutions do
            local matchCount
            local subst = ColorSubstitutions[i]
            text, matchCount = text:gsub(subst[1], subst[2])

            if (matchCount > 0) then
                break
            end
        end
    end

    local category = diag:category()

    local textWithMaybeCategory =
        text .. ((printCategory and #category > 0) and " ["..category.."]" or "")
    fDiag:addIndentedLine(indentation, textWithMaybeCategory)
end

-----

local function PrintPrefixDiagnostics(diags, indentation,
                                      --[[out--]] fDiag)
    for i = 1, #diags do
        local text = diags[i]:spelling()

        if (text:match("^in file included from ")) then
            fDiag:addIndentedLine(indentation, "In"..text:sub(3))
        else
            return i
        end
    end

    return #diags + 1
end

local function PrintDiagsImpl(diags, useColors,
                              startIndex, indentation, currentFDiag)
    if (startIndex == nil) then
        startIndex = 1
    end
    if (indentation == nil) then
        indentation = 0
    end

    local formattedDiags = FormattedDiagSet(useColors)

    for i = startIndex, #diags do
        local fDiag = (currentFDiag ~= nil) and currentFDiag or formattedDiags:newDiag()

        local diag = diags[i]
        local childDiags = diag:childDiagnostics()

        local innerStartIndex = PrintPrefixDiagnostics(childDiags, indentation, fDiag)
        FormatDiagnostic(diag, useColors, indentation, fDiag)

        -- Recurse. We expect only at most two levels in total (but do not check for that).
        PrintDiagsImpl(diag:childDiagnostics(), useColors,
                       innerStartIndex, indentation + 2, fDiag)

        local isFatal = (diag:severity() == "fatal")
        local isError = isFatal or diag:severity() == "error"
        local omitFollowing = (isFatal or (isError and diag:category() == "Parse Issue"))

        if (omitFollowing) then
            assert(indentation == 0)

            if (i < #diags) then
                local info = format("%s: omitting %d following diagnostics.",
                                    useColors and encode_color("NOTE", Col.Bold..Col.Blue) or "NOTE",
                                    #diags - i)
                formattedDiags:setInfo(info)
            end
        end

        formattedDiags:appendDiag(fDiag)

        if (omitFollowing) then
            break
        end
    end

    return formattedDiags
end

api.FormattedDiagSet = FormattedDiagSet

function api.GetDiags(diags, useColors)
    checktype(diags, 1, "table", 2)
    checktype(useColors, 2, "boolean", 2)

    return PrintDiagsImpl(diags, useColors)
end

-- Done!
return api
