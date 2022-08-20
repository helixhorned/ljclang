// Support library for LJClang.
// Copyright (C) 2013-2022 Philipp Kutin
// See LICENSE for license information.

#include <clang-c/Index.h>

// Returns the LLVM version obtained with "<llvm-config> --version" when
// building us.
const char *ljclang_getLLVMVersion()
{
    return LJCLANG_LLVM_VERSION;
}

/* Our cursor visitor takes the CXCursor objects by pointer. */
typedef enum CXChildVisitResult (*LJCX_CursorVisitor)(
    CXCursor *cursor, CXCursor *parent, CXClientData client_data);

static enum CXChildVisitResult
ourCursorVisitor(CXCursor cursor, CXCursor parent, CXClientData client_data)
{
    LJCX_CursorVisitor *visitor = (LJCX_CursorVisitor *)(client_data);
    return (*visitor)(&cursor, &parent, NULL);
}

int ljclang_visitChildrenWith(CXCursor parent, LJCX_CursorVisitor visitor)
{
    const unsigned wasBroken = clang_visitChildren(parent, ourCursorVisitor, &visitor);
    return (wasBroken ? 1 : 0);
}
