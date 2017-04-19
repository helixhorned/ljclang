/* Support library for LJClang, for cases the LuaJIT FFI doesn't handle.
 * (Mostly C callbacks with pass-by-value compound arguments/results.) */

#include <cstdint>
#include <cstdlib>

#include <vector>
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
}

extern "C"
const char *ljclang_getTimeTypeString()
{
    return TimeType<time_t>::String;
}

/* Our cursor visitor takes the CXCursor objects by pointer. */
using LJCX_CursorVisitor = CXChildVisitResult (*)(
    CXCursor *cursor, CXCursor *parent, CXClientData client_data);

struct LJCX_CursorVisitorData
{
    LJCX_CursorVisitorData(LJCX_CursorVisitor v) : visitor(v) {}

    LJCX_CursorVisitor visitor;
};

static std::vector<LJCX_CursorVisitorData> CursorVisitors;


/* Registers a LJClang_CursorVisitor callback <visitor> and returns an index by
 * which it can be subsequently referenced.
 *
 * Returns:
 * >=0: the visitor function index on success.
 *  -1: failed realloc().
 */
extern "C"
int ljclang_regCursorVisitor(LJCX_CursorVisitor visitor)
{
    const size_t idx = CursorVisitors.size();
    CursorVisitors.emplace_back(visitor);
    return idx;
}

static enum CXChildVisitResult
ourCursorVisitor(CXCursor cursor, CXCursor parent, CXClientData client_data)
{
    LJCX_CursorVisitorData *cvd = static_cast<LJCX_CursorVisitorData *>(client_data);
    return cvd->visitor(&cursor, &parent, nullptr);
}

extern "C"
int ljclang_visitChildren(CXCursor parent, int visitoridx)
{
    if (static_cast<unsigned>(visitoridx) >= CursorVisitors.size())
        return -1;

    const unsigned wasBroken = clang_visitChildren(
        parent, ourCursorVisitor, CursorVisitors.data() + visitoridx);

    return (wasBroken ? 1 : 0);
}
