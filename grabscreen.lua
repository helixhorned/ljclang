#!/usr/bin/env luajit

local ffi = require("ffi")

local io = require("io")
local os = require("os")

local class = require("class").class
local FrameBuffer = require("framebuffer").FrameBuffer
local JKissRng = require("jkiss_rng").JKissRng
local posix = require("posix")

local _ok, _sha2 = pcall(function() return require("sha2") end)
local sha2 = _ok and _sha2 or nil

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

if (sampling and sha2 == nil) then
    stderr:write("WARNING: 'sha2' unavailable. Will only sample but not hash.\n")
    os.execute("/bin/sleep 1")

    sha2 = {
        sha1 = function(str)
            assert(str ~= nil)
            return "<unavailable>"
        end
    }
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

---------- Sampling and hashing ----------

local SideLen = 8
local SquareSize = SideLen * SideLen  -- in pixels
assert(map.xlen % SideLen == 0)
assert(map.ylen % SideLen == 0)

local function GetLinearIndex(x, y)
    return map.xlen * y + x
end

local Sampler = class
{
    function()
        assert(size % SquareSize == 0)
        local sampleCount = size / SquareSize

        return {
            rng = JKissRng(),
            fbIndexes = {},
            sampleCount = sampleCount,
            sampleBuf = Array(map:getPixelType(), sampleCount),
        }
    end,

    generate = function(self)
        local idxs = {}

        for y = 0, map.ylen - 1, SideLen do
            for x = 0, map.xlen - 1, SideLen do
                local xoff = self.rng:getu32() % SideLen
                local yoff = self.rng:getu32() % SideLen

                local linearIdx = GetLinearIndex(x + xoff, y + yoff)
                assert(linearIdx < size)
                idxs[#idxs + 1] = linearIdx
            end
        end

        assert(#idxs == self.sampleCount)

        self.fbIndexes = idxs
    end,

    sample = function(self)
        assert(#self.fbIndexes == self.sampleCount)

        for i = 1, self.sampleCount do
            self.sampleBuf[i] = fbPtr[self.fbIndexes[i]]
        end
    end,

    hash = function(self)
        local byteCount = self.sampleCount * map:getPixelSize()
        return sha2.sha1(ffi.string(self.sampleBuf, byteCount))
    end
}

-- "Forward-declare"
local sampleAndHash

if (sampling) then
    local sampler = Sampler()
    local currentHash = "<unavailable>"

    sampler:generate()

    function sampleAndHash()
        sampler:sample()
        local hash = sampler:hash()

        if (hash ~= currentHash) then
            currentHash = hash
            stderr:write("changed\n")
            -- Perturb the positions of the pixesl to be sampled.
            sampler:generate()
        end
    end
end

----------

local testFunc = sampling and sampleAndHash or copyAndNarrow

repeat
    local startMs = currentTimeMs()
    testFunc()
    stderr:write(("%.0f ms\n"):format(currentTimeMs() - startMs))
until (not continuous)

-- NOTE: never reached in continuous mode.
io.write(ffi.string(narrowBuf, size))