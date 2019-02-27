local ffi = require("ffi")
local C = ffi.C

local IN = require("inotify_decls")

local class = require("class").class
local check = require("error_util").check

local error = error
local tostring = tostring
local type = type

----------

ffi.cdef[[
int close(int);
char *strerror(int);

struct inotify_event {
    int      wd;
    uint32_t mask;
    uint32_t cookie;

    uint32_t len;
    char     name[];
};
]]

local api = { IN=IN }

local function getErrnoString(errno)
    local errmsgCStr = C.strerror(ffi.errno())
    return (errmsgCStr ~= nil) and ffi.string(errmsgCStr) or "errno="..tostring(errno)
end

local inotify_event = ffi.typeof("struct inotify_event")

api.init = class
{
    function(flags)
        check(flags == nil or type(flags) == "number",
              "<flags> must be nil or a number", 2)

        local fd = (flags == nil) and C.inotify_init() or C.inotify_init1(flags)

        if (fd == -1) then
            local funcname = (flags == nil) and "inotify_init" or "inotify_init1"
            error(funcname.."() failed: "..getErrnoString())
        end

        return {
            fd = fd
        }
    end,

    __gc = function(self)
        C.close(self.fd)
    end,

    add_watch = function(self, pathname, mask)
        check(type(pathname) == "string", "<pathname> must be a string", 2)
        check(type(mask) == "number", "<mask> must be a number", 2)

        local wd = C.inotify_add_watch(self.fd, pathname, mask)

        if (wd == -1) then
            error("inotify_add_watch() failed: "..getErrnoString())
        end
    end,
}

-- Done!
return api
