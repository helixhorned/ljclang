local assert = assert
local pairs = pairs

local string = require("string")
local table = require("table")

local error_util = require("error_util")
local checktype = error_util.checktype

----------

local InternalCode = {
    Normal = string.char(1),
    Bold   = string.char(2),
    Uline  = string.char(3),

    Black  = string.char(4),
    Red    = string.char(5),
    Green  = string.char(6),
    Yellow = string.char(7),
    Blue   = string.char(8),
    Purple = string.char(11),
    Cyan   = string.char(12),
    White  = string.char(14),

    Begin = string.char(15),
    End = string.char(16),
}

local InternalCodeSeq = {}
for _, v in pairs(InternalCode) do
    InternalCodeSeq[#InternalCodeSeq + 1] = v
end

local InternalCodePattern = "[" .. table.concat(InternalCodeSeq) .. "]"

local api = {
    -- We pass outward our internal color codes. (Which are just lower control codes.
    -- Hopefully they are not encountered in diagnostic strings from Clang.)
    Normal = InternalCode.Normal,
    Bold   = InternalCode.Bold,
    Uline  = InternalCode.Uline,

    Black  = InternalCode.Black,
    Red    = InternalCode.Red,
    Green  = InternalCode.Green,
    Yellow = InternalCode.Yellow,
    Blue   = InternalCode.Blue,
    Purple = InternalCode.Purple,
    Cyan   = InternalCode.Cyan,
    White  = InternalCode.White,
}

-- For reference:
-- https://wiki.archlinux.org/index.php/Color_Bash_Prompt#List_of_colors_for_prompt_and_Bash
local ToTerminalCode = {
    [InternalCode.Normal] = "0;",
    [InternalCode.Bold] = "1;",
    [InternalCode.Uline] = "4;",

    [InternalCode.Black] = "30m",
    [InternalCode.Red] = "31m",
    [InternalCode.Green] = "32m",
    [InternalCode.Yellow] = "33m",
    [InternalCode.Blue] = "34m",
    [InternalCode.Purple] = "35m",
    [InternalCode.Cyan] = "36m",
    [InternalCode.White] = "37m",

    [InternalCode.Begin] = "\027[",
    [InternalCode.End] = "\027[m",
}

api.encode = function(str, modcolor)
    checktype(str, 1, "string", 2)
    checktype(modcolor, 2, "string", 2)

    assert(not str:match(InternalCodePattern),
           "String to color-code contains lower control chars")

    return InternalCode.Begin .. modcolor..str.. InternalCode.End
end

api.colorize = function(coded_str)
    checktype(coded_str, 1, "string", 2)
    return coded_str:gsub(InternalCodePattern, ToTerminalCode)
end

api.strip = function(coded_str)
    checktype(coded_str, 1, "string", 2)
    return coded_str:gsub(InternalCodePattern, "")
end

-- Done!
return api
