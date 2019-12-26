local ffi = require("ffi")
local C = ffi.C

local bit = require("bit")
local string = require("string")

local class = require("class").class
local error_util = require("error_util")

local ljposix = ffi.load("ljposix")
require("posix_types")
local decls = require("posix_decls")

local assert = assert
local check = error_util.check
local checktype = error_util.checktype
local error = error
local ipairs = ipairs
local tostring = tostring
local type = type

----------

ffi.cdef[[
void free(void *ptr);

ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
int open(const char *pathname, int flags);
int close(int);
int dup2(int oldfd, int newfd);

void *mmap(void *addr, size_t length, int prot, int flags,
           int fd, off_t offset);
int munmap(void *addr, size_t length);

char *strerror(int);

pid_t fork(void);
pid_t getpid(void);
pid_t waitpid(pid_t pid, int *stat_loc, int options);
int execv(const char *path, char *const argv[]);
int pipe(int pipefd[2]);

struct _IO_FILE;
typedef struct _IO_FILE FILE;
FILE *stdin, *stdout, *stderr;
FILE *freopen(const char *pathname, const char *mode, FILE *stream);
char *realpath(const char *path, char *resolved_path);
]]

-- NOTE: members have 'tv_' prefix stripped.
ffi.cdef[[
struct timespec {
    time_t sec;
    long   nsec;
};

int clock_gettime(clockid_t clock_id, struct timespec *tp);
int clock_nanosleep(clockid_t clock_id, int flags,
                    const struct timespec *request,
                    struct timespec *remain);
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
    O = decls.O,
    MAP = decls.MAP,
    POLL = decls.POLL,
    PROT = decls.PROT,
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

local function callAllowing(isErrnoAllowed, functionName, ...)
    local ret = C[functionName](...)
    local errno = (ret < 0) and ffi.errno() or nil

    if (ret < 0 and not isErrnoAllowed[errno]) then
        local message = string.format("%s failed: %s", functionName, getErrnoString())
        error(message)
    end

    return ret, errno
end

local char_array_t = ffi.typeof("char [?]")
local char_ptr_array_t = ffi.typeof("char * [?]")

local function makeArgv(tab)
    assert(tab[0] ~= nil)

    local argc = #tab + 1
    local charArrays = {}

    for i = 0, argc - 1 do
        local str = tab[i]
        check(type(str) == "string", "table values must be strings", 3)

        local charArray = char_array_t(#str + 1, str)
        assert(charArray[#str] == 0)
        charArrays[i] = charArray
    end

    local argv = char_ptr_array_t(argc + 1, charArrays)
    argv[argc] = nil
    return argv
end

----------

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
local Allow_EAGAIN = { [decls.E.AGAIN] = true }
local Allow_EPIPE = { [decls.E.PIPE] = true }

api.STDOUT_FILENO = 1
api.STDERR_FILENO = 2

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

    -- Read from a file descriptor previously opened with O_NONBLOCK.
    readNonblocking = function(self, byteCount)
        checktype(byteCount, 1, "number", 2)
        check(byteCount >= 1, "argument must be at least 1", 2)
        local buf = uint8_array_t(byteCount)
        local bytesRead, errno = callAllowing(Allow_EAGAIN, "read", self.fd, buf, byteCount)
        assert(bytesRead <= byteCount)
        return (errno == nil) and ffi.string(buf, bytesRead) or nil
    end,

    readInto = function(self, obj, allowPartial)
        checktype(obj, 1, "cdata", 2)
        checktype(allowPartial, 2, "boolean", 2)

        local length = ffi.sizeof(obj)
        check(length ~= nil, "argument #1 must have ffi.sizeof() ~= nil", 2)
        check(length >= 1, "argument #1 must have ffi.sizeof() >= 1", 2)

        local bytesRead = call("read", self.fd, obj, length)
        assert(bytesRead >= 0 and bytesRead <= length)
        check(allowPartial or bytesRead == length, "partial read occurred", 2)

        return obj, bytesRead
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

    -- Write to a file descriptor, catching EPIPE instead of propagating it as Lua error.
    writePipe = function(self, obj)
        check(type(obj) == "string" or type(obj) == "cdata",
              "argument #1 must be a string or cdata", 2)
        local length = (type(obj) == "string") and #obj or ffi.sizeof(obj)
        check(length > 0, "argument must have non-zero length", 2)
        local bytesWritten, errno = callAllowing(Allow_EPIPE, "write", self.fd, obj, length)
        assert(bytesWritten <= length)
        return (errno == nil) and bytesWritten or nil
    end,

    -- Redirect 'fd' to us.
    capture = function(self, fd)
        checktype(fd, 1, "number", 2)
        local ret = call("dup2", self.fd, fd)
        assert(ret == fd)
        return ret
    end,

    close = function(self)
        local ret = call("close", self.fd)
        self.fd = -1
        assert(ret == 0)
        return ret
    end,
--[[
-- TODO: implement
    __gc = function(self)
        return self:close()
    end,
--]]
}

local timespec_t = ffi.typeof("struct timespec")
local single_timespec_t = ffi.typeof("$ [1]", timespec_t)

-- TODO: for the clock_* functions:
--  - expose more or all arguments
--  - more proper argument and/or return value checking

api.clock_gettime = function()
    local ts = single_timespec_t()
    local ret = call("clock_gettime", decls.CLOCK.MONOTONIC, ts)
    assert(ret == 0)
    return ts[0]
end

api.clock_nanosleep = function(nsec)
    local request = timespec_t(nsec / 1e9, nsec % 1e9)
    local ret = call("clock_nanosleep", decls.CLOCK.MONOTONIC, 0, request, nil)
    assert(ret == 0)
end

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

-- NOTE: Linux's "man mmap" explicitly mentions this value.
local MAP_FAILED = ffi.cast("void *", -1)

api.mmap = function(addr, length, prot, flags, fd, offset)
    check(addr == nil, "argument #1 must be nil", 2)

    checktype(length, 2, "number", 2)
    check(length > 0, "argument #2 must be greater than zero", 2)

    checktype(prot, 3, "number", 2)
    checktype(flags, 4, "number", 2)

    local MAP, PROT = decls.MAP, decls.PROT
    check(bit.band(prot, bit.bnot(PROT.READ + PROT.WRITE)) == 0,
          "Only PROT.READ and/or PROT.WRITE allowed", 2)
    check(bit.band(prot, bit.bnot(MAP.SHARED + MAP.PRIVATE)) == 0,
          "Only MAP.SHARED or MAP.PRIVATE allowed", 2)

    checktype(fd, 5, "number", 2)
    checktype(offset, 6, "number", 2)

    local ptr = C.mmap(addr, length, prot, flags, fd, offset)
    if (ptr == MAP_FAILED) then
        error("mmap failed: "..getErrnoString())
    end

    return ffi.gc(ptr, function(p)
        C.munmap(p, length)
    end)
end

api.fork = function()
    local ret = call("fork")
    assert(ret >= 0)

    if (ret == 0) then
        return "child", nil
    else
        return "parent", ret
    end
end

-- Example: "/bin/ls", { "-la" }
api.exec = function(fileName, args)
    checktype(fileName, 1, "string", 2)
    check(#fileName > 0 and fileName:sub(1,1) == '/',
          "argument #1 must be an absolute file name", 2)
    checktype(args, 2, "table", 2)
    check(args[0] == nil, "argument #2 must not contain an entry at index 0", 2)

    args[0] = fileName

    local argv = makeArgv(args)
    call("execv", argv[0], argv)
    assert(false)
end

api.freopen = function(pathname, mode, stream)
    checktype(pathname, 1, "string", 2)
    checktype(mode, 2, "string", 2)

    check(ffi.istype("FILE *", stream), "argument #3 must be a FILE *", 2)
    check(stream ~= nil, "argument #3 must be non-NULL")

    local retPtr = C.freopen(pathname, mode, stream)

    if (retPtr == nil) then
        local message = string.format("freopen failed: %s", getErrnoString())
        error(message)
    end
end

api.realpath = function(pathname)
    checktype(pathname, 1, "string", 2)

    local retPtr = C.realpath(pathname, nil)

    if (retPtr == nil) then
        return nil, getErrnoString()
    end

    local str = ffi.string(retPtr)
    C.free(retPtr)
    return str
end

local pid_t = ffi.typeof("pid_t")

local function isPid(v)
    if (ffi.sizeof("void *") == 4) then
        return (type(v) == "number")
    else
        return ffi.istype("pid_t", v)
    end
end

api.waitpid = function(pid, options)
    check(isPid(pid), "argument #1 must be a pid", 2)
    -- Exclude other conventions other than passing -1 or an exact PID:
    check(pid == -1 or pid > 0, "argument #1 must be -1 or strictly positive", 2)
    checktype(options, 2, "number", 2)
    check(options == 0, "argument #2 must be 0 (not yet implemented)", 2)

    local stat_loc = ffi.new("int [1]")
    local ret_pid = call("waitpid", pid, stat_loc, options)
    assert(pid == -1 or ret_pid == pid)

    if (stat_loc[0] == 0) then
        return "exited", 0, ret_pid
    end

    -- Any other condition than exiting with status 0: not implemented.
    -- (We would have to have the W*() macros from sys/wait.h here somehow.)
    return "NYI", -1, pid_t(-1)
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
    check(sig == SIG.INT, "argument #1 must be SIG.INT", 2)
    check(handler == SIG_DFL, "argument #2 must be SIG.DFL", 2)
    ljposix.ljclang_setSigintHandlingToDefault()
end

-- Done!
return api
