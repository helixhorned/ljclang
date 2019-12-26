-- Implementation of the JKISS random number generator from
-- http://www0.cs.ucl.ac.uk/staff/D.Jones/GoodPracticeRNG.pdf

local ffi = require("ffi")

local bit = require("bit")

local class = require("class").class

local tonumber = tonumber

----------

local api = {}

local uint32_t = ffi.typeof("uint32_t")
local uint64_t = ffi.typeof("uint64_t")

api.JKissRng = class
{
    "uint32_t x, y, z, c;",

    __new = function(ct)
        return ffi.new(ct, 123456789, 987654321, 43219876, 654321)
    end,

    getu32 = function(self)
        self.x = 314527869 * self.x + 1234567

        self.y = bit.bxor(self.y, bit.lshift(self.y, 5))
        self.y = bit.bxor(self.y, bit.rshift(self.y, 7))
        self.y = bit.bxor(self.y, bit.lshift(self.y, 22))

        local t = 4294584393ULL * self.z + self.c
        -- NOTE: bit operations on 64-bit integers are a LuaJIT 2.1 feature,
        -- according to:
        --  https://github.com/Egor-Skriptunoff/pure_lua_SHA/blob/master/README.md
        self.c = bit.rshift(t, 32)
        self.z = t

        local sum = uint64_t(self.x) + self.y + self.z
        return tonumber(uint32_t(sum))
    end,

    getDouble = function(self)
        local hi = bit.rshift(self:getu32(), 6) -- 26 bits
        local lo = bit.rshift(self:getu32(), 5) -- 27 bits
        return (hi * 0x1p27 + lo) / 0x1p53
    end,
}

-- Done!
return api
