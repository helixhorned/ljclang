#!/usr/bin/env luajit

local ffi = require("ffi")

local io = require("io")
local os = require("os")

local FrameBuffer = require("framebuffer").FrameBuffer

local arg = arg
local print = print

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
local narrowBuf = ffi.new("uint8_t [?]", size)

for i = 0, size - 1 do
    local r, _g, _b, _a = unpackPx(fbPtr[i])
    narrowBuf[i] = r
end

io.write(ffi.string(narrowBuf, size))
