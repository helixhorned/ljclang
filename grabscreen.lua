#!/usr/bin/env luajit

local ffi = require("ffi")

local io = require("io")
local os = require("os")

local class = require("class").class
local FrameBuffer = require("framebuffer").FrameBuffer
local JKissRng = require("jkiss_rng").JKissRng
local posix = require("posix")

local assert = assert
local print = print
local tonumber = tonumber

local arg = arg
local stderr = io.stderr

----------

-- NOTE: on the Raspberry Pi, malloc() and calloc() are significantly faster than ffi.new
ffi.cdef[[
void *malloc(size_t size);
void free(void *ptr);

int memcmp(const void *s1, const void *s2, size_t n);
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
local sampling = (arg[1] == 's')
local toStdout = (arg[1] == '-')

if (not (continuous or sampling or toStdout)) then
    print("Usage: "..arg[0].." [-|c|s]")
    print("Captures the screen to in an unspecified 8-bit format.")
    print(" -: to stdout")
    print(" c: continuously, without output")
    print(" s: sample framebuffer periodically (implies 'c')")
    print("")
    os.exit(1)
end

continuous = continuous or sampling

local fb = FrameBuffer(0, false)
local map = fb:getMapping()
local unpackPx = map:getUnpackPixelFunc()
local fbPtr = map:getBasePointer()

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

---------- Sampling and comparison ----------

local SideLen = 8
local SquareSize = SideLen * SideLen  -- in pixels
assert(map.xres % SideLen == 0)
assert(map.yres % SideLen == 0)

local SBuf = ffi.typeof[[struct {
    static const int Current = 0;
    static const int Other = 1;
}]]

local Sampler = class
{
    function()
        assert(size % SquareSize == 0)
        local sampleCount = size / SquareSize

        return {
            rng = JKissRng(),
            fbIndexes = {},
            sampleCount = sampleCount,
            currentBufIdx = 0,
            sampleBufs = {
                [0] = Array(map:getPixelType(), sampleCount),
                [1] = Array(map:getPixelType(), sampleCount),
            }
        }
    end,

    generate = function(self)
        local idxs = {}

        for y = 0, map.yres - 1, SideLen do
            for x = 0, map.xres - 1, SideLen do
                local xoff = self.rng:getu32() % SideLen
                local yoff = self.rng:getu32() % SideLen

                idxs[#idxs + 1] = map:getLinearIndex(x + xoff, y + yoff)
            end
        end

        assert(#idxs == self.sampleCount)

        self.fbIndexes = idxs
    end,

    sample = function(self)
        assert(#self.fbIndexes == self.sampleCount)

        self:switchBuffer()
        local sampleBuf = self:getBuffer(SBuf.Current)

        for i = 1, self.sampleCount do
            sampleBuf[i] = fbPtr[self.fbIndexes[i]]
        end
    end,

    compare = function(self)
        local currentBuf = self:getBuffer(SBuf.Current)
        local otherBuf = self:getBuffer(SBuf.Other)
        local byteCount = self.sampleCount * map:getPixelSize()
        return (ffi.C.memcmp(currentBuf, otherBuf, byteCount) ~= 0)
    end,

-- private:
    getBuffer = function(self, which)
        local bufIdx = (which == SBuf.Current)
            and self.currentBufIdx
            or 1 - self.currentBufIdx
        return self.sampleBufs[bufIdx]
    end,

    switchBuffer = function(self)
        self.currentBufIdx = 1 - self.currentBufIdx
    end,
}

-- "Forward-declare"
local sampleAndCompare

if (sampling) then
    local sampler = Sampler()

    sampler:generate()

    function sampleAndCompare()
        sampler:sample()

        if (sampler:compare()) then
            stderr:write("changed\n")
            -- Perturb the positions of the pixesl to be sampled.
            sampler:generate()
        end
    end
end

----------

local testFunc = sampling and sampleAndCompare or copyAndNarrow

repeat
    local startMs = currentTimeMs()
    testFunc()
    stderr:write(("%.0f ms\n"):format(currentTimeMs() - startMs))
until (not continuous)

-- NOTE: never reached in continuous mode.
io.write(ffi.string(narrowBuf, size))
