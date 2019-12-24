#!/usr/bin/env luajit

local ffi = require("ffi")

local io = require("io")
local os = require("os")

local FrameBuffer = require("framebuffer").FrameBuffer

local arg = arg
local print = print

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

----------

if (arg[1] ~= "-") then
    print("Usage: "..arg[0].." -")
    print("Captures the screen to stdout in an unspecified 8-bit format.")
    os.exit(1)
end

local fb = FrameBuffer(0, false)
local map = fb:getMapping()
local unpackPx = map:getUnpackPixelFunc()
local fbPtr = map:getPixelPointer()

local size = map:getSize()
local tempBuf = Array(map:getPixelType(), size)
local narrowBuf = Array(ffi.typeof("uint8_t"), size)

-- NOTE: this significantly speeds things up (both on the Pi and the desktop).
ffi.copy(tempBuf, fbPtr, size * map:getPixelSize())

for i = 0, size - 1 do
    local r, _g, _b, _a = unpackPx(tempBuf[i])
    narrowBuf[i] = r
end

io.write(ffi.string(narrowBuf, size))
