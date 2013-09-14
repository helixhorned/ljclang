
local pairs = pairs

-- Get options from command line.
--
-- opts, args = getopts(opt_meta, arg, usage_func)
--
-- <opts>: table { [optletter]=true/false/string/tab }
-- <args>: string sequence
--
-- <opt_meta>: Meta-information about options, table of [optletter]=<info>,
--  false: doesn't have argument (i.e. is switch)
--  true: has argument, collect once
--  1: has argument, collect all
--
-- <arg>: The arguments provided to the program
-- <usage_func>: Function to print usage and terminate. Should accept optional
--   prefix line.
local function getopts(opt_meta, arg, usage)
    local opts = {}
    for k,v in pairs(opt_meta) do
        -- Init tables for collect-multi options.
        if (v and v~=true) then
            opts[k] = {}
        end
    end

    -- The extracted positional arguments:
    local args = {}

    local skipnext = false
    for i=1,#arg do
        if (skipnext) then
            skipnext = false
            goto next
        end

        if (arg[i]:sub(1,1)=="-") then
            local opt = arg[i]:sub(2)
            skipnext = opt_meta[opt]
            if (skipnext == nil) then
                usage("Unrecognized option "..arg[i])
            elseif (skipnext) then
                if (arg[i+1] == nil) then
                    usage()
                end
                if (skipnext~=true) then
                    opts[opt][#opts[opt]+1] = arg[i+1]
                else
                    opts[opt] = arg[i+1]
                end
            else
                opts[opt] = true
            end
        else
            local ii=1
            for j=i,#arg do
                args[ii] = arg[j]
                ii = ii+1
            end
            break
        end
::next::
    end

    return opts, args
end

return {
    getopts = getopts
}
