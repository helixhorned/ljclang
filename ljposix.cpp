// Support library for POSIX functionality.
// Copyright (C) 2013-2019 Philipp Kutin
// See LICENSE for license information.

#include <string>
#include <type_traits>

#include <ctime>
#include <cstddef>
#include <cstdint>

#include <sys/types.h>
#include <poll.h>
#include <signal.h>

namespace
{
    template <typename T> struct TypeString {};

    template <> struct TypeString<int32_t> { static constexpr const char *value = "int32_t"; };
    template <> struct TypeString<int64_t> { static constexpr const char *value = "int64_t"; };
    template <> struct TypeString<uint32_t> { static constexpr const char *value = "uint32_t"; };
    template <> struct TypeString<uint64_t> { static constexpr const char *value = "uint64_t"; };
    template <> struct TypeString<unsigned long> { static constexpr const char *value = "unsigned long"; };

    // NOTE: do not use 'is_same_v', it is absent in Raspbian's libstdc++.
    constexpr bool LongIntIsInt64 = std::is_same<int64_t, long int>::value;
    struct DummyType {};
    using LongInt = std::conditional_t<LongIntIsInt64, DummyType, long int>;
    template <> struct TypeString<LongInt> { static constexpr const char *value = "long int"; };

    template <> struct TypeString<sigset_t> {
        static const std::string structDef;
        static const char *value;
    };

    const std::string TypeString<sigset_t>::structDef =
        "struct { uint8_t bytes_[" + std::to_string(sizeof(sigset_t)) + "]; } " +
        "__attribute__((aligned(" + std::to_string(alignof(sigset_t)) + ")))";
    const char *TypeString<sigset_t>::value = structDef.c_str();
}

#define TypeDef(typeName) \
    std::string{"typedef "} + TypeString<typeName>::value + " " + #typeName + ";"

extern "C"
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
        ;

    return s.c_str();
}

// Check that the 'struct pollfd' on our system (which we want to expose) includes *only*
// the three members specified by POSIX.
static_assert(sizeof(pollfd) == sizeof(int) + 2 * sizeof(short));

extern "C"
void ljclang_setSigintHandlingToDefault()
{
    signal(SIGINT, SIG_DFL);
}
