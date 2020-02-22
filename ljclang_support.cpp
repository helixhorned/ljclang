// Support library for LJClang.
// Copyright (C) 2013-2020 Philipp Kutin
// See LICENSE for license information.

#include <thread>

#include <clang-c/Index.h>

extern "C"
{
// Returns the LLVM version obtained with "<llvm-config> --version" when
// building us.
const char *ljclang_getLLVMVersion()
{
    return LJCLANG_LLVM_VERSION;
}

unsigned ljclang_getHardwareConcurrency()
{
    return std::thread::hardware_concurrency();
}
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
