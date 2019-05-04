
local string = require("string")
local table = require("table")

local format = string.format

local assert = assert
local ipairs = ipairs
local type = type
local unpack = unpack

local class = require("class").class
local error_util = require("error_util")

local check = error_util.check
local checktype = error_util.checktype

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

-- Special separation characters that are disjoint with our encoding of color codes.
-- (See terminal_colors.lua)
local Sep = {
    Diag = {
        Value = '\0',
        Pattern = '%z',
    },
    -- Octet values that cannot be part of a well-formed UTF-8-encoded string.
    -- (See ISO/IEC 10646:2017 section 9.2)
    Line = '\xFE',
    EmptyInfo = '\xFD',
}

local SpecialCharsPattern = "[%z\xFE\xFD]"

local function patternFor(sep)
    return "([^"..sep.."]+)"..sep
end

local function FormattedDiagSet_Serialize(self)
    local tab = {}

    for _, diag in ipairs(self.diags) do
        local innerTab = {}

        for _, line in ipairs(diag) do
            assert(not line:find(SpecialCharsPattern))
            innerTab[#innerTab + 1] = line
        end

        tab[#tab + 1] = table.concat(innerTab, Sep.Line)..Sep.Line
    end

    if (self.info ~= nil) then
        assert(#self.info == 1)
        assert(not self.info[1]:find(SpecialCharsPattern))
        tab[#tab + 1] = self.info[1]..Sep.Line
    else
        tab[#tab + 1] = Sep.EmptyInfo..Sep.Line
    end

    return table.concat(tab, Sep.Diag.Value)..Sep.Diag.Value
end

local FormattedDiagSet  -- "forward-declare"
local InvalidStringMsg = "passed string that is not a formatted diagnostic serialization"

function api.FormattedDiagSet_Deserialize(diagsStr, useColors)
    checktype(diagsStr, 1, "string", 2)
    checktype(useColors, 2, "boolean", 2)

    local fDiagSet = FormattedDiagSet(useColors)

    for diagStr in diagsStr:gmatch(patternFor(Sep.Diag.Pattern)) do
        local fDiag = FormattedDiag(useColors)
        for line in diagStr:gmatch(patternFor(Sep.Line)) do
            fDiag[#fDiag + 1] = line
        end
        fDiagSet.diags[#fDiagSet.diags + 1] = fDiag
    end

    local lastDiag = fDiagSet.diags[#fDiagSet.diags]
    fDiagSet.info = (lastDiag[1] ~= Sep.EmptyInfo) and lastDiag or nil
    fDiagSet.diags[#fDiagSet.diags] = nil

    if (fDiagSet.info ~= nil) then
        local good = (#fDiagSet.info == 1 and not fDiagSet.info[1]:find(Sep.EmptyInfo))
        check(good, InvalidStringMsg..", or INTERNAL ERROR", 2)
    else
        -- TODO: also have a check?
    end

    return fDiagSet
end

FormattedDiagSet = class
{
    function(useColors)
        return {
            diags = {},  -- list of FormattedDiag objects
            info = nil,  -- nil or a FormattedDiag with one line

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

    serialize = FormattedDiagSet_Serialize,
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

local function PrintDiagsImpl(diags, useColors, allDiags,
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
        PrintDiagsImpl(diag:childDiagnostics(), useColors, allDiags,
                       innerStartIndex, indentation + 2, fDiag)

        local isFatal = (diag:severity() == "fatal")
        local isError = isFatal or diag:severity() == "error"
        local omitFollowing = not allDiags and (isFatal or (isError and diag:category() == "Parse Issue"))

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

function api.GetDiags(diags, useColors, allDiags)
    checktype(diags, 1, "table", 2)
    checktype(useColors, 2, "boolean", 2)
    checktype(allDiags, 3, "boolean", 2)

    return PrintDiagsImpl(diags, useColors, allDiags)
end

-- Done!
return api
