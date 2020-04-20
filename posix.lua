local ffi = require("ffi")
local C = ffi.C

local bit = require("bit")
local string = require("string")

local class = require("class").class
local error_util = require("error_util")

local ljposix = ffi.load("ljposix")
require("posix_types")
local decls = require("posix_decls")
local linux_decls = require("ljclang_linux_decls")

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
long sysconf(int name);

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

-- NOTE: readdir64() is glibc-specific. We use it instead of readdir() because 'struct
-- dirent' has #ifndef-conditional member definitions while 'struct dirent64' does not.
ffi.cdef[[
struct _DIR;
struct dirent64;
typedef struct _DIR DIR;
DIR *opendir(const char *name);
int closedir(DIR *dirp);
struct dirent64 *readdir64(DIR *dirp);
const char *ljclang_getDirent64Name(const struct dirent64 *dirent);
]]

-- NOTE: leave type 'struct sockaddr' incomplete.
ffi.cdef[[
struct sockaddr;
int socket(int domain, int type, int protocol);
int bind(int socket, const struct sockaddr *address, socklen_t address_len);
int connect(int socket, const struct sockaddr *address, socklen_t address_len);
int listen(int socket, int backlog);
int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
int shutdown(int sockfd, int how);
]]

ffi.cdef[[
int clock_gettime(clockid_t clock_id, struct timespec *tp);
int clock_nanosleep(clockid_t clock_id, int flags,
                    const struct timespec *request,
                    struct timespec *remain);

int poll(struct pollfd fds[], nfds_t nfds, int timeout);

int sigaddset(sigset_t *, int);
int sigemptyset(sigset_t *);
int sigprocmask(int, const sigset_t *restrict, sigset_t *restrict);

void ljclang_setSigintHandlingToDefault();
]]

local pollfd_t = ffi.typeof("struct pollfd")
local pollfd_array_t = ffi.typeof("$ [?]", pollfd_t)

ffi.cdef[[
void ljclang_FD_CLR(int fd, fd_set *set);
int  ljclang_FD_ISSET(int fd, fd_set *set);
void ljclang_FD_SET(int fd, fd_set *set);

int select(int nfds, fd_set *readfds, fd_set *writefds,
           fd_set *exceptfds, struct timeval *timeout);
]]

local fd_set_t = ffi.typeof("fd_set")
local FD_SETSIZE = 8 * ffi.sizeof(fd_set_t)

local function checkSetFd(fd)
    checktype(fd, 1, "number", 3)
    check(fd >= 0 and fd < FD_SETSIZE, "file descriptor value is too large", 3)
end

fd_set_t = class
{
    fd_set_t,

    set = function(self, fd)
        checkSetFd(fd)
        ljposix.ljclang_FD_SET(fd, self)
    end,

    clear = function(self, fd)
        checkSetFd(fd)
        ljposix.ljclang_FD_CLR(fd, self)
    end,

    isSet = function(self, fd)
        checkSetFd(fd)
        return (ljposix.ljclang_FD_ISSET(fd, self) ~= 0)
    end,
}

local SIG = decls.SIG
local SIG_DFL = pollfd_t()  -- just a marker with a unique address

local external_SIG = {
    INT = SIG.INT,
    DFL = SIG_DFL,
}

local api = {
    AF = decls.AF,
    O = decls.O,
    MAP = decls.MAP,
    POLL = decls.POLL,
    PROT = decls.PROT,
    _SC = decls._SC,
    SHUT = decls.SHUT,
    SIG = external_SIG,
    SOCK = decls.SOCK,

    fd_set_t = fd_set_t,
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
    call("sigemptyset", sigset)
    call("sigaddset", sigset, SIG.PIPE)
    call("sigprocmask", SIG.BLOCK, sigset, nil)
end

local uint8_ptr_t = ffi.typeof("uint8_t *")
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

        local bytePtr = ffi.cast(uint8_ptr_t, obj)
        local bytesRead = 0

        repeat
            local remainByteCount = length - bytesRead
            local ret = call("read", self.fd, bytePtr, remainByteCount)
            assert(ret >= 0 and ret <= remainByteCount)
            bytePtr = bytePtr + ret
            bytesRead = bytesRead + ret
        until (allowPartial or bytesRead == length)

        return obj, bytesRead
    end,

    write = function(self, obj)
        check(type(obj) == "string" or type(obj) == "cdata",
              "argument #1 must be a string or cdata", 2)
        local length = (type(obj) == "string") and #obj or ffi.sizeof(obj)
        check(length > 0, "argument must have non-zero length", 2)
        local bytesWritten = call("write", self.fd, obj, length)
        assert(bytesWritten <= length)
        -- TODO: check non-discarding at all usage sites.
        return bytesWritten
    end,

    writeFull = function(self, obj, length)
        check(type(obj) == "cdata",
              "argument #1 must be a cdata", 2)
        check(length == nil or type(length) == "number",
              "argument #2 must be nil or a number", 2)

        local objLength = ffi.sizeof(obj)
        local writeLength = (length ~= nil) and length or objLength

        check(writeLength > 0, "must request to write at least one byte", 2)
        check(writeLength <= objLength, "requested write length greater than object size", 2)

        local bytePtr = ffi.cast(uint8_ptr_t, obj)
        local bytesWritten = 0

        repeat
            local remainByteCount = writeLength - bytesWritten
            local ret = call("write", self.fd, bytePtr, remainByteCount)
            assert(ret >= 0 and ret <= remainByteCount)
            bytePtr = bytePtr + ret
            bytesWritten = bytesWritten + ret
        until (bytesWritten == writeLength)
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

    shutdown = function(self, how)
        local ret = call("shutdown", self.fd, how)
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

local Directory = class{
    "DIR *ptr;",

    read = function(self)
        assert(self.ptr ~= nil)

        ffi.errno(0)
        local dirEnt = C.readdir64(self.ptr)
        if (ffi.errno() ~= 0) then
            error("readdir failed: %s"..getErrnoString())
        end

        return (dirEnt ~= nil) and ffi.string(ljposix.ljclang_getDirent64Name(dirEnt)) or nil
    end
}

api.Dir = function(name)
    checktype(name, 1, "string", 2)

    local dirPtr = C.opendir(name)
    if (dirPtr == nil) then
        error("opendir failed: %s"..getErrnoString())
    end

    return ffi.gc(Directory(dirPtr), function(d)
        C.closedir(d.ptr)
    end)
end

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

api.sysconf = function(name)
    checktype(name, 2, "number", 2)
    local ret = call("sysconf", name)
    assert(ret ~= -1)
    return ret
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

    do
        local MAP, PROT = decls.MAP, decls.PROT
        check(bit.band(prot, bit.bnot(PROT.READ + PROT.WRITE)) == 0,
              "Only PROT.READ and/or PROT.WRITE allowed", 2)
        local allowedFlags = bit.bnot(MAP.SHARED + MAP.PRIVATE + linux_decls.MAP.ANONYMOUS)
        check(bit.band(flags, allowedFlags) == 0,
              "Only MAP.{SHARED,PRIVATE,ANONYMOUS} allowed", 2)
        check(bit.band(flags, linux_decls.MAP.ANONYMOUS) == 0 or fd == -1,
              "argument #5 must be -1 when argument #4 has MAP.ANONYMOUS set", 2)
    end

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
    return (type(v) == "number" or ffi.istype("pid_t", v))
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
