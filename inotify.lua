local ffi = require("ffi")
local C = ffi.C

local IN = require("inotify_decls")

local class = require("class").class
local check = require("error_util").check
local posix = require("posix")

local assert = assert
local error = error
local tostring = tostring
local type = type

----------

ffi.cdef[[
struct inotify_event {
    int      wd;
    uint32_t mask;
    uint32_t cookie;

    uint32_t len;
//    char     name[];
};
]]

local api = { IN=IN }

local getErrnoString = posix.getErrnoString

local inotify_event_t = ffi.typeof("struct inotify_event")

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
            fd = posix.Fd(fd)
        }
    end,
--[[
-- TODO: implement
    __gc = function(self)
        self:close()
    end,
--]]
    getRawFd = function(self)
        check(self.fd.fd ~= -1, "must call before closing", 2)
        return self.fd.fd
    end,

    close = function(self)
        if (self.fd.fd ~= -1) then
            self.fd:close()
        end
    end,

    add_watch = function(self, pathname, mask)
        check(type(pathname) == "string", "<pathname> must be a string", 2)
        check(type(mask) == "number", "<mask> must be a number", 2)

        local wd = C.inotify_add_watch(self.fd.fd, pathname, mask)

        if (wd == -1) then
            error("inotify_add_watch() on '"..pathname.."' failed: "..getErrnoString())
        end

        assert(wd >= 0)
        return wd
    end,

    check_ = function(self) -- TEMP
        local ev = self.fd:readInto(inotify_event_t())

        -- TODO: read all in the queue (needs switching between nonblocking and blocking at
        -- runtime?) A: No, did not work out well.
        --
        -- But at least then read a handful of events so that the probabilty of losing some
        -- is reduced! (We could have many events at once if many files were modified at
        -- once, e.g. git stash or checkout)

        assert(ev.len == 0)
        return ev
    end
}

-- Done!
return api
