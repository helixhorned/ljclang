local ffi = require("ffi")
local C = ffi.C

local class = require("class").class
local error_util = require("error_util")
local linux_decls = require("linux_decls")
local posix = require("posix")

local checktype = error_util.checktype

local FBIO = linux_decls.FBIO
local O = posix.O

local error = error
local unpack = unpack

----------

local fb_fix_screeninfo = ffi.typeof("struct fb_fix_screeninfo")
local fb_var_screeninfo = ffi.typeof("struct fb_var_screeninfo")

ffi.cdef[[
int ioctl(int fd, unsigned long request, ...);
]]

local function ioctl(fd, request, arg)
    -- NOTE: will error if 'arg' present and not convertible to pointer.
    local ptr = (arg ~= nil) and ffi.new("void *", arg) or nil
    local vargs = { ptr }

    local res = C.ioctl(fd, request, unpack(vargs))

    if (res == -1) then
        return nil, posix.getErrnoString()
    end

    -- NOTE: 'res' discarded (currently no use).
    return arg
end

----------

local api = {}

api.FrameBuffer = class
{
    function(fbIndex, writable)
        checktype(fbIndex, 1, "number", 2)
        checktype(writable, 2, "boolean", 2)

        local deviceFileName = "/dev/fb"..fbIndex
        local fd = C.open(deviceFileName, writable and O.RDWR or O.RDONLY)
        if (fd == -1) then
            error("Failed opening "..deviceFileName..": "..posix.getErrnoString())
        end

        local finfo, errMsg = ioctl(fd, FBIO.GET_FSCREENINFO, fb_fix_screeninfo())
        if (finfo == nil) then
            C.close(fd)
            error("Failed getting fixed framebuffer info: "..posix.getErrnoString())
        end

        return {
            fd = fd,
            writable = writable,

            type = finfo.type,
            visual = finfo.visual,
            line_length = finfo.line_length,
        }
    end,

    getVarInfo = function(self)
        local vinfo, errMsg = ioctl(self.fd, FBIO.GET_VSCREENINFO, fb_var_screeninfo())
        if (vinfo == nil) then
            error("Failed getting variable framebuffer info: "..posix.getErrnoString())
        end
        return vinfo
    end,

    close = function(self)
        C.close(self.fd)
    end,
}

-- Done!
return api
