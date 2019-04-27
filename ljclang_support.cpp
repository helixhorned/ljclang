// Support library for LJClang.
// Copyright (C) 2013-2019 Philipp Kutin
// See LICENSE for license information.

#define LJCLANG_USE_POSIX 1

#if LJCLANG_USE_POSIX
# include <sys/types.h>
# include <poll.h>
# include <signal.h>
#endif

#include <cstddef>
#include <cstdint>
#include <ctime>

#include <string>
#include <thread>
#include <type_traits>

#include <clang-c/Index.h>

// Returns the LLVM version obtained with "<llvm-config> --version" when
// building us.
extern "C"
{
const char *ljclang_getLLVMVersion()
{
    return LJCLANG_LLVM_VERSION;
}

unsigned ljclang_getHardwareConcurrency()
{
    return std::thread::hardware_concurrency();
}
}

namespace
{
    template <typename T> struct TypeString {};

    template <> struct TypeString<int32_t> { static constexpr const char *value = "int32_t"; };
    template <> struct TypeString<int64_t> { static constexpr const char *value = "int64_t"; };
    template <> struct TypeString<uint32_t> { static constexpr const char *value = "uint32_t"; };
    template <> struct TypeString<uint64_t> { static constexpr const char *value = "uint64_t"; };

    constexpr bool LongIntIsInt64 = std::is_same_v<int64_t, long int>;
    struct DummyType {};
    using LongInt = std::conditional_t<LongIntIsInt64, DummyType, long int>;
    template <> struct TypeString<LongInt> { static constexpr const char *value = "long int"; };
}

#define TypeDef(typeName) \
    std::string{"typedef "} + TypeString<time_t>::value + " " + #typeName + ";"

extern "C"
const char *ljclang_getTypeDefs()
{
    static const std::string s =
        TypeDef(time_t)
#if LJCLANG_USE_POSIX
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
        + TypeDef(timer_t)
        + TypeDef(uid_t)
        // poll.h
        + TypeDef(nfds_t)
        // signal.h
        + TypeDef(sigset_t)
#endif
        ;

    return s.c_str();
}

/* Our cursor visitor takes the CXCursor objects by pointer. */
using LJCX_CursorVisitor = CXChildVisitResult (*)(
    CXCursor *cursor, CXCursor *parent, CXClientData client_data);

static enum CXChildVisitResult
ourCursorVisitor(CXCursor cursor, CXCursor parent, CXClientData client_data)
{
    auto *visitor = static_cast<LJCX_CursorVisitor *>(client_data);
    return (*visitor)(&cursor, &parent, nullptr);
}

extern "C"
int ljclang_visitChildrenWith(CXCursor parent, LJCX_CursorVisitor visitor)
{
    const unsigned wasBroken = clang_visitChildren(parent, ourCursorVisitor, &visitor);
    return (wasBroken ? 1 : 0);
}
