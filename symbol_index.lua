
local ffi = require("ffi")

local class = require("class").class
local posix = require("posix")
local linux_decls = require("ljclang_linux_decls")

local error_util = require("error_util")
local checktype = error_util.checktype

local assert = assert
local tonumber = tonumber

----------

local api = {}

local SymbolInfo = ffi.typeof[[struct {
    uint64_t intFlags;  // intrinsic flags (identifying a particular symbol)
    uint64_t extFlags;  // extrinsic flags (describing a particular symbol use)
}]]

local SymbolInfoPage = (function()
    local pageSize = posix.sysconf(posix._SC.PAGESIZE)
    assert(pageSize % ffi.sizeof(SymbolInfo) == 0)
    return ffi.typeof("$ [$]", SymbolInfo, tonumber(pageSize / ffi.sizeof(SymbolInfo)))
end)()

local MaxSymPages = {
    Local = (ffi.abi("64bit") and 1*2^30 or 128*2^20) / ffi.sizeof(SymbolInfoPage),
    Global = (ffi.abi("64bit") and 4*2^30 or 512*2^20) / ffi.sizeof(SymbolInfoPage),
}

api.SymbolIndex = class
{
    function(localPageArrayCount)
        checktype(localPageArrayCount, 1, "number", 2)

        local PROT, MAP, LMAP = posix.PROT, posix.MAP, linux_decls.MAP
        local SymbolInfoPagePtr = ffi.typeof("$ *", SymbolInfoPage)

        local requestSymPages = function(count, flags, ptrTab)
            local voidPtr = posix.mmap(nil, count * ffi.sizeof(SymbolInfoPage),
                                       PROT.READ + PROT.WRITE, flags, -1, 0)
            -- Need to retain the pointer as its GC triggers the munmap().
            ptrTab[#ptrTab + 1] = voidPtr

            return ffi.cast(SymbolInfoPagePtr, voidPtr)
        end

        local allLocalPages, voidPtrs = {}, {}

        for i = 1, localPageArrayCount do
            allLocalPages[i] = requestSymPages(
                MaxSymPages.Local, MAP.SHARED + LMAP.ANONYMOUS, voidPtrs)
        end

        return {
            globalPages = requestSymPages(
                MaxSymPages.Global, MAP.PRIVATE + LMAP.ANONYMOUS, voidPtrs),
            allLocalPages = allLocalPages,
            voidPtrs_ = voidPtrs,
        }
    end,
}

-- Done!
return api
