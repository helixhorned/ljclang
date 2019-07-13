#!/usr/bin/env luajit

local io = io
local ipairs = ipairs

if (arg[1] == nil) then
    print("Usage: "..arg[0].." <docfile> [<srcfiles...>]")
    os.exit(1)
end

local docLines = {}
local srcLines = {}

local function readFileIntoTable(fileName, table)
    local f = io.open(fileName)
    assert(f ~= nil)
    repeat
        local s = f:read()
        table[#table + 1] = s
    until (s == nil)
end

readFileIntoTable(arg[1], docLines)

for i = 2,#arg do
    readFileIntoTable(arg[i], srcLines)
end

local LineBegPattern = "^ *%-%- "
-- For continued doc lines, it is valid to not have a space after the comment marker.
local LineContPattern = "^ *%-%- ?"

local function findText(table, searchText)
    local lineNum

    for i, line in ipairs(table) do
        if (line:match(LineBegPattern) and line:gsub(LineBegPattern, ""):find(searchText, 1, true)) then
            if (lineNum ~= nil) then
                error("Search text '" .. searchText .. "' is present multiple times.")
            end
            lineNum = i
        end
    end

    return lineNum
end

local sections = {}

for i = 1, #docLines do
    local docLine = docLines[i]
    local nextLine = docLines[i + 1] or ""
    if (docLine:match("^[A-Za-z ]+$") and
            nextLine == string.rep('-', #docLine)) then
        sections[#sections + 1] = docLine
    end
end

for _, docLine in ipairs(docLines) do
    local searchText = docLine:match("^@@(.*)")

    if (searchText == nil) then
        io.write(docLine, '\n')
    elseif (searchText == "[toc]") then
        -- Link to auto-generated anchor tags on GitHub.
        for i, section in ipairs(sections) do
            local str = string.format("**[%s](#%s)**%s",
                                      section, section:lower():gsub(' ', '-'),
                                      i < #sections and '\\' or "")
            io.write(str, '\n')
        end
    elseif (searchText:sub(1,5) == "[run]") then

        io.write("~~~~~~~~~~\n")

        local command = searchText:sub(6)
        local helpText = io.popen(command):read("*a")
        io.write(helpText)

        io.write("~~~~~~~~~~\n")
    else
        local lineNum = findText(srcLines, searchText)

        if (lineNum == nil) then
            io.write(docLine, '\n')
        else
            for i = lineNum, #srcLines do
                local line = srcLines[i]

                if (not line:match(LineContPattern)) then
                    break
                end

                io.write(line:gsub(LineContPattern, ""), "\n")
            end
        end
    end
end
