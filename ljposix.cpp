// Support library for POSIX functionality.
// Copyright (C) 2013-2020 Philipp Kutin
// See LICENSE for license information.

#include <string>
#include <type_traits>

#include <ctime>
#include <cstddef>
#include <cstdint>

#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <dirent.h>
#include <poll.h>
#include <signal.h>

namespace
{
    template <typename T> struct TypeString {};

    // NOTE: do not use 'is_same_v', it is absent in Raspbian's libstdc++.
    constexpr bool LongIntIsInt64 = std::is_same<int64_t, long int>::value;
    constexpr bool ULongIsUInt64 = std::is_same<uint64_t, unsigned long>::value;
    struct DummyType1 {};
    struct DummyType2 {};
    using LongInt = std::conditional_t<LongIntIsInt64, DummyType1, long int>;
    using ULong = std::conditional_t<ULongIsUInt64, DummyType2, unsigned long>;

    template <> struct TypeString<int32_t> { static constexpr const char *value = "int32_t"; };
    template <> struct TypeString<int64_t> { static constexpr const char *value = "int64_t"; };
    template <> struct TypeString<uint32_t> { static constexpr const char *value = "uint32_t"; };
    template <> struct TypeString<uint64_t> { static constexpr const char *value = "uint64_t"; };
    template <> struct TypeString<unsigned short> { static constexpr const char *value = "unsigned short"; };

    template <> struct TypeString<LongInt> { static constexpr const char *value = "long int"; };
    template <> struct TypeString<ULong> { static constexpr const char *value = "unsigned long"; };

    template <> struct TypeString<sigset_t> {
        static const std::string structDef;
        static const char *value;
    };

    template <> struct TypeString<fd_set> {
        static const std::string structDef;
        static const char *value;
    };

    const std::string TypeString<sigset_t>::structDef =
        "struct { uint8_t bytes_[" + std::to_string(sizeof(sigset_t)) + "]; } " +
        "__attribute__((aligned(" + std::to_string(alignof(sigset_t)) + ")))";
    const char *TypeString<sigset_t>::value = structDef.c_str();

    // NOTE: LuaJIT does not seem to support endowing a C struct with
    //  __attribute__((aligned(...))) with metamethods. ("Invalid C type".)
    using fd_mask = long int;
    static_assert(alignof(fd_set) == alignof(fd_mask));
    static_assert(sizeof(fd_set) % sizeof(fd_mask) == 0);

    const std::string TypeString<fd_set>::structDef =
        "struct { long int bytes_[" + std::to_string(sizeof(fd_set) / sizeof(fd_mask)) + "]; }";

    const char *TypeString<fd_set>::value = structDef.c_str();
}

#define TypeDef(typeName) \
    std::string{"typedef "} + TypeString<typeName>::value + " " + #typeName + ";"

extern "C" {
const char *ljclang_getTypeDefs()
{
    static const std::string s =
        TypeDef(time_t)
        + TypeDef(blkcnt_t)
        + TypeDef(blksize_t)
        + TypeDef(clock_t)
        + TypeDef(clockid_t)
        + TypeDef(dev_t)
        + TypeDef(fsblkcnt_t)
        + TypeDef(fsfilcnt_t)
        + TypeDef(gid_t)
        + TypeDef(id_t)
        + TypeDef(ino_t)
        + TypeDef(mode_t)
        + TypeDef(nlink_t)
        + TypeDef(off_t)
        + TypeDef(pid_t)
        + TypeDef(ssize_t)
        + TypeDef(suseconds_t)
        + TypeDef(uid_t)
        // poll.h
        + TypeDef(nfds_t)
        // signal.h
        + TypeDef(sigset_t)
        // sys/select.h
        + TypeDef(fd_set)
        // sys/socket.h
        + TypeDef(sa_family_t)
        + TypeDef(socklen_t)
        ;

    return s.c_str();
}

// ---------- fd_set ----------

static_assert(FD_SETSIZE == 8 * sizeof(fd_set));

// TODO: we could also check assumptions here and implement the functions in Lua.

void ljclang_FD_CLR(int fd, fd_set *set) {
    FD_CLR(fd, set);
}

int  ljclang_FD_ISSET(int fd, fd_set *set) {
    return FD_ISSET(fd, set);
}

void ljclang_FD_SET(int fd, fd_set *set) {
    FD_SET(fd, set);
}

// NOTE: we do not expose FD_ZERO().
// We just assume that it is the same as zeroing its bytes.
// See /usr/include/<triple>/bits/select.h

}  // extern "C"

namespace {
namespace Check {

struct timeval {
    time_t sec;
    suseconds_t usec;
};

struct timespec {
    time_t sec;
    long   nsec;
};

struct pollfd {
    int   fd;
    short events;
    short revents;
};

}
}

// Check that on our system, the structs we want to expose include *only* the members
// specified by POSIX.
static_assert(sizeof(Check::timeval) == sizeof(struct timeval));
static_assert(sizeof(Check::timespec) == sizeof(struct timespec));
static_assert(sizeof(Check::pollfd) == sizeof(struct pollfd));

extern "C"
const char *ljclang_getDirent64Name(const struct dirent64 &dirent) {
    return dirent.d_name;
}

extern "C"
void ljclang_setSigintHandlingToDefault()
{
    signal(SIGINT, SIG_DFL);
}
