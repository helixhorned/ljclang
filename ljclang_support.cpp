/* Support library for LJClang, for cases the LuaJIT FFI doesn't handle.
 * (Mostly C callbacks with pass-by-value compound arguments/results.) */

#include <cstdint>
#include <type_traits>
#include <time.h>

#include <clang-c/Index.h>

// Returns the LLVM version obtained with "<llvm-config> --version" when
// building us.
extern "C"
const char *ljclang_getLLVMVersion()
{
    return LJCLANG_LLVM_VERSION;
}

namespace
{
    static_assert(std::is_integral<time_t>::value, "");
    static_assert(sizeof(time_t) == 4 || sizeof(time_t) == 8, "");

    template <typename T> struct TimeType {};

    template <> struct TimeType<int32_t> { static constexpr const char *String = "int32_t"; };
    template <> struct TimeType<int64_t> { static constexpr const char *String = "int64_t"; };
    template <> struct TimeType<uint32_t> { static constexpr const char *String = "uint32_t"; };
    template <> struct TimeType<uint64_t> { static constexpr const char *String = "uint64_t"; };

    constexpr bool LongIntIsInt64 = std::is_same_v<int64_t, long int>;
    struct DummyType {};
    using LongInt = std::conditional_t<LongIntIsInt64, DummyType, long int>;
    template <> struct TimeType<LongInt> { static constexpr const char *String = "long int"; };
}

extern "C"
const char *ljclang_getTimeTypeString()
{
    return TimeType<time_t>::String;
}

/* Our cursor visitor takes the CXCursor objects by pointer. */
using LJCX_CursorVisitor = CXChildVisitResult (*)(
    CXCursor *cursor, CXCursor *parent, CXClientData client_data);

static enum CXChildVisitResult
ourCursorVisitor(CXCursor cursor, CXCursor parent, CXClientData client_data)
{
    LJCX_CursorVisitor *visitor = static_cast<LJCX_CursorVisitor *>(client_data);
    return (*visitor)(&cursor, &parent, nullptr);
}

extern "C"
int ljclang_visitChildrenWith(CXCursor parent, LJCX_CursorVisitor visitor)
{
    const unsigned wasBroken = clang_visitChildren(parent, ourCursorVisitor, &visitor);
    return (wasBroken ? 1 : 0);
}
