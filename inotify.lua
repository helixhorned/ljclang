local ffi = require("ffi")
local C = ffi.C

local IN = require("inotify_decls")

local class = require("class").class
local check = require("error_util").check
local posix = require("posix")

local assert = assert
local error = error
local tonumber = tonumber
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
local sizeof_inotify_event_t = tonumber(ffi.sizeof(inotify_event_t))
local MaxEventsInBatch = 128
local EventBatch = ffi.typeof("$ [$]", inotify_event_t, MaxEventsInBatch)

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

    waitForEvents = function(self)
        local events, bytesRead = self.fd:readInto(EventBatch(), true)
        assert(bytesRead % sizeof_inotify_event_t == 0)
        local eventCount = tonumber(bytesRead) / sizeof_inotify_event_t

        local tab = {}

        for i = 1, eventCount do
            local event = events[i - 1]
            assert(event.len == 0)
            tab[i] = event
        end

        return tab
    end
}

-- Done!
return api
