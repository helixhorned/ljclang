
local string = require("string")

local assert = assert
local type = type
local unpack = unpack

local checktype = require("error_util").checktype

local Col = require("terminal_colors")
local colorize = Col.colorize

----------

local api = {}

local function GetColorizeTripleFunc(severityTextColor, colorizeMainText)
    return function(pre, tag, post)
        return
            colorize(pre, Col.Bold..Col.White)..
            colorize(tag, Col.Bold..severityTextColor)..
            (colorizeMainText and colorize(post, Col.Bold..Col.White) or post)
    end
end

local ColorizeErrorFunc = GetColorizeTripleFunc(Col.Red, true)
local ColorizeWarningFunc = GetColorizeTripleFunc(Col.Purple, true)
local ColorizeNoteFunc = GetColorizeTripleFunc(Col.Black, false)

local function FormatDiagnostic(diag, useColors, printCategory)
    local text = diag:format()

    if (useColors) then
        text = text:gsub("(.*)(error: )(.*)", ColorizeErrorFunc)
        text = text:gsub("(.*)(warning: )(.*)", ColorizeWarningFunc)
        text = text:gsub("(.*)(note: )(.*)", ColorizeNoteFunc)
    end

    local category = diag:category()
    return text .. ((printCategory and #category > 0) and " ["..category.."]" or "")
end

local function PrintPrefixDiagnostics(diags, onNewTextLine, indentation)
    for i = 1, #diags do
        local text = diags[i]:spelling()

        if (text:match("^in file included from ")) then
            onNewTextLine("%s%s", string.rep(" ", indentation), "In"..text:sub(3))
        else
            return i
        end
    end

    return #diags + 1
end

-- <callbacks>: table { <onDiagBegin>, <onNewTextLine> [, <onDiagEnd>] }
--  <onNewTextLine> gets passed (fmt, ...) for each line of text that is emitted. Note:
--  `fmt` is not newline-terminated -- <onNewTextLine> is supposed to do that itself.
local function PrintDiags(diags, useColors, callbacks, startIndex, indentation)
    checktype(diags, 1, "table", 2)
    checktype(useColors, 2, "boolean", 2)
    checktype(callbacks, 3, "table", 3)

    local localCallbacks = { unpack(callbacks) }
    if (localCallbacks[3] == nil) then
        localCallbacks[3] = function() end
    end

    local onDiagBegin, onNewTextLine, onDiagEnd = unpack(localCallbacks, 1, 3)

    if (startIndex == nil) then
        startIndex = 1
    end
    if (indentation == nil) then
        indentation = 0
    end

    checktype(startIndex, 4, "number")
    checktype(indentation, 5, "number")

    for i = startIndex, #diags do
        onDiagBegin(i, indentation)

        local diag = diags[i]
        local childDiags = diag:childDiagnostics()

        local innerStartIndex = PrintPrefixDiagnostics(childDiags, onNewTextLine, indentation)
        local formattedDiag = FormatDiagnostic(diag, useColors, indentation == 0)
        onNewTextLine("%s%s", string.rep(" ", indentation), formattedDiag)

        -- Recurse. We expect only at most two levels in total (but do not check for that).
        PrintDiags(diag:childDiagnostics(), useColors, localCallbacks,
                   innerStartIndex, indentation + 2)

        onDiagEnd(i, indentation)
        if (indentation == 0) then
            -- Add a newline.
            onNewTextLine("")
        end
    end
end

api.PrintDiags = PrintDiags

-- Done!
return api
