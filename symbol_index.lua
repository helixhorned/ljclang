
local ffi = require("ffi")

local class = require("class").class
local posix = require("posix")
local linux_decls = require("ljclang_linux_decls")

local error_util = require("error_util")
local checktype = error_util.checktype
local check = error_util.check

local assert = assert
local tonumber = tonumber

----------

local api = {
    EntriesPerPage = nil  -- set below
}

local SymbolInfo = ffi.typeof[[struct {
    uint64_t intFlags;  // intrinsic flags (identifying a particular symbol)
    uint64_t extFlags;  // extrinsic flags (describing a particular symbol use)
}]]

local SymbolInfoPage = (function()
    local pageSize = posix.getPageSize()
    assert(pageSize % ffi.sizeof(SymbolInfo) == 0)
    api.EntriesPerPage = tonumber(pageSize / ffi.sizeof(SymbolInfo))
    return ffi.typeof("$ [$]", SymbolInfo, api.EntriesPerPage)
end)()

local SymbolInfoPagePtr = ffi.typeof("$ *", SymbolInfoPage)

local MaxSymPages = {
    Local = (ffi.abi("64bit") and 1*2^30 or 128*2^20) / ffi.sizeof(SymbolInfoPage),
    Global = (ffi.abi("64bit") and 4*2^30 or 512*2^20) / ffi.sizeof(SymbolInfoPage),
}

api.SymbolIndex = class
{
    function(localPageArrayCount)
        checktype(localPageArrayCount, 1, "number", 2)

        local PROT, MAP, LMAP = posix.PROT, posix.MAP, linux_decls.MAP

        local requestSymPages = function(count, flags, ptrTab)
            local voidPtr = posix.mmap(nil, count * ffi.sizeof(SymbolInfoPage),
                                       PROT.READ + PROT.WRITE, flags, -1, 0)
            -- Need to retain the pointer as its GC triggers the munmap().
            ptrTab[#ptrTab + 1] = voidPtr

            return ffi.cast(SymbolInfoPagePtr, voidPtr)
        end

        local localPageArrays, voidPtrs = {}, {}

        for i = 1, localPageArrayCount do
            localPageArrays[i] = requestSymPages(
                MaxSymPages.Local, MAP.SHARED + LMAP.ANONYMOUS, voidPtrs)
        end

        return {
            globalPageArray = requestSymPages(
                MaxSymPages.Global, MAP.PRIVATE + LMAP.ANONYMOUS, voidPtrs),
            localPageArrays = localPageArrays,
            voidPtrs_ = voidPtrs,
        }
    end,

    remapLocalToGlobalPage = function(self, localPageArrayIdx, srcPageIdx, globalPageIdx)
        checktype(localPageArrayIdx, 1, "number", 2)
        check(localPageArrayIdx >= 1 and localPageArrayIdx <= #self.localPageArrays,
              "argument #1 must be a valid local page array index" ,2)

        checktype(srcPageIdx, 2, "number", 2)
        check(srcPageIdx >= 0 and srcPageIdx < MaxSymPages.Local,
              "argument #2 must be a valid local page index", 2)
        checktype(globalPageIdx, 3, "number", 2)
        check(globalPageIdx >= 0 and globalPageIdx < MaxSymPages.Global,
              "argument #3 must be a valid global page index", 2)

        posix.memRemapSinglePage(
            self:getLocalPageArrayVoidPtr(localPageArrayIdx), srcPageIdx,
            self:getGlobalPageArrayVoidPtr(), globalPageIdx)
    end,

-- private, KEEPINSYNC with how self.voidPtrs_ is set up:
    getLocalPageArrayVoidPtr = function(self, localPageArrayIdx)
        return self.voidPtrs_[localPageArrayIdx]
    end,

    getGlobalPageArrayVoidPtr = function(self)
        return self.voidPtrs_[#self.voidPtrs_]
    end,
}

-- Done!
return api
