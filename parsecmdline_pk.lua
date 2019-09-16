
local pairs = pairs

-- Get options and positional arguments from command line. A '--' stops option
-- processing and collects the following arguments into 'args' (positional
-- arguments), irrespective of whether they start with a dash.
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
-- opt_meta[0] is an offset for the indices of the returned <args> table.
-- For example, if it's -1, the args[0] will be the first positional argument.
-- Defaults to 0.
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
    local apos = 1 + (opt_meta[0] or 0)

    local skipnext = false
    local processOpts = true

    for i=1,#arg do
        if (skipnext) then
            skipnext = false
            goto next
        end

        if (arg[i] == "--") then
            processOpts = false
            goto next
        end

        if (processOpts and arg[i]:sub(1,1)=="-") then
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
                    if (opts[opt] ~= nil) then
                        usage("Duplicate option "..arg[i])
                    end
                    opts[opt] = arg[i+1]
                end
            else
                opts[opt] = true
            end
        else
            -- Uncommenting this makes option processing stop at the first
            -- non-option argument. When it is commented, options and
            -- positional arguments can be in any order, and only '--' stops
            -- option processing.
--            processOpts = false
            args[apos] = arg[i]
            apos = apos+1
        end
::next::
    end

    return opts, args
end

return {
    getopts = getopts
}
