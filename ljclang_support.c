/* Support library for LJClang, for cases the LuaJIT FFI doesn't handle.
 * (Mostly C callbacks with pass-by-value compound arguments/results.) */

#include <stdlib.h>
#include <string.h>

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

typedef struct {
    LJCX_CursorVisitor visitor;
} LJCX_CursorVisitorData;

static LJCX_CursorVisitorData *g_cursorVisitors;
static unsigned g_numVisitors;


/* Registers a LJClang_CursorVisitor callback <visitor> and returns an index by
 * which it can be subsequently referenced.
 *
 * Returns:
 * >=0: the visitor function index on success.
 *  -1: failed realloc().
 */
int ljclang_regCursorVisitor(LJCX_CursorVisitor visitor)
{
    const int szCVD = (int)sizeof(LJCX_CursorVisitorData);
    LJCX_CursorVisitorData cvd;

    memset(&cvd, 0, szCVD);
    cvd.visitor = visitor;

    void *newVisitors = realloc(g_cursorVisitors, (g_numVisitors+1)*szCVD);

    if (newVisitors == NULL)
        return -1;

    g_cursorVisitors = (LJCX_CursorVisitorData *)newVisitors;
    memcpy(&g_cursorVisitors[g_numVisitors], &cvd, szCVD);

    return g_numVisitors++;
}

static enum CXChildVisitResult
ourCursorVisitor(CXCursor cursor, CXCursor parent, CXClientData client_data)
{
    LJCX_CursorVisitorData *cvd = (LJCX_CursorVisitorData *)client_data;
    return cvd->visitor(&cursor, &parent, NULL);
}

int ljclang_visitChildren(CXCursor parent, int visitoridx)
{
    if ((unsigned)visitoridx >= g_numVisitors)
        return -1;

    const unsigned wasBroken = clang_visitChildren(
        parent, ourCursorVisitor, (CXClientData)&g_cursorVisitors[visitoridx]);

    return (wasBroken ? 1 : 0);
}
