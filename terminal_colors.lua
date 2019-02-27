
-- For reference:
-- https://wiki.archlinux.org/index.php/Color_Bash_Prompt#List_of_colors_for_prompt_and_Bash

return {
--Normal = "0;",
Bold = "1;",
--Uline = "4;",

Black = "30m",
Red = "31m",
--Green = "32m",
--Yellow = "33m",
--Blue = "34m",
Purple = "35m",
--Cyan = "36m",
White = "37m",

colorize = function(str, modcolor)
    return "\027["..modcolor..str.."\027[m"
end
}
