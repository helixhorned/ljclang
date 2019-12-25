#!/usr/bin/env luajit

local ffi = require("ffi")

local io = require("io")
local os = require("os")

local FrameBuffer = require("framebuffer").FrameBuffer
local posix = require("posix")

local arg = arg
local print = print
local tonumber = tonumber

----------

-- NOTE: on the Raspberry Pi, malloc() and calloc() are significantly faster than ffi.new
ffi.cdef[[
void *malloc(size_t size);
void free(void *ptr);
]]

local function Array(elementType, count)
    local ptrType = ffi.typeof("$ *", elementType)
    local voidPtr = ffi.C.malloc(ffi.sizeof(elementType) * count)
    return ffi.gc(ptrType(voidPtr), ffi.C.free)
end

local function currentTimeMs()
    local ts = posix.clock_gettime()
    return 1000 * tonumber(ts.sec) + tonumber(ts.nsec) / 1000000
end

----------

local continuous = (arg[1] == 'c')
local toStdout = (arg[1] == '-')

if (not (continuous or toStdout)) then
    print("Usage: "..arg[0].." [-|c]")
    print("Captures the screen to in an unspecified 8-bit format.")
    print(" -: to stdout")
    print(" c: continuously, without output")
    os.exit(1)
end

local fb = FrameBuffer(0, false)
local map = fb:getMapping()
local unpackPx = map:getUnpackPixelFunc()
local fbPtr = map:getPixelPointer()

local size = map:getSize()
local tempBuf = Array(map:getPixelType(), size)
local narrowBuf = Array(ffi.typeof("uint8_t"), size)

local function copyAndNarrow()
    -- NOTE: this significantly speeds things up (both on the Pi and the desktop).
    ffi.copy(tempBuf, fbPtr, size * map:getPixelSize())

    for i = 0, size - 1 do
        local r, _g, _b, _a = unpackPx(tempBuf[i])
        narrowBuf[i] = r
    end
end

repeat
    local startMs = currentTimeMs()
    copyAndNarrow()
    io.stderr:write(("%.0f ms\n"):format(currentTimeMs() - startMs))
until (not continuous)

-- NOTE: never reached in continuous mode.
io.write(ffi.string(narrowBuf, size))
