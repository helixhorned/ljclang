/* Support library for LJClang, for cases the LuaJIT FFI doesn't handle.
 * (Mostly C callbacks with pass-by-value compound arguments/results.) */

#include <stdlib.h>
#include <string.h>

#include <clang-c/Index.h>


/* Our cursor visitor takes the CXCursor objects by pointer. */
typedef enum CXChildVisitResult (*LJCX_CursorVisitor)(
    CXCursor *cursor, CXCursor *parent, CXClientData client_data);

/* Compile with cursor kinds bitmap? This was originally intended as
 * 'optimization' (because C callback are said to be slow in LuaJIT), but maybe
 * it was premature optimization... they're still pretty fast. */
/*#define USE_KINDS_BITAR*/

#define UNUSED(var) (void)(var);

/* NOTE: Make sure that the 'last' CXCursor kind LAST_KIND is the numerically
 * greatest. */
#define LAST_KIND CXCursor_LastExtraDecl
#define NUM_KINDS (LAST_KIND+1)
#define KINDS_BITAR_SIZE ((NUM_KINDS+7)>>3)

typedef struct {
    LJCX_CursorVisitor visitor;
#ifdef USE_KINDS_BITAR
    unsigned char kinds[KINDS_BITAR_SIZE];
#endif
} LJCX_CursorVisitorData;

static LJCX_CursorVisitorData *g_cursorVisitors;
static unsigned g_numVisitors;


/* Registers a LJClang_CursorVisitor callback <visitor> and returns an index by
 * which it can be subsequently referenced.
 *
 * <kinds>: An array containing CXCursorKind values. If <kinds> contains a
 * particular cursor kind, <visitor> is invoked on such a cursor.
 * NOTE: Only effective if compiled with #define USE_KINDS_BITAR.
 *
 * <numkinds>: The number of elements in <kinds>. In the special case of being
 * 0, all cursor kinds are considered to be visited and <kinds> is not
 * accessed.
 *
 * Returns:
 * >=0: the visitor function index on success.
 *  -1: failed realloc().
 *  -2: <kinds> contains an invalid CXCursorKind
 */
int ljclang_regCursorVisitor(LJCX_CursorVisitor visitor, enum CXCursorKind *kinds, int numkinds)
{
#ifdef USE_KINDS_BITAR
    int i;
#endif
    const int szCVD = (int)sizeof(LJCX_CursorVisitorData);
    LJCX_CursorVisitorData cvd;

    memset(&cvd, 0, szCVD);
    cvd.visitor = visitor;

#ifdef USE_KINDS_BITAR
    if (numkinds == 0)
        memset(cvd.kinds, 255, sizeof(cvd.kinds));

    for (i=0; i<numkinds; i++)
    {
        if ((unsigned)numkinds >= NUM_KINDS)
            return -2;

        cvd.kinds[i>>3] |= 1<<(i&7);
    }
#else
    UNUSED(kinds);
    UNUSED(numkinds);
#endif

    {
        /* Finally, reallocate g_cursorVisitors. */
        void *newVisitors = realloc(g_cursorVisitors, (g_numVisitors+1)*szCVD);

        if (newVisitors == NULL)
            return -1;

        g_cursorVisitors = (LJCX_CursorVisitorData *)newVisitors;
        memcpy(&g_cursorVisitors[g_numVisitors], &cvd, szCVD);

        return g_numVisitors++;
    }
}

static enum CXChildVisitResult
ourCursorVisitor(CXCursor cursor, CXCursor parent, CXClientData client_data)
{
    LJCX_CursorVisitorData *cvd = (LJCX_CursorVisitorData *)client_data;

    int k = cursor.kind;

    if ((unsigned)k >= NUM_KINDS)
        return CXChildVisit_Break;
#ifdef USE_KINDS_BITAR
    if (cvd->kinds[k>>3] & (1<<(k&7)))
#endif
        return cvd->visitor(&cursor, &parent, NULL);

    return CXChildVisit_Continue;
}

int ljclang_visitChildren(CXCursor parent, int visitoridx)
{
    unsigned wasbroken;

    if ((unsigned)visitoridx >= g_numVisitors)
        return -1;

    wasbroken = clang_visitChildren(parent, ourCursorVisitor,
                                    (CXClientData)&g_cursorVisitors[visitoridx]);
    return (wasbroken ? 1 : 0);
}
