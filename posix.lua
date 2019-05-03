local ffi = require("ffi")
local C = ffi.C

local string = require("string")

local class = require("class").class
local error_util = require("error_util")
local decls = require("posix_decls")

local _ljclang_USED_ONLY_FOR_typedefs = require("ljclang")
local support = ffi.load("ljclang_support")

local assert = assert
local check = error_util.check
local checktype = error_util.checktype
local error = error
local ipairs = ipairs
local tostring = tostring
local type = type

----------

ffi.cdef[[
ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
int close(int);

char *strerror(int);

pid_t fork(void);
pid_t getpid(void);
int pipe(int pipefd[2]);
]]

-- NOTE: POSIX integer types declared in ljclang.lua.
ffi.cdef[[
struct pollfd {
    int   fd;
    short events;
    short revents;
};

int poll(struct pollfd fds[], nfds_t nfds, int timeout);

int sigaddset(sigset_t *, int);
int sigprocmask(int, const sigset_t *restrict, sigset_t *restrict);

void ljclang_setSigintHandlingToDefault();
]]

local pollfd_t = ffi.typeof("struct pollfd")
local pollfd_array_t = ffi.typeof("$ [?]", pollfd_t)

local SIG = decls.SIG
local SIG_DFL = pollfd_t()  -- just a marker with a unique address

local external_SIG = {
    INT = SIG.INT,
    DFL = SIG_DFL,
}

local api = {
    POLL = decls.POLL,
    SIG = external_SIG,
}

local function getErrnoString()
    local errno = ffi.errno()
    local errmsgCStr = C.strerror(errno)
    return (errmsgCStr ~= nil) and ffi.string(errmsgCStr) or "errno="..tostring(errno)
end

api.getErrnoString = getErrnoString

local function call(functionName, ...)
    local ret = C[functionName](...)

    if (ret < 0) then
        local message = string.format("%s failed: %s", functionName, getErrnoString())
        error(message)
    end

    return ret
end

do
    -- Block SIGPIPE so that the writes to pipes with no one to read it (possible only by
    -- application logic error) return, the EPIPE errno is seen, and we throw a Lua error.
    --
    -- TODO: think about whether to keep here of move elsewhere.
    local sigset = ffi.new("sigset_t [1]")
    call("sigaddset", sigset, SIG.PIPE)
    call("sigprocmask", SIG.BLOCK, sigset, nil)
end

local uint8_array_t = ffi.typeof("uint8_t [?]")

api.Fd = class
{
    function(fd)
        checktype(fd, 1, "number", 2)

        return {
            fd = fd,
        }
    end,

    read = function(self, byteCount)
        checktype(byteCount, 1, "number", 2)
        check(byteCount >= 1, "argument must be at least 1", 2)
        local buf = uint8_array_t(byteCount)
        local bytesRead = call("read", self.fd, buf, byteCount)
        assert(bytesRead <= byteCount)
        return ffi.string(buf, bytesRead)
    end,

    readInto = function(self, obj)
        checktype(obj, 1, "cdata", 2)
        local length = ffi.sizeof(obj)
        check(length ~= nil, "argument must have ffi.sizeof() ~= nil", 2)
        check(length >= 1, "argument must have ffi.sizeof() >= 1", 2)
        local bytesRead = call("read", self.fd, obj, length)
        -- Partial reads not yet handled.
        check(bytesRead == length, "partial read occurred")
        return obj
    end,

    write = function(self, obj)
        check(type(obj) == "string" or type(obj) == "cdata",
              "argument #1 must be a string or cdata", 2)
        local length = (type(obj) == "string") and #obj or ffi.sizeof(obj)
        check(length > 0, "argument must have non-zero length", 2)
        local bytesWritten = call("write", self.fd, obj, length)
        assert(bytesWritten <= length)
        return bytesWritten
    end,

    close = function(self)
        local ret = call("close", self.fd)
        self.fd = -1
        assert(ret == 0)
        return ret
    end,

    __gc = function(self)
        return self:close()
    end,
}

api.poll = function(tab)
    checktype(tab, 1, "table", 2)
    check(#tab > 0, "passed table must not be empty", 2)

    local homogenousEventSet = (tab.events ~= nil) and tab.events or nil
    assert(homogenousEventSet ~= nil, "must provide <tab>.events: "..
               "inhomogenous event specification not implemented")

    local pollfds = pollfd_array_t(#tab, pollfd_t{0, tab.events, 0})

    for i, fd in ipairs(tab) do
        check(type(fd) == "number", "numeric elements of passed table must be numbers", 2)
        pollfds[i - 1].fd = fd
    end

    local eventCount = call("poll", pollfds, #tab, -1)
    assert(eventCount >= 0)

    local events = {}

    for i = 0, #tab - 1 do
        if (pollfds[i].revents ~= 0) then
            local p = pollfds[i]
            events[#events + 1] = pollfd_t(p)
        end
    end

    assert(#events == eventCount)
    return events
end

api.fork = function()
    local ret = call("fork")
    assert(ret >= 0)

    if (ret == 0) then
        return "child", C.getpid()
    else
        return "parent", ret
    end
end

api.pipe = function()
    local fds = ffi.new("int [2]")
    local ret = call("pipe", fds)
    assert(ret == 0)

    return {
        r = api.Fd(fds[0]),
        w = api.Fd(fds[1]),
    }
end

api.signal = function(sig, handler)
    check(sig == SIG.INT, "argument #1 must be SIG.INT")
    check(handler == SIG_DFL, "argument #2 must be SIG.DFL")
    support.ljclang_setSigintHandlingToDefault()
end

-- Done!
return api
