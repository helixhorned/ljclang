require('ffi').cdef[==========[
	/*===-- clang-c/CXString.h - C Index strings  --------------------*- C -*-===*\
|*                                                                            *|
|* Part of the LLVM Project, under the Apache License v2.0 with LLVM          *|
|* Exceptions.                                                                *|
|* See https://llvm.org/LICENSE.txt for license information.                  *|
|* SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception                    *|
|*                                                                            *|
|*===----------------------------------------------------------------------===*|
|*                                                                            *|
|* This header provides the interface to C Index strings.                     *|
|*                                                                            *|
\*===----------------------------------------------------------------------===*/
typedef struct {
  const void *data;
  unsigned private_flags;
} CXString;
typedef struct {
  CXString *Strings;
  unsigned Count;
} CXStringSet;
 const char *clang_getCString(CXString string);
 void clang_disposeString(CXString string);
 void clang_disposeStringSet(CXStringSet *set);
	/*===-- clang-c/CXCompilationDatabase.h - Compilation database  ---*- C -*-===*\
|*                                                                            *|
|* Part of the LLVM Project, under the Apache License v2.0 with LLVM          *|
|* Exceptions.                                                                *|
|* See https://llvm.org/LICENSE.txt for license information.                  *|
|* SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception                    *|
|*                                                                            *|
|*===----------------------------------------------------------------------===*|
|*                                                                            *|
|* This header provides a public interface to use CompilationDatabase without *|
|* the full Clang C++ API.                                                    *|
|*                                                                            *|
\*===----------------------------------------------------------------------===*/
typedef void * CXCompilationDatabase;
typedef void * CXCompileCommands;
typedef void * CXCompileCommand;
typedef enum  {
  /*
   * No error occurred
   */
  CXCompilationDatabase_NoError = 0,
  /*
   * Database can not be loaded
   */
  CXCompilationDatabase_CanNotLoadDatabase = 1
} CXCompilationDatabase_Error;
 CXCompilationDatabase
clang_CompilationDatabase_fromDirectory(const char *BuildDir,
                                        CXCompilationDatabase_Error *ErrorCode);
 void
clang_CompilationDatabase_dispose(CXCompilationDatabase);
 CXCompileCommands
clang_CompilationDatabase_getCompileCommands(CXCompilationDatabase,
                                             const char *CompleteFileName);
 CXCompileCommands
clang_CompilationDatabase_getAllCompileCommands(CXCompilationDatabase);
 void clang_CompileCommands_dispose(CXCompileCommands);
 unsigned
clang_CompileCommands_getSize(CXCompileCommands);
 CXCompileCommand
clang_CompileCommands_getCommand(CXCompileCommands, unsigned I);
 CXString
clang_CompileCommand_getDirectory(CXCompileCommand);
 CXString
clang_CompileCommand_getFilename(CXCompileCommand);
 unsigned
clang_CompileCommand_getNumArgs(CXCompileCommand);
 CXString
clang_CompileCommand_getArg(CXCompileCommand, unsigned I);
 unsigned
clang_CompileCommand_getNumMappedSources(CXCompileCommand);
 CXString
clang_CompileCommand_getMappedSourcePath(CXCompileCommand, unsigned I);
 CXString
clang_CompileCommand_getMappedSourceContent(CXCompileCommand, unsigned I);
	/*===-- clang-c/CXErrorCode.h - C Index Error Codes  --------------*- C -*-===*\
|*                                                                            *|
|* Part of the LLVM Project, under the Apache License v2.0 with LLVM          *|
|* Exceptions.                                                                *|
|* See https://llvm.org/LICENSE.txt for license information.                  *|
|* SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception                    *|
|*                                                                            *|
|*===----------------------------------------------------------------------===*|
|*                                                                            *|
|* This header provides the CXErrorCode enumerators.                          *|
|*                                                                            *|
\*===----------------------------------------------------------------------===*/
enum CXErrorCode {

  CXError_Success = 0,

  CXError_Failure = 1,

  CXError_Crashed = 2,

  CXError_InvalidArguments = 3,

  CXError_ASTReadError = 4
};
	/*===-- clang-c/Index.h - Indexing Public C Interface -------------*- C -*-===*\
|*                                                                            *|
|* Part of the LLVM Project, under the Apache License v2.0 with LLVM          *|
|* Exceptions.                                                                *|
|* See https://llvm.org/LICENSE.txt for license information.                  *|
|* SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception                    *|
|*                                                                            *|
|*===----------------------------------------------------------------------===*|
|*                                                                            *|
|* This header provides a public interface to a Clang library for extracting  *|
|* high-level symbol information from source files without exposing the full  *|
|* Clang C++ API.                                                             *|
|*                                                                            *|
\*===----------------------------------------------------------------------===*/
typedef void *CXIndex;
typedef struct CXTargetInfoImpl *CXTargetInfo;
typedef struct CXTranslationUnitImpl *CXTranslationUnit;
typedef void *CXClientData;
struct CXUnsavedFile {

  const char *Filename;

  const char *Contents;

  unsigned long Length;
};
enum CXAvailabilityKind {

  CXAvailability_Available,

  CXAvailability_Deprecated,

  CXAvailability_NotAvailable,

  CXAvailability_NotAccessible
};
typedef struct CXVersion {

  int Major;

  int Minor;

  int Subminor;
} CXVersion;
enum CXCursor_ExceptionSpecificationKind {

  CXCursor_ExceptionSpecificationKind_None,

  CXCursor_ExceptionSpecificationKind_DynamicNone,

  CXCursor_ExceptionSpecificationKind_Dynamic,

  CXCursor_ExceptionSpecificationKind_MSAny,

  CXCursor_ExceptionSpecificationKind_BasicNoexcept,

  CXCursor_ExceptionSpecificationKind_ComputedNoexcept,

  CXCursor_ExceptionSpecificationKind_Unevaluated,

  CXCursor_ExceptionSpecificationKind_Uninstantiated,

  CXCursor_ExceptionSpecificationKind_Unparsed,

  CXCursor_ExceptionSpecificationKind_NoThrow
};
 CXIndex clang_createIndex(int excludeDeclarationsFromPCH,
                                         int displayDiagnostics);
 void clang_disposeIndex(CXIndex index);
typedef enum {

  CXGlobalOpt_None = 0x0,

  CXGlobalOpt_ThreadBackgroundPriorityForIndexing = 0x1,

  CXGlobalOpt_ThreadBackgroundPriorityForEditing = 0x2,

  CXGlobalOpt_ThreadBackgroundPriorityForAll =
      CXGlobalOpt_ThreadBackgroundPriorityForIndexing |
      CXGlobalOpt_ThreadBackgroundPriorityForEditing
} CXGlobalOptFlags;
 void clang_CXIndex_setGlobalOptions(CXIndex, unsigned options);
 unsigned clang_CXIndex_getGlobalOptions(CXIndex);
 void
clang_CXIndex_setInvocationEmissionPathOption(CXIndex, const char *Path);
typedef void *CXFile;
 CXString clang_getFileName(CXFile SFile);
 // REMOVED: clang_getFileTime
typedef struct {
  unsigned long long data[3];
} CXFileUniqueID;
 int clang_getFileUniqueID(CXFile file, CXFileUniqueID *outID);
 unsigned
clang_isFileMultipleIncludeGuarded(CXTranslationUnit tu, CXFile file);
 CXFile clang_getFile(CXTranslationUnit tu,
                                    const char *file_name);
 const char *clang_getFileContents(CXTranslationUnit tu,
                                                 CXFile file, size_t *size);
 int clang_File_isEqual(CXFile file1, CXFile file2);
 CXString clang_File_tryGetRealPathName(CXFile file);
typedef struct {
  const void *ptr_data[2];
  unsigned int_data;
} CXSourceLocation;
typedef struct {
  const void *ptr_data[2];
  unsigned begin_int_data;
  unsigned end_int_data;
} CXSourceRange;
 CXSourceLocation clang_getNullLocation(void);
 unsigned clang_equalLocations(CXSourceLocation loc1,
                                             CXSourceLocation loc2);
 CXSourceLocation clang_getLocation(CXTranslationUnit tu,
                                                  CXFile file,
                                                  unsigned line,
                                                  unsigned column);
 CXSourceLocation clang_getLocationForOffset(CXTranslationUnit tu,
                                                           CXFile file,
                                                           unsigned offset);
 int clang_Location_isInSystemHeader(CXSourceLocation location);
 int clang_Location_isFromMainFile(CXSourceLocation location);
 CXSourceRange clang_getNullRange(void);
 CXSourceRange clang_getRange(CXSourceLocation begin,
                                            CXSourceLocation end);
 unsigned clang_equalRanges(CXSourceRange range1,
                                          CXSourceRange range2);
 int clang_Range_isNull(CXSourceRange range);
 void clang_getExpansionLocation(CXSourceLocation location,
                                               CXFile *file,
                                               unsigned *line,
                                               unsigned *column,
                                               unsigned *offset);
 void clang_getPresumedLocation(CXSourceLocation location,
                                              CXString *filename,
                                              unsigned *line,
                                              unsigned *column);
 void clang_getInstantiationLocation(CXSourceLocation location,
                                                   CXFile *file,
                                                   unsigned *line,
                                                   unsigned *column,
                                                   unsigned *offset);
 void clang_getSpellingLocation(CXSourceLocation location,
                                              CXFile *file,
                                              unsigned *line,
                                              unsigned *column,
                                              unsigned *offset);
 void clang_getFileLocation(CXSourceLocation location,
                                          CXFile *file,
                                          unsigned *line,
                                          unsigned *column,
                                          unsigned *offset);
 CXSourceLocation clang_getRangeStart(CXSourceRange range);
 CXSourceLocation clang_getRangeEnd(CXSourceRange range);
typedef struct {

  unsigned count;

  CXSourceRange *ranges;
} CXSourceRangeList;
 CXSourceRangeList *clang_getSkippedRanges(CXTranslationUnit tu,
                                                         CXFile file);
 CXSourceRangeList *clang_getAllSkippedRanges(CXTranslationUnit tu);
 void clang_disposeSourceRangeList(CXSourceRangeList *ranges);
enum CXDiagnosticSeverity {

  CXDiagnostic_Ignored = 0,

  CXDiagnostic_Note    = 1,

  CXDiagnostic_Warning = 2,

  CXDiagnostic_Error   = 3,

  CXDiagnostic_Fatal   = 4
};
typedef void *CXDiagnostic;
typedef void *CXDiagnosticSet;
 unsigned clang_getNumDiagnosticsInSet(CXDiagnosticSet Diags);
 CXDiagnostic clang_getDiagnosticInSet(CXDiagnosticSet Diags,
                                                     unsigned Index);
enum CXLoadDiag_Error {

  CXLoadDiag_None = 0,

  CXLoadDiag_Unknown = 1,

  CXLoadDiag_CannotLoad = 2,

  CXLoadDiag_InvalidFile = 3
};
 CXDiagnosticSet clang_loadDiagnostics(const char *file,
                                                  enum CXLoadDiag_Error *error,
                                                  CXString *errorString);
 void clang_disposeDiagnosticSet(CXDiagnosticSet Diags);
 CXDiagnosticSet clang_getChildDiagnostics(CXDiagnostic D);
 unsigned clang_getNumDiagnostics(CXTranslationUnit Unit);
 CXDiagnostic clang_getDiagnostic(CXTranslationUnit Unit,
                                                unsigned Index);
 CXDiagnosticSet
  clang_getDiagnosticSetFromTU(CXTranslationUnit Unit);
 void clang_disposeDiagnostic(CXDiagnostic Diagnostic);
enum CXDiagnosticDisplayOptions {

  CXDiagnostic_DisplaySourceLocation = 0x01,

  CXDiagnostic_DisplayColumn = 0x02,

  CXDiagnostic_DisplaySourceRanges = 0x04,

  CXDiagnostic_DisplayOption = 0x08,

  CXDiagnostic_DisplayCategoryId = 0x10,

  CXDiagnostic_DisplayCategoryName = 0x20
};
 CXString clang_formatDiagnostic(CXDiagnostic Diagnostic,
                                               unsigned Options);
 unsigned clang_defaultDiagnosticDisplayOptions(void);
 enum CXDiagnosticSeverity
clang_getDiagnosticSeverity(CXDiagnostic);
 CXSourceLocation clang_getDiagnosticLocation(CXDiagnostic);
 CXString clang_getDiagnosticSpelling(CXDiagnostic);
 CXString clang_getDiagnosticOption(CXDiagnostic Diag,
                                                  CXString *Disable);
 unsigned clang_getDiagnosticCategory(CXDiagnostic);

CXString clang_getDiagnosticCategoryName(unsigned Category);
 CXString clang_getDiagnosticCategoryText(CXDiagnostic);
 unsigned clang_getDiagnosticNumRanges(CXDiagnostic);
 CXSourceRange clang_getDiagnosticRange(CXDiagnostic Diagnostic,
                                                      unsigned Range);
 unsigned clang_getDiagnosticNumFixIts(CXDiagnostic Diagnostic);
 CXString clang_getDiagnosticFixIt(CXDiagnostic Diagnostic,
                                                 unsigned FixIt,
                                               CXSourceRange *ReplacementRange);
 CXString
clang_getTranslationUnitSpelling(CXTranslationUnit CTUnit);
 CXTranslationUnit clang_createTranslationUnitFromSourceFile(
                                         CXIndex CIdx,
                                         const char *source_filename,
                                         int num_clang_command_line_args,
                                   const char * const *clang_command_line_args,
                                         unsigned num_unsaved_files,
                                         struct CXUnsavedFile *unsaved_files);
 CXTranslationUnit clang_createTranslationUnit(
    CXIndex CIdx,
    const char *ast_filename);
 enum CXErrorCode clang_createTranslationUnit2(
    CXIndex CIdx,
    const char *ast_filename,
    CXTranslationUnit *out_TU);
enum CXTranslationUnit_Flags {

  CXTranslationUnit_None = 0x0,

  CXTranslationUnit_DetailedPreprocessingRecord = 0x01,

  CXTranslationUnit_Incomplete = 0x02,

  CXTranslationUnit_PrecompiledPreamble = 0x04,

  CXTranslationUnit_CacheCompletionResults = 0x08,

  CXTranslationUnit_ForSerialization = 0x10,

  CXTranslationUnit_CXXChainedPCH = 0x20,

  CXTranslationUnit_SkipFunctionBodies = 0x40,

  CXTranslationUnit_IncludeBriefCommentsInCodeCompletion = 0x80,

  CXTranslationUnit_CreatePreambleOnFirstParse = 0x100,

  CXTranslationUnit_KeepGoing = 0x200,

  CXTranslationUnit_SingleFileParse = 0x400,

  CXTranslationUnit_LimitSkipFunctionBodiesToPreamble = 0x800,

  CXTranslationUnit_IncludeAttributedTypes = 0x1000,

  CXTranslationUnit_VisitImplicitAttributes = 0x2000,

  CXTranslationUnit_IgnoreNonErrorsFromIncludedFiles = 0x4000,

  CXTranslationUnit_RetainExcludedConditionalBlocks = 0x8000
};
 unsigned clang_defaultEditingTranslationUnitOptions(void);
 CXTranslationUnit
clang_parseTranslationUnit(CXIndex CIdx,
                           const char *source_filename,
                           const char *const *command_line_args,
                           int num_command_line_args,
                           struct CXUnsavedFile *unsaved_files,
                           unsigned num_unsaved_files,
                           unsigned options);
 enum CXErrorCode
clang_parseTranslationUnit2(CXIndex CIdx,
                            const char *source_filename,
                            const char *const *command_line_args,
                            int num_command_line_args,
                            struct CXUnsavedFile *unsaved_files,
                            unsigned num_unsaved_files,
                            unsigned options,
                            CXTranslationUnit *out_TU);
 enum CXErrorCode clang_parseTranslationUnit2FullArgv(
    CXIndex CIdx, const char *source_filename,
    const char *const *command_line_args, int num_command_line_args,
    struct CXUnsavedFile *unsaved_files, unsigned num_unsaved_files,
    unsigned options, CXTranslationUnit *out_TU);
enum CXSaveTranslationUnit_Flags {

  CXSaveTranslationUnit_None = 0x0
};
 unsigned clang_defaultSaveOptions(CXTranslationUnit TU);
enum CXSaveError {

  CXSaveError_None = 0,

  CXSaveError_Unknown = 1,

  CXSaveError_TranslationErrors = 2,

  CXSaveError_InvalidTU = 3
};
 int clang_saveTranslationUnit(CXTranslationUnit TU,
                                             const char *FileName,
                                             unsigned options);
 unsigned clang_suspendTranslationUnit(CXTranslationUnit);
 void clang_disposeTranslationUnit(CXTranslationUnit);
enum CXReparse_Flags {

  CXReparse_None = 0x0
};
 unsigned clang_defaultReparseOptions(CXTranslationUnit TU);
 int clang_reparseTranslationUnit(CXTranslationUnit TU,
                                                unsigned num_unsaved_files,
                                          struct CXUnsavedFile *unsaved_files,
                                                unsigned options);
enum CXTUResourceUsageKind {
  CXTUResourceUsage_AST = 1,
  CXTUResourceUsage_Identifiers = 2,
  CXTUResourceUsage_Selectors = 3,
  CXTUResourceUsage_GlobalCompletionResults = 4,
  CXTUResourceUsage_SourceManagerContentCache = 5,
  CXTUResourceUsage_AST_SideTables = 6,
  CXTUResourceUsage_SourceManager_Membuffer_Malloc = 7,
  CXTUResourceUsage_SourceManager_Membuffer_MMap = 8,
  CXTUResourceUsage_ExternalASTSource_Membuffer_Malloc = 9,
  CXTUResourceUsage_ExternalASTSource_Membuffer_MMap = 10,
  CXTUResourceUsage_Preprocessor = 11,
  CXTUResourceUsage_PreprocessingRecord = 12,
  CXTUResourceUsage_SourceManager_DataStructures = 13,
  CXTUResourceUsage_Preprocessor_HeaderSearch = 14,
  CXTUResourceUsage_MEMORY_IN_BYTES_BEGIN = CXTUResourceUsage_AST,
  CXTUResourceUsage_MEMORY_IN_BYTES_END =
    CXTUResourceUsage_Preprocessor_HeaderSearch,
  CXTUResourceUsage_First = CXTUResourceUsage_AST,
  CXTUResourceUsage_Last = CXTUResourceUsage_Preprocessor_HeaderSearch
};
const char *clang_getTUResourceUsageName(enum CXTUResourceUsageKind kind);
typedef struct CXTUResourceUsageEntry {
  /* The memory usage category. */
  enum CXTUResourceUsageKind kind;
  /* Amount of resources used.
      The units will depend on the resource kind. */
  unsigned long amount;
} CXTUResourceUsageEntry;
typedef struct CXTUResourceUsage {
  /* Private data member, used for queries. */
  void *data;
  /* The number of entries in the 'entries' array. */
  unsigned numEntries;
  /* An array of key-value pairs, representing the breakdown of memory
            usage. */
  CXTUResourceUsageEntry *entries;
} CXTUResourceUsage;
 CXTUResourceUsage clang_getCXTUResourceUsage(CXTranslationUnit TU);
 void clang_disposeCXTUResourceUsage(CXTUResourceUsage usage);
 CXTargetInfo
clang_getTranslationUnitTargetInfo(CXTranslationUnit CTUnit);
 void
clang_TargetInfo_dispose(CXTargetInfo Info);
 CXString
clang_TargetInfo_getTriple(CXTargetInfo Info);
 int
clang_TargetInfo_getPointerWidth(CXTargetInfo Info);
enum CXCursorKind {
  /* Declarations */

  CXCursor_UnexposedDecl                 = 1,

  CXCursor_StructDecl                    = 2,

  CXCursor_UnionDecl                     = 3,

  CXCursor_ClassDecl                     = 4,

  CXCursor_EnumDecl                      = 5,

  CXCursor_FieldDecl                     = 6,

  CXCursor_EnumConstantDecl              = 7,

  CXCursor_FunctionDecl                  = 8,

  CXCursor_VarDecl                       = 9,

  CXCursor_ParmDecl                      = 10,

  CXCursor_ObjCInterfaceDecl             = 11,

  CXCursor_ObjCCategoryDecl              = 12,

  CXCursor_ObjCProtocolDecl              = 13,

  CXCursor_ObjCPropertyDecl              = 14,

  CXCursor_ObjCIvarDecl                  = 15,

  CXCursor_ObjCInstanceMethodDecl        = 16,

  CXCursor_ObjCClassMethodDecl           = 17,

  CXCursor_ObjCImplementationDecl        = 18,

  CXCursor_ObjCCategoryImplDecl          = 19,

  CXCursor_TypedefDecl                   = 20,

  CXCursor_CXXMethod                     = 21,

  CXCursor_Namespace                     = 22,

  CXCursor_LinkageSpec                   = 23,

  CXCursor_Constructor                   = 24,

  CXCursor_Destructor                    = 25,

  CXCursor_ConversionFunction            = 26,

  CXCursor_TemplateTypeParameter         = 27,

  CXCursor_NonTypeTemplateParameter      = 28,

  CXCursor_TemplateTemplateParameter     = 29,

  CXCursor_FunctionTemplate              = 30,

  CXCursor_ClassTemplate                 = 31,

  CXCursor_ClassTemplatePartialSpecialization = 32,

  CXCursor_NamespaceAlias                = 33,

  CXCursor_UsingDirective                = 34,

  CXCursor_UsingDeclaration              = 35,

  CXCursor_TypeAliasDecl                 = 36,

  CXCursor_ObjCSynthesizeDecl            = 37,

  CXCursor_ObjCDynamicDecl               = 38,

  CXCursor_CXXAccessSpecifier            = 39,
  CXCursor_FirstDecl                     = CXCursor_UnexposedDecl,
  CXCursor_LastDecl                      = CXCursor_CXXAccessSpecifier,
  /* References */
  CXCursor_FirstRef                      = 40, /* Decl references */
  CXCursor_ObjCSuperClassRef             = 40,
  CXCursor_ObjCProtocolRef               = 41,
  CXCursor_ObjCClassRef                  = 42,

  CXCursor_TypeRef                       = 43,
  CXCursor_CXXBaseSpecifier              = 44,

  CXCursor_TemplateRef                   = 45,

  CXCursor_NamespaceRef                  = 46,

  CXCursor_MemberRef                     = 47,

  CXCursor_LabelRef                      = 48,

  CXCursor_OverloadedDeclRef             = 49,

  CXCursor_VariableRef                   = 50,
  CXCursor_LastRef                       = CXCursor_VariableRef,
  /* Error conditions */
  CXCursor_FirstInvalid                  = 70,
  CXCursor_InvalidFile                   = 70,
  CXCursor_NoDeclFound                   = 71,
  CXCursor_NotImplemented                = 72,
  CXCursor_InvalidCode                   = 73,
  CXCursor_LastInvalid                   = CXCursor_InvalidCode,
  /* Expressions */
  CXCursor_FirstExpr                     = 100,

  CXCursor_UnexposedExpr                 = 100,

  CXCursor_DeclRefExpr                   = 101,

  CXCursor_MemberRefExpr                 = 102,

  CXCursor_CallExpr                      = 103,

  CXCursor_ObjCMessageExpr               = 104,

  CXCursor_BlockExpr                     = 105,

  CXCursor_IntegerLiteral                = 106,

  CXCursor_FloatingLiteral               = 107,

  CXCursor_ImaginaryLiteral              = 108,

  CXCursor_StringLiteral                 = 109,

  CXCursor_CharacterLiteral              = 110,

  CXCursor_ParenExpr                     = 111,

  CXCursor_UnaryOperator                 = 112,

  CXCursor_ArraySubscriptExpr            = 113,

  CXCursor_BinaryOperator                = 114,

  CXCursor_CompoundAssignOperator        = 115,

  CXCursor_ConditionalOperator           = 116,

  CXCursor_CStyleCastExpr                = 117,

  CXCursor_CompoundLiteralExpr           = 118,

  CXCursor_InitListExpr                  = 119,

  CXCursor_AddrLabelExpr                 = 120,

  CXCursor_StmtExpr                      = 121,

  CXCursor_GenericSelectionExpr          = 122,

  CXCursor_GNUNullExpr                   = 123,

  CXCursor_CXXStaticCastExpr             = 124,

  CXCursor_CXXDynamicCastExpr            = 125,

  CXCursor_CXXReinterpretCastExpr        = 126,

  CXCursor_CXXConstCastExpr              = 127,

  CXCursor_CXXFunctionalCastExpr         = 128,

  CXCursor_CXXTypeidExpr                 = 129,

  CXCursor_CXXBoolLiteralExpr            = 130,

  CXCursor_CXXNullPtrLiteralExpr         = 131,

  CXCursor_CXXThisExpr                   = 132,

  CXCursor_CXXThrowExpr                  = 133,

  CXCursor_CXXNewExpr                    = 134,

  CXCursor_CXXDeleteExpr                 = 135,

  CXCursor_UnaryExpr                     = 136,

  CXCursor_ObjCStringLiteral             = 137,

  CXCursor_ObjCEncodeExpr                = 138,

  CXCursor_ObjCSelectorExpr              = 139,

  CXCursor_ObjCProtocolExpr              = 140,

  CXCursor_ObjCBridgedCastExpr           = 141,

  CXCursor_PackExpansionExpr             = 142,

  CXCursor_SizeOfPackExpr                = 143,
  /* Represents a C++ lambda expression that produces a local function
   * object.
   *
   * \code
   * void abssort(float *x, unsigned N) {
   *   std::sort(x, x + N,
   *             [](float a, float b) {
   *               return std::abs(a) < std::abs(b);
   *             });
   * }
   * \endcode
   */
  CXCursor_LambdaExpr                    = 144,

  CXCursor_ObjCBoolLiteralExpr           = 145,

  CXCursor_ObjCSelfExpr                  = 146,

  CXCursor_OMPArraySectionExpr           = 147,

  CXCursor_ObjCAvailabilityCheckExpr     = 148,

  CXCursor_FixedPointLiteral             = 149,
  CXCursor_LastExpr                      = CXCursor_FixedPointLiteral,
  /* Statements */
  CXCursor_FirstStmt                     = 200,

  CXCursor_UnexposedStmt                 = 200,

  CXCursor_LabelStmt                     = 201,

  CXCursor_CompoundStmt                  = 202,

  CXCursor_CaseStmt                      = 203,

  CXCursor_DefaultStmt                   = 204,

  CXCursor_IfStmt                        = 205,

  CXCursor_SwitchStmt                    = 206,

  CXCursor_WhileStmt                     = 207,

  CXCursor_DoStmt                        = 208,

  CXCursor_ForStmt                       = 209,

  CXCursor_GotoStmt                      = 210,

  CXCursor_IndirectGotoStmt              = 211,

  CXCursor_ContinueStmt                  = 212,

  CXCursor_BreakStmt                     = 213,

  CXCursor_ReturnStmt                    = 214,

  CXCursor_GCCAsmStmt                    = 215,
  CXCursor_AsmStmt                       = CXCursor_GCCAsmStmt,

  CXCursor_ObjCAtTryStmt                 = 216,

  CXCursor_ObjCAtCatchStmt               = 217,

  CXCursor_ObjCAtFinallyStmt             = 218,

  CXCursor_ObjCAtThrowStmt               = 219,

  CXCursor_ObjCAtSynchronizedStmt        = 220,

  CXCursor_ObjCAutoreleasePoolStmt       = 221,

  CXCursor_ObjCForCollectionStmt         = 222,

  CXCursor_CXXCatchStmt                  = 223,

  CXCursor_CXXTryStmt                    = 224,

  CXCursor_CXXForRangeStmt               = 225,

  CXCursor_SEHTryStmt                    = 226,

  CXCursor_SEHExceptStmt                 = 227,

  CXCursor_SEHFinallyStmt                = 228,

  CXCursor_MSAsmStmt                     = 229,

  CXCursor_NullStmt                      = 230,

  CXCursor_DeclStmt                      = 231,

  CXCursor_OMPParallelDirective          = 232,

  CXCursor_OMPSimdDirective              = 233,

  CXCursor_OMPForDirective               = 234,

  CXCursor_OMPSectionsDirective          = 235,

  CXCursor_OMPSectionDirective           = 236,

  CXCursor_OMPSingleDirective            = 237,

  CXCursor_OMPParallelForDirective       = 238,

  CXCursor_OMPParallelSectionsDirective  = 239,

  CXCursor_OMPTaskDirective              = 240,

  CXCursor_OMPMasterDirective            = 241,

  CXCursor_OMPCriticalDirective          = 242,

  CXCursor_OMPTaskyieldDirective         = 243,

  CXCursor_OMPBarrierDirective           = 244,

  CXCursor_OMPTaskwaitDirective          = 245,

  CXCursor_OMPFlushDirective             = 246,

  CXCursor_SEHLeaveStmt                  = 247,

  CXCursor_OMPOrderedDirective           = 248,

  CXCursor_OMPAtomicDirective            = 249,

  CXCursor_OMPForSimdDirective           = 250,

  CXCursor_OMPParallelForSimdDirective   = 251,

  CXCursor_OMPTargetDirective            = 252,

  CXCursor_OMPTeamsDirective             = 253,

  CXCursor_OMPTaskgroupDirective         = 254,

  CXCursor_OMPCancellationPointDirective = 255,

  CXCursor_OMPCancelDirective            = 256,

  CXCursor_OMPTargetDataDirective        = 257,

  CXCursor_OMPTaskLoopDirective          = 258,

  CXCursor_OMPTaskLoopSimdDirective      = 259,

  CXCursor_OMPDistributeDirective        = 260,

  CXCursor_OMPTargetEnterDataDirective   = 261,

  CXCursor_OMPTargetExitDataDirective    = 262,

  CXCursor_OMPTargetParallelDirective    = 263,

  CXCursor_OMPTargetParallelForDirective = 264,

  CXCursor_OMPTargetUpdateDirective      = 265,

  CXCursor_OMPDistributeParallelForDirective = 266,

  CXCursor_OMPDistributeParallelForSimdDirective = 267,

  CXCursor_OMPDistributeSimdDirective = 268,

  CXCursor_OMPTargetParallelForSimdDirective = 269,

  CXCursor_OMPTargetSimdDirective = 270,

  CXCursor_OMPTeamsDistributeDirective = 271,

  CXCursor_OMPTeamsDistributeSimdDirective = 272,

  CXCursor_OMPTeamsDistributeParallelForSimdDirective = 273,

  CXCursor_OMPTeamsDistributeParallelForDirective = 274,

  CXCursor_OMPTargetTeamsDirective = 275,

  CXCursor_OMPTargetTeamsDistributeDirective = 276,

  CXCursor_OMPTargetTeamsDistributeParallelForDirective = 277,

  CXCursor_OMPTargetTeamsDistributeParallelForSimdDirective = 278,

  CXCursor_OMPTargetTeamsDistributeSimdDirective = 279,

  CXCursor_BuiltinBitCastExpr = 280,

  CXCursor_OMPMasterTaskLoopDirective = 281,

  CXCursor_OMPParallelMasterTaskLoopDirective = 282,

  CXCursor_OMPMasterTaskLoopSimdDirective      = 283,

  CXCursor_OMPParallelMasterTaskLoopSimdDirective      = 284,

  CXCursor_OMPParallelMasterDirective      = 285,
  CXCursor_LastStmt = CXCursor_OMPParallelMasterDirective,

  CXCursor_TranslationUnit               = 300,
  /* Attributes */
  CXCursor_FirstAttr                     = 400,

  CXCursor_UnexposedAttr                 = 400,
  CXCursor_IBActionAttr                  = 401,
  CXCursor_IBOutletAttr                  = 402,
  CXCursor_IBOutletCollectionAttr        = 403,
  CXCursor_CXXFinalAttr                  = 404,
  CXCursor_CXXOverrideAttr               = 405,
  CXCursor_AnnotateAttr                  = 406,
  CXCursor_AsmLabelAttr                  = 407,
  CXCursor_PackedAttr                    = 408,
  CXCursor_PureAttr                      = 409,
  CXCursor_ConstAttr                     = 410,
  CXCursor_NoDuplicateAttr               = 411,
  CXCursor_CUDAConstantAttr              = 412,
  CXCursor_CUDADeviceAttr                = 413,
  CXCursor_CUDAGlobalAttr                = 414,
  CXCursor_CUDAHostAttr                  = 415,
  CXCursor_CUDASharedAttr                = 416,
  CXCursor_VisibilityAttr                = 417,
  CXCursor_DLLExport                     = 418,
  CXCursor_DLLImport                     = 419,
  CXCursor_NSReturnsRetained             = 420,
  CXCursor_NSReturnsNotRetained          = 421,
  CXCursor_NSReturnsAutoreleased         = 422,
  CXCursor_NSConsumesSelf                = 423,
  CXCursor_NSConsumed                    = 424,
  CXCursor_ObjCException                 = 425,
  CXCursor_ObjCNSObject                  = 426,
  CXCursor_ObjCIndependentClass          = 427,
  CXCursor_ObjCPreciseLifetime           = 428,
  CXCursor_ObjCReturnsInnerPointer       = 429,
  CXCursor_ObjCRequiresSuper             = 430,
  CXCursor_ObjCRootClass                 = 431,
  CXCursor_ObjCSubclassingRestricted     = 432,
  CXCursor_ObjCExplicitProtocolImpl      = 433,
  CXCursor_ObjCDesignatedInitializer     = 434,
  CXCursor_ObjCRuntimeVisible            = 435,
  CXCursor_ObjCBoxable                   = 436,
  CXCursor_FlagEnum                      = 437,
  CXCursor_ConvergentAttr                = 438,
  CXCursor_WarnUnusedAttr                = 439,
  CXCursor_WarnUnusedResultAttr          = 440,
  CXCursor_AlignedAttr                   = 441,
  CXCursor_LastAttr                      = CXCursor_AlignedAttr,
  /* Preprocessing */
  CXCursor_PreprocessingDirective        = 500,
  CXCursor_MacroDefinition               = 501,
  CXCursor_MacroExpansion                = 502,
  CXCursor_MacroInstantiation            = CXCursor_MacroExpansion,
  CXCursor_InclusionDirective            = 503,
  CXCursor_FirstPreprocessing            = CXCursor_PreprocessingDirective,
  CXCursor_LastPreprocessing             = CXCursor_InclusionDirective,
  /* Extra Declarations */

  CXCursor_ModuleImportDecl              = 600,
  CXCursor_TypeAliasTemplateDecl         = 601,

  CXCursor_StaticAssert                  = 602,

  CXCursor_FriendDecl                    = 603,
  CXCursor_FirstExtraDecl                = CXCursor_ModuleImportDecl,
  CXCursor_LastExtraDecl                 = CXCursor_FriendDecl,

  CXCursor_OverloadCandidate             = 700
};
typedef struct {
  enum CXCursorKind kind;
  int xdata;
  const void *data[3];
} CXCursor;
 CXCursor clang_getNullCursor(void);
 CXCursor clang_getTranslationUnitCursor(CXTranslationUnit);
 unsigned clang_equalCursors(CXCursor, CXCursor);
 int clang_Cursor_isNull(CXCursor cursor);
 unsigned clang_hashCursor(CXCursor);
 enum CXCursorKind clang_getCursorKind(CXCursor);
 unsigned clang_isDeclaration(enum CXCursorKind);
 unsigned clang_isInvalidDeclaration(CXCursor);
 unsigned clang_isReference(enum CXCursorKind);
 unsigned clang_isExpression(enum CXCursorKind);
 unsigned clang_isStatement(enum CXCursorKind);
 unsigned clang_isAttribute(enum CXCursorKind);
 unsigned clang_Cursor_hasAttrs(CXCursor C);
 unsigned clang_isInvalid(enum CXCursorKind);
 unsigned clang_isTranslationUnit(enum CXCursorKind);
 unsigned clang_isPreprocessing(enum CXCursorKind);
 unsigned clang_isUnexposed(enum CXCursorKind);
enum CXLinkageKind {

  CXLinkage_Invalid,

  CXLinkage_NoLinkage,

  CXLinkage_Internal,

  CXLinkage_UniqueExternal,

  CXLinkage_External
};
 enum CXLinkageKind clang_getCursorLinkage(CXCursor cursor);
enum CXVisibilityKind {

  CXVisibility_Invalid,

  CXVisibility_Hidden,

  CXVisibility_Protected,

  CXVisibility_Default
};
 enum CXVisibilityKind clang_getCursorVisibility(CXCursor cursor);
 enum CXAvailabilityKind
clang_getCursorAvailability(CXCursor cursor);
typedef struct CXPlatformAvailability {

  CXString Platform;

  CXVersion Introduced;

  CXVersion Deprecated;

  CXVersion Obsoleted;

  int Unavailable;

  CXString Message;
} CXPlatformAvailability;
 int
clang_getCursorPlatformAvailability(CXCursor cursor,
                                    int *always_deprecated,
                                    CXString *deprecated_message,
                                    int *always_unavailable,
                                    CXString *unavailable_message,
                                    CXPlatformAvailability *availability,
                                    int availability_size);
 void
clang_disposeCXPlatformAvailability(CXPlatformAvailability *availability);
enum CXLanguageKind {
  CXLanguage_Invalid = 0,
  CXLanguage_C,
  CXLanguage_ObjC,
  CXLanguage_CPlusPlus
};
 enum CXLanguageKind clang_getCursorLanguage(CXCursor cursor);
enum CXTLSKind {
  CXTLS_None = 0,
  CXTLS_Dynamic,
  CXTLS_Static
};
 enum CXTLSKind clang_getCursorTLSKind(CXCursor cursor);
 CXTranslationUnit clang_Cursor_getTranslationUnit(CXCursor);
typedef struct CXCursorSetImpl *CXCursorSet;
 CXCursorSet clang_createCXCursorSet(void);
 void clang_disposeCXCursorSet(CXCursorSet cset);
 unsigned clang_CXCursorSet_contains(CXCursorSet cset,
                                                   CXCursor cursor);
 unsigned clang_CXCursorSet_insert(CXCursorSet cset,
                                                 CXCursor cursor);
 CXCursor clang_getCursorSemanticParent(CXCursor cursor);
 CXCursor clang_getCursorLexicalParent(CXCursor cursor);
 void clang_getOverriddenCursors(CXCursor cursor,
                                               CXCursor **overridden,
                                               unsigned *num_overridden);
 void clang_disposeOverriddenCursors(CXCursor *overridden);
 CXFile clang_getIncludedFile(CXCursor cursor);
 CXCursor clang_getCursor(CXTranslationUnit, CXSourceLocation);
 CXSourceLocation clang_getCursorLocation(CXCursor);
 CXSourceRange clang_getCursorExtent(CXCursor);
enum CXTypeKind {

  CXType_Invalid = 0,

  CXType_Unexposed = 1,
  /* Builtin types */
  CXType_Void = 2,
  CXType_Bool = 3,
  CXType_Char_U = 4,
  CXType_UChar = 5,
  CXType_Char16 = 6,
  CXType_Char32 = 7,
  CXType_UShort = 8,
  CXType_UInt = 9,
  CXType_ULong = 10,
  CXType_ULongLong = 11,
  CXType_UInt128 = 12,
  CXType_Char_S = 13,
  CXType_SChar = 14,
  CXType_WChar = 15,
  CXType_Short = 16,
  CXType_Int = 17,
  CXType_Long = 18,
  CXType_LongLong = 19,
  CXType_Int128 = 20,
  CXType_Float = 21,
  CXType_Double = 22,
  CXType_LongDouble = 23,
  CXType_NullPtr = 24,
  CXType_Overload = 25,
  CXType_Dependent = 26,
  CXType_ObjCId = 27,
  CXType_ObjCClass = 28,
  CXType_ObjCSel = 29,
  CXType_Float128 = 30,
  CXType_Half = 31,
  CXType_Float16 = 32,
  CXType_ShortAccum = 33,
  CXType_Accum = 34,
  CXType_LongAccum = 35,
  CXType_UShortAccum = 36,
  CXType_UAccum = 37,
  CXType_ULongAccum = 38,
  CXType_FirstBuiltin = CXType_Void,
  CXType_LastBuiltin = CXType_ULongAccum,
  CXType_Complex = 100,
  CXType_Pointer = 101,
  CXType_BlockPointer = 102,
  CXType_LValueReference = 103,
  CXType_RValueReference = 104,
  CXType_Record = 105,
  CXType_Enum = 106,
  CXType_Typedef = 107,
  CXType_ObjCInterface = 108,
  CXType_ObjCObjectPointer = 109,
  CXType_FunctionNoProto = 110,
  CXType_FunctionProto = 111,
  CXType_ConstantArray = 112,
  CXType_Vector = 113,
  CXType_IncompleteArray = 114,
  CXType_VariableArray = 115,
  CXType_DependentSizedArray = 116,
  CXType_MemberPointer = 117,
  CXType_Auto = 118,

  CXType_Elaborated = 119,
  /* OpenCL PipeType. */
  CXType_Pipe = 120,
  /* OpenCL builtin types. */
  CXType_OCLImage1dRO = 121,
  CXType_OCLImage1dArrayRO = 122,
  CXType_OCLImage1dBufferRO = 123,
  CXType_OCLImage2dRO = 124,
  CXType_OCLImage2dArrayRO = 125,
  CXType_OCLImage2dDepthRO = 126,
  CXType_OCLImage2dArrayDepthRO = 127,
  CXType_OCLImage2dMSAARO = 128,
  CXType_OCLImage2dArrayMSAARO = 129,
  CXType_OCLImage2dMSAADepthRO = 130,
  CXType_OCLImage2dArrayMSAADepthRO = 131,
  CXType_OCLImage3dRO = 132,
  CXType_OCLImage1dWO = 133,
  CXType_OCLImage1dArrayWO = 134,
  CXType_OCLImage1dBufferWO = 135,
  CXType_OCLImage2dWO = 136,
  CXType_OCLImage2dArrayWO = 137,
  CXType_OCLImage2dDepthWO = 138,
  CXType_OCLImage2dArrayDepthWO = 139,
  CXType_OCLImage2dMSAAWO = 140,
  CXType_OCLImage2dArrayMSAAWO = 141,
  CXType_OCLImage2dMSAADepthWO = 142,
  CXType_OCLImage2dArrayMSAADepthWO = 143,
  CXType_OCLImage3dWO = 144,
  CXType_OCLImage1dRW = 145,
  CXType_OCLImage1dArrayRW = 146,
  CXType_OCLImage1dBufferRW = 147,
  CXType_OCLImage2dRW = 148,
  CXType_OCLImage2dArrayRW = 149,
  CXType_OCLImage2dDepthRW = 150,
  CXType_OCLImage2dArrayDepthRW = 151,
  CXType_OCLImage2dMSAARW = 152,
  CXType_OCLImage2dArrayMSAARW = 153,
  CXType_OCLImage2dMSAADepthRW = 154,
  CXType_OCLImage2dArrayMSAADepthRW = 155,
  CXType_OCLImage3dRW = 156,
  CXType_OCLSampler = 157,
  CXType_OCLEvent = 158,
  CXType_OCLQueue = 159,
  CXType_OCLReserveID = 160,
  CXType_ObjCObject = 161,
  CXType_ObjCTypeParam = 162,
  CXType_Attributed = 163,
  CXType_OCLIntelSubgroupAVCMcePayload = 164,
  CXType_OCLIntelSubgroupAVCImePayload = 165,
  CXType_OCLIntelSubgroupAVCRefPayload = 166,
  CXType_OCLIntelSubgroupAVCSicPayload = 167,
  CXType_OCLIntelSubgroupAVCMceResult = 168,
  CXType_OCLIntelSubgroupAVCImeResult = 169,
  CXType_OCLIntelSubgroupAVCRefResult = 170,
  CXType_OCLIntelSubgroupAVCSicResult = 171,
  CXType_OCLIntelSubgroupAVCImeResultSingleRefStreamout = 172,
  CXType_OCLIntelSubgroupAVCImeResultDualRefStreamout = 173,
  CXType_OCLIntelSubgroupAVCImeSingleRefStreamin = 174,
  CXType_OCLIntelSubgroupAVCImeDualRefStreamin = 175,
  CXType_ExtVector = 176
};
enum CXCallingConv {
  CXCallingConv_Default = 0,
  CXCallingConv_C = 1,
  CXCallingConv_X86StdCall = 2,
  CXCallingConv_X86FastCall = 3,
  CXCallingConv_X86ThisCall = 4,
  CXCallingConv_X86Pascal = 5,
  CXCallingConv_AAPCS = 6,
  CXCallingConv_AAPCS_VFP = 7,
  CXCallingConv_X86RegCall = 8,
  CXCallingConv_IntelOclBicc = 9,
  CXCallingConv_Win64 = 10,
  /* Alias for compatibility with older versions of API. */
  CXCallingConv_X86_64Win64 = CXCallingConv_Win64,
  CXCallingConv_X86_64SysV = 11,
  CXCallingConv_X86VectorCall = 12,
  CXCallingConv_Swift = 13,
  CXCallingConv_PreserveMost = 14,
  CXCallingConv_PreserveAll = 15,
  CXCallingConv_AArch64VectorCall = 16,
  CXCallingConv_Invalid = 100,
  CXCallingConv_Unexposed = 200
};
typedef struct {
  enum CXTypeKind kind;
  void *data[2];
} CXType;
 CXType clang_getCursorType(CXCursor C);
 CXString clang_getTypeSpelling(CXType CT);
 CXType clang_getTypedefDeclUnderlyingType(CXCursor C);
 CXType clang_getEnumDeclIntegerType(CXCursor C);
 long long clang_getEnumConstantDeclValue(CXCursor C);
 unsigned long long clang_getEnumConstantDeclUnsignedValue(CXCursor C);
 int clang_getFieldDeclBitWidth(CXCursor C);
 int clang_Cursor_getNumArguments(CXCursor C);
 CXCursor clang_Cursor_getArgument(CXCursor C, unsigned i);
enum CXTemplateArgumentKind {
  CXTemplateArgumentKind_Null,
  CXTemplateArgumentKind_Type,
  CXTemplateArgumentKind_Declaration,
  CXTemplateArgumentKind_NullPtr,
  CXTemplateArgumentKind_Integral,
  CXTemplateArgumentKind_Template,
  CXTemplateArgumentKind_TemplateExpansion,
  CXTemplateArgumentKind_Expression,
  CXTemplateArgumentKind_Pack,
  /* Indicates an error case, preventing the kind from being deduced. */
  CXTemplateArgumentKind_Invalid
};
 int clang_Cursor_getNumTemplateArguments(CXCursor C);
 enum CXTemplateArgumentKind clang_Cursor_getTemplateArgumentKind(
    CXCursor C, unsigned I);
 CXType clang_Cursor_getTemplateArgumentType(CXCursor C,
                                                           unsigned I);
 long long clang_Cursor_getTemplateArgumentValue(CXCursor C,
                                                               unsigned I);
 unsigned long long clang_Cursor_getTemplateArgumentUnsignedValue(
    CXCursor C, unsigned I);
 unsigned clang_equalTypes(CXType A, CXType B);
 CXType clang_getCanonicalType(CXType T);
 unsigned clang_isConstQualifiedType(CXType T);
 unsigned clang_Cursor_isMacroFunctionLike(CXCursor C);
 unsigned clang_Cursor_isMacroBuiltin(CXCursor C);
 unsigned clang_Cursor_isFunctionInlined(CXCursor C);
 unsigned clang_isVolatileQualifiedType(CXType T);
 unsigned clang_isRestrictQualifiedType(CXType T);
 unsigned clang_getAddressSpace(CXType T);
 CXString clang_getTypedefName(CXType CT);
 CXType clang_getPointeeType(CXType T);
 CXCursor clang_getTypeDeclaration(CXType T);
 CXString clang_getDeclObjCTypeEncoding(CXCursor C);
 CXString clang_Type_getObjCEncoding(CXType type);
 CXString clang_getTypeKindSpelling(enum CXTypeKind K);
 enum CXCallingConv clang_getFunctionTypeCallingConv(CXType T);
 CXType clang_getResultType(CXType T);
 int clang_getExceptionSpecificationType(CXType T);
 int clang_getNumArgTypes(CXType T);
 CXType clang_getArgType(CXType T, unsigned i);
 CXType clang_Type_getObjCObjectBaseType(CXType T);
 unsigned clang_Type_getNumObjCProtocolRefs(CXType T);
 CXCursor clang_Type_getObjCProtocolDecl(CXType T, unsigned i);
 unsigned clang_Type_getNumObjCTypeArgs(CXType T);
 CXType clang_Type_getObjCTypeArg(CXType T, unsigned i);
 unsigned clang_isFunctionTypeVariadic(CXType T);
 CXType clang_getCursorResultType(CXCursor C);
 int clang_getCursorExceptionSpecificationType(CXCursor C);
 unsigned clang_isPODType(CXType T);
 CXType clang_getElementType(CXType T);
 long long clang_getNumElements(CXType T);
 CXType clang_getArrayElementType(CXType T);
 long long clang_getArraySize(CXType T);
 CXType clang_Type_getNamedType(CXType T);
 unsigned clang_Type_isTransparentTagTypedef(CXType T);
enum CXTypeNullabilityKind {

  CXTypeNullability_NonNull = 0,

  CXTypeNullability_Nullable = 1,

  CXTypeNullability_Unspecified = 2,

  CXTypeNullability_Invalid = 3
};
 enum CXTypeNullabilityKind clang_Type_getNullability(CXType T);
enum CXTypeLayoutError {

  CXTypeLayoutError_Invalid = -1,

  CXTypeLayoutError_Incomplete = -2,

  CXTypeLayoutError_Dependent = -3,

  CXTypeLayoutError_NotConstantSize = -4,

  CXTypeLayoutError_InvalidFieldName = -5,

  CXTypeLayoutError_Undeduced = -6
};
 long long clang_Type_getAlignOf(CXType T);
 CXType clang_Type_getClassType(CXType T);
 long long clang_Type_getSizeOf(CXType T);
 long long clang_Type_getOffsetOf(CXType T, const char *S);
 CXType clang_Type_getModifiedType(CXType T);
 long long clang_Cursor_getOffsetOfField(CXCursor C);
 unsigned clang_Cursor_isAnonymous(CXCursor C);
 unsigned clang_Cursor_isAnonymousRecordDecl(CXCursor C);
 unsigned clang_Cursor_isInlineNamespace(CXCursor C);
enum CXRefQualifierKind {

  CXRefQualifier_None = 0,

  CXRefQualifier_LValue,

  CXRefQualifier_RValue
};
 int clang_Type_getNumTemplateArguments(CXType T);
 CXType clang_Type_getTemplateArgumentAsType(CXType T, unsigned i);
 enum CXRefQualifierKind clang_Type_getCXXRefQualifier(CXType T);
 unsigned clang_Cursor_isBitField(CXCursor C);
 unsigned clang_isVirtualBase(CXCursor);
enum CX_CXXAccessSpecifier {
  CX_CXXInvalidAccessSpecifier,
  CX_CXXPublic,
  CX_CXXProtected,
  CX_CXXPrivate
};
 enum CX_CXXAccessSpecifier clang_getCXXAccessSpecifier(CXCursor);
enum CX_StorageClass {
  CX_SC_Invalid,
  CX_SC_None,
  CX_SC_Extern,
  CX_SC_Static,
  CX_SC_PrivateExtern,
  CX_SC_OpenCLWorkGroupLocal,
  CX_SC_Auto,
  CX_SC_Register
};
 enum CX_StorageClass clang_Cursor_getStorageClass(CXCursor);
 unsigned clang_getNumOverloadedDecls(CXCursor cursor);
 CXCursor clang_getOverloadedDecl(CXCursor cursor,
                                                unsigned index);
 CXType clang_getIBOutletCollectionType(CXCursor);
enum CXChildVisitResult {

  CXChildVisit_Break,

  CXChildVisit_Continue,

  CXChildVisit_Recurse
};
typedef enum CXChildVisitResult (*CXCursorVisitor)(CXCursor cursor,
                                                   CXCursor parent,
                                                   CXClientData client_data);
 unsigned clang_visitChildren(CXCursor parent,
                                            CXCursorVisitor visitor,
                                            CXClientData client_data);
 CXString clang_getCursorUSR(CXCursor);
 CXString clang_constructUSR_ObjCClass(const char *class_name);
 CXString
  clang_constructUSR_ObjCCategory(const char *class_name,
                                 const char *category_name);
 CXString
  clang_constructUSR_ObjCProtocol(const char *protocol_name);
 CXString clang_constructUSR_ObjCIvar(const char *name,
                                                    CXString classUSR);
 CXString clang_constructUSR_ObjCMethod(const char *name,
                                                      unsigned isInstanceMethod,
                                                      CXString classUSR);
 CXString clang_constructUSR_ObjCProperty(const char *property,
                                                        CXString classUSR);
 CXString clang_getCursorSpelling(CXCursor);
 CXSourceRange clang_Cursor_getSpellingNameRange(CXCursor,
                                                          unsigned pieceIndex,
                                                          unsigned options);
typedef void *CXPrintingPolicy;
enum CXPrintingPolicyProperty {
  CXPrintingPolicy_Indentation,
  CXPrintingPolicy_SuppressSpecifiers,
  CXPrintingPolicy_SuppressTagKeyword,
  CXPrintingPolicy_IncludeTagDefinition,
  CXPrintingPolicy_SuppressScope,
  CXPrintingPolicy_SuppressUnwrittenScope,
  CXPrintingPolicy_SuppressInitializers,
  CXPrintingPolicy_ConstantArraySizeAsWritten,
  CXPrintingPolicy_AnonymousTagLocations,
  CXPrintingPolicy_SuppressStrongLifetime,
  CXPrintingPolicy_SuppressLifetimeQualifiers,
  CXPrintingPolicy_SuppressTemplateArgsInCXXConstructors,
  CXPrintingPolicy_Bool,
  CXPrintingPolicy_Restrict,
  CXPrintingPolicy_Alignof,
  CXPrintingPolicy_UnderscoreAlignof,
  CXPrintingPolicy_UseVoidForZeroParams,
  CXPrintingPolicy_TerseOutput,
  CXPrintingPolicy_PolishForDeclaration,
  CXPrintingPolicy_Half,
  CXPrintingPolicy_MSWChar,
  CXPrintingPolicy_IncludeNewlines,
  CXPrintingPolicy_MSVCFormatting,
  CXPrintingPolicy_ConstantsAsWritten,
  CXPrintingPolicy_SuppressImplicitBase,
  CXPrintingPolicy_FullyQualifiedName,
  CXPrintingPolicy_LastProperty = CXPrintingPolicy_FullyQualifiedName
};
 unsigned
clang_PrintingPolicy_getProperty(CXPrintingPolicy Policy,
                                 enum CXPrintingPolicyProperty Property);
 void clang_PrintingPolicy_setProperty(CXPrintingPolicy Policy,
                                                     enum CXPrintingPolicyProperty Property,
                                                     unsigned Value);
 CXPrintingPolicy clang_getCursorPrintingPolicy(CXCursor);
 void clang_PrintingPolicy_dispose(CXPrintingPolicy Policy);
 CXString clang_getCursorPrettyPrinted(CXCursor Cursor,
                                                     CXPrintingPolicy Policy);
 CXString clang_getCursorDisplayName(CXCursor);
 CXCursor clang_getCursorReferenced(CXCursor);
 CXCursor clang_getCursorDefinition(CXCursor);
 unsigned clang_isCursorDefinition(CXCursor);
 CXCursor clang_getCanonicalCursor(CXCursor);
 int clang_Cursor_getObjCSelectorIndex(CXCursor);
 int clang_Cursor_isDynamicCall(CXCursor C);
 CXType clang_Cursor_getReceiverType(CXCursor C);
typedef enum {
  CXObjCPropertyAttr_noattr    = 0x00,
  CXObjCPropertyAttr_readonly  = 0x01,
  CXObjCPropertyAttr_getter    = 0x02,
  CXObjCPropertyAttr_assign    = 0x04,
  CXObjCPropertyAttr_readwrite = 0x08,
  CXObjCPropertyAttr_retain    = 0x10,
  CXObjCPropertyAttr_copy      = 0x20,
  CXObjCPropertyAttr_nonatomic = 0x40,
  CXObjCPropertyAttr_setter    = 0x80,
  CXObjCPropertyAttr_atomic    = 0x100,
  CXObjCPropertyAttr_weak      = 0x200,
  CXObjCPropertyAttr_strong    = 0x400,
  CXObjCPropertyAttr_unsafe_unretained = 0x800,
  CXObjCPropertyAttr_class = 0x1000
} CXObjCPropertyAttrKind;
 unsigned clang_Cursor_getObjCPropertyAttributes(CXCursor C,
                                                             unsigned reserved);
 CXString clang_Cursor_getObjCPropertyGetterName(CXCursor C);
 CXString clang_Cursor_getObjCPropertySetterName(CXCursor C);
typedef enum {
  CXObjCDeclQualifier_None = 0x0,
  CXObjCDeclQualifier_In = 0x1,
  CXObjCDeclQualifier_Inout = 0x2,
  CXObjCDeclQualifier_Out = 0x4,
  CXObjCDeclQualifier_Bycopy = 0x8,
  CXObjCDeclQualifier_Byref = 0x10,
  CXObjCDeclQualifier_Oneway = 0x20
} CXObjCDeclQualifierKind;
 unsigned clang_Cursor_getObjCDeclQualifiers(CXCursor C);
 unsigned clang_Cursor_isObjCOptional(CXCursor C);
 unsigned clang_Cursor_isVariadic(CXCursor C);
 unsigned clang_Cursor_isExternalSymbol(CXCursor C,
                                       CXString *language, CXString *definedIn,
                                       unsigned *isGenerated);
 CXSourceRange clang_Cursor_getCommentRange(CXCursor C);
 CXString clang_Cursor_getRawCommentText(CXCursor C);
 CXString clang_Cursor_getBriefCommentText(CXCursor C);
 CXString clang_Cursor_getMangling(CXCursor);
 CXStringSet *clang_Cursor_getCXXManglings(CXCursor);
 CXStringSet *clang_Cursor_getObjCManglings(CXCursor);
typedef void *CXModule;
 CXModule clang_Cursor_getModule(CXCursor C);
 CXModule clang_getModuleForFile(CXTranslationUnit, CXFile);
 CXFile clang_Module_getASTFile(CXModule Module);
 CXModule clang_Module_getParent(CXModule Module);
 CXString clang_Module_getName(CXModule Module);
 CXString clang_Module_getFullName(CXModule Module);
 int clang_Module_isSystem(CXModule Module);
 unsigned clang_Module_getNumTopLevelHeaders(CXTranslationUnit,
                                                           CXModule Module);
CXFile clang_Module_getTopLevelHeader(CXTranslationUnit,
                                      CXModule Module, unsigned Index);
 unsigned clang_CXXConstructor_isConvertingConstructor(CXCursor C);
 unsigned clang_CXXConstructor_isCopyConstructor(CXCursor C);
 unsigned clang_CXXConstructor_isDefaultConstructor(CXCursor C);
 unsigned clang_CXXConstructor_isMoveConstructor(CXCursor C);
 unsigned clang_CXXField_isMutable(CXCursor C);
 unsigned clang_CXXMethod_isDefaulted(CXCursor C);
 unsigned clang_CXXMethod_isPureVirtual(CXCursor C);
 unsigned clang_CXXMethod_isStatic(CXCursor C);
 unsigned clang_CXXMethod_isVirtual(CXCursor C);
 unsigned clang_CXXRecord_isAbstract(CXCursor C);
 unsigned clang_EnumDecl_isScoped(CXCursor C);
 unsigned clang_CXXMethod_isConst(CXCursor C);
 enum CXCursorKind clang_getTemplateCursorKind(CXCursor C);
 CXCursor clang_getSpecializedCursorTemplate(CXCursor C);
 CXSourceRange clang_getCursorReferenceNameRange(CXCursor C,
                                                unsigned NameFlags,
                                                unsigned PieceIndex);
enum CXNameRefFlags {

  CXNameRange_WantQualifier = 0x1,

  CXNameRange_WantTemplateArgs = 0x2,

  CXNameRange_WantSinglePiece = 0x4
};
typedef enum CXTokenKind {

  CXToken_Punctuation,

  CXToken_Keyword,

  CXToken_Identifier,

  CXToken_Literal,

  CXToken_Comment
} CXTokenKind;
typedef struct {
  unsigned int_data[4];
  void *ptr_data;
} CXToken;
 CXToken *clang_getToken(CXTranslationUnit TU,
                                       CXSourceLocation Location);
 CXTokenKind clang_getTokenKind(CXToken);
 CXString clang_getTokenSpelling(CXTranslationUnit, CXToken);
 CXSourceLocation clang_getTokenLocation(CXTranslationUnit,
                                                       CXToken);
 CXSourceRange clang_getTokenExtent(CXTranslationUnit, CXToken);
 void clang_tokenize(CXTranslationUnit TU, CXSourceRange Range,
                                   CXToken **Tokens, unsigned *NumTokens);
 void clang_annotateTokens(CXTranslationUnit TU,
                                         CXToken *Tokens, unsigned NumTokens,
                                         CXCursor *Cursors);
 void clang_disposeTokens(CXTranslationUnit TU,
                                        CXToken *Tokens, unsigned NumTokens);
/* for debug/testing */
 CXString clang_getCursorKindSpelling(enum CXCursorKind Kind);
 void clang_getDefinitionSpellingAndExtent(CXCursor,
                                          const char **startBuf,
                                          const char **endBuf,
                                          unsigned *startLine,
                                          unsigned *startColumn,
                                          unsigned *endLine,
                                          unsigned *endColumn);
 void clang_enableStackTraces(void);
 void clang_executeOnThread(void (*fn)(void*), void *user_data,
                                          unsigned stack_size);
typedef void *CXCompletionString;
typedef struct {

  enum CXCursorKind CursorKind;

  CXCompletionString CompletionString;
} CXCompletionResult;
enum CXCompletionChunkKind {

  CXCompletionChunk_Optional,

  CXCompletionChunk_TypedText,

  CXCompletionChunk_Text,

  CXCompletionChunk_Placeholder,

  CXCompletionChunk_Informative,

  CXCompletionChunk_CurrentParameter,

  CXCompletionChunk_LeftParen,

  CXCompletionChunk_RightParen,

  CXCompletionChunk_LeftBracket,

  CXCompletionChunk_RightBracket,

  CXCompletionChunk_LeftBrace,

  CXCompletionChunk_RightBrace,

  CXCompletionChunk_LeftAngle,

  CXCompletionChunk_RightAngle,

  CXCompletionChunk_Comma,

  CXCompletionChunk_ResultType,

  CXCompletionChunk_Colon,

  CXCompletionChunk_SemiColon,

  CXCompletionChunk_Equal,

  CXCompletionChunk_HorizontalSpace,

  CXCompletionChunk_VerticalSpace
};
 enum CXCompletionChunkKind
clang_getCompletionChunkKind(CXCompletionString completion_string,
                             unsigned chunk_number);
 CXString
clang_getCompletionChunkText(CXCompletionString completion_string,
                             unsigned chunk_number);
 CXCompletionString
clang_getCompletionChunkCompletionString(CXCompletionString completion_string,
                                         unsigned chunk_number);
 unsigned
clang_getNumCompletionChunks(CXCompletionString completion_string);
 unsigned
clang_getCompletionPriority(CXCompletionString completion_string);
 enum CXAvailabilityKind
clang_getCompletionAvailability(CXCompletionString completion_string);
 unsigned
clang_getCompletionNumAnnotations(CXCompletionString completion_string);
 CXString
clang_getCompletionAnnotation(CXCompletionString completion_string,
                              unsigned annotation_number);
 CXString
clang_getCompletionParent(CXCompletionString completion_string,
                          enum CXCursorKind *kind);
 CXString
clang_getCompletionBriefComment(CXCompletionString completion_string);
 CXCompletionString
clang_getCursorCompletionString(CXCursor cursor);
typedef struct {

  CXCompletionResult *Results;

  unsigned NumResults;
} CXCodeCompleteResults;
 unsigned
clang_getCompletionNumFixIts(CXCodeCompleteResults *results,
                             unsigned completion_index);
 CXString clang_getCompletionFixIt(
    CXCodeCompleteResults *results, unsigned completion_index,
    unsigned fixit_index, CXSourceRange *replacement_range);
enum CXCodeComplete_Flags {

  CXCodeComplete_IncludeMacros = 0x01,

  CXCodeComplete_IncludeCodePatterns = 0x02,

  CXCodeComplete_IncludeBriefComments = 0x04,

  CXCodeComplete_SkipPreamble = 0x08,

  CXCodeComplete_IncludeCompletionsWithFixIts = 0x10
};
enum CXCompletionContext {

  CXCompletionContext_Unexposed = 0,

  CXCompletionContext_AnyType = 1 << 0,

  CXCompletionContext_AnyValue = 1 << 1,

  CXCompletionContext_ObjCObjectValue = 1 << 2,

  CXCompletionContext_ObjCSelectorValue = 1 << 3,

  CXCompletionContext_CXXClassTypeValue = 1 << 4,

  CXCompletionContext_DotMemberAccess = 1 << 5,

  CXCompletionContext_ArrowMemberAccess = 1 << 6,

  CXCompletionContext_ObjCPropertyAccess = 1 << 7,

  CXCompletionContext_EnumTag = 1 << 8,

  CXCompletionContext_UnionTag = 1 << 9,

  CXCompletionContext_StructTag = 1 << 10,

  CXCompletionContext_ClassTag = 1 << 11,

  CXCompletionContext_Namespace = 1 << 12,

  CXCompletionContext_NestedNameSpecifier = 1 << 13,

  CXCompletionContext_ObjCInterface = 1 << 14,

  CXCompletionContext_ObjCProtocol = 1 << 15,

  CXCompletionContext_ObjCCategory = 1 << 16,

  CXCompletionContext_ObjCInstanceMessage = 1 << 17,

  CXCompletionContext_ObjCClassMessage = 1 << 18,

  CXCompletionContext_ObjCSelectorName = 1 << 19,

  CXCompletionContext_MacroName = 1 << 20,

  CXCompletionContext_NaturalLanguage = 1 << 21,

  CXCompletionContext_IncludedFile = 1 << 22,

  CXCompletionContext_Unknown = ((1 << 23) - 1)
};
 unsigned clang_defaultCodeCompleteOptions(void);
CXCodeCompleteResults *clang_codeCompleteAt(CXTranslationUnit TU,
                                            const char *complete_filename,
                                            unsigned complete_line,
                                            unsigned complete_column,
                                            struct CXUnsavedFile *unsaved_files,
                                            unsigned num_unsaved_files,
                                            unsigned options);
void clang_sortCodeCompletionResults(CXCompletionResult *Results,
                                     unsigned NumResults);
void clang_disposeCodeCompleteResults(CXCodeCompleteResults *Results);
unsigned clang_codeCompleteGetNumDiagnostics(CXCodeCompleteResults *Results);
CXDiagnostic clang_codeCompleteGetDiagnostic(CXCodeCompleteResults *Results,
                                             unsigned Index);
unsigned long long clang_codeCompleteGetContexts(
                                                CXCodeCompleteResults *Results);
enum CXCursorKind clang_codeCompleteGetContainerKind(
                                                 CXCodeCompleteResults *Results,
                                                     unsigned *IsIncomplete);
CXString clang_codeCompleteGetContainerUSR(CXCodeCompleteResults *Results);
CXString clang_codeCompleteGetObjCSelector(CXCodeCompleteResults *Results);
 CXString clang_getClangVersion(void);
 void clang_toggleCrashRecovery(unsigned isEnabled);

typedef void (*CXInclusionVisitor)(CXFile included_file,
                                   CXSourceLocation* inclusion_stack,
                                   unsigned include_len,
                                   CXClientData client_data);
 void clang_getInclusions(CXTranslationUnit tu,
                                        CXInclusionVisitor visitor,
                                        CXClientData client_data);
typedef enum {
  CXEval_Int = 1 ,
  CXEval_Float = 2,
  CXEval_ObjCStrLiteral = 3,
  CXEval_StrLiteral = 4,
  CXEval_CFStr = 5,
  CXEval_Other = 6,
  CXEval_UnExposed = 0
} CXEvalResultKind ;
typedef void * CXEvalResult;
 CXEvalResult clang_Cursor_Evaluate(CXCursor C);
 CXEvalResultKind clang_EvalResult_getKind(CXEvalResult E);
 int clang_EvalResult_getAsInt(CXEvalResult E);
 long long clang_EvalResult_getAsLongLong(CXEvalResult E);
 unsigned clang_EvalResult_isUnsignedInt(CXEvalResult E);
 unsigned long long clang_EvalResult_getAsUnsigned(CXEvalResult E);
 double clang_EvalResult_getAsDouble(CXEvalResult E);
 const char* clang_EvalResult_getAsStr(CXEvalResult E);
 void clang_EvalResult_dispose(CXEvalResult E);
typedef void *CXRemapping;
 CXRemapping clang_getRemappings(const char *path);
CXRemapping clang_getRemappingsFromFileList(const char **filePaths,
                                            unsigned numFiles);
 unsigned clang_remap_getNumFiles(CXRemapping);
 void clang_remap_getFilenames(CXRemapping, unsigned index,
                                     CXString *original, CXString *transformed);
 void clang_remap_dispose(CXRemapping);
enum CXVisitorResult {
  CXVisit_Break,
  CXVisit_Continue
};
typedef struct CXCursorAndRangeVisitor {
  void *context;
  enum CXVisitorResult (*visit)(void *context, CXCursor, CXSourceRange);
} CXCursorAndRangeVisitor;
typedef enum {

  CXResult_Success = 0,

  CXResult_Invalid = 1,

  CXResult_VisitBreak = 2
} CXResult;
 CXResult clang_findReferencesInFile(CXCursor cursor, CXFile file,
                                               CXCursorAndRangeVisitor visitor);
 CXResult clang_findIncludesInFile(CXTranslationUnit TU,
                                                 CXFile file,
                                              CXCursorAndRangeVisitor visitor);
typedef void *CXIdxClientFile;
typedef void *CXIdxClientEntity;
typedef void *CXIdxClientContainer;
typedef void *CXIdxClientASTFile;
typedef struct {
  void *ptr_data[2];
  unsigned int_data;
} CXIdxLoc;
typedef struct {

  CXIdxLoc hashLoc;

  const char *filename;

  CXFile file;
  int isImport;
  int isAngled;

  int isModuleImport;
} CXIdxIncludedFileInfo;
typedef struct {

  CXFile file;

  CXModule module;

  CXIdxLoc loc;

  int isImplicit;
} CXIdxImportedASTFileInfo;
typedef enum {
  CXIdxEntity_Unexposed     = 0,
  CXIdxEntity_Typedef       = 1,
  CXIdxEntity_Function      = 2,
  CXIdxEntity_Variable      = 3,
  CXIdxEntity_Field         = 4,
  CXIdxEntity_EnumConstant  = 5,
  CXIdxEntity_ObjCClass     = 6,
  CXIdxEntity_ObjCProtocol  = 7,
  CXIdxEntity_ObjCCategory  = 8,
  CXIdxEntity_ObjCInstanceMethod = 9,
  CXIdxEntity_ObjCClassMethod    = 10,
  CXIdxEntity_ObjCProperty  = 11,
  CXIdxEntity_ObjCIvar      = 12,
  CXIdxEntity_Enum          = 13,
  CXIdxEntity_Struct        = 14,
  CXIdxEntity_Union         = 15,
  CXIdxEntity_CXXClass              = 16,
  CXIdxEntity_CXXNamespace          = 17,
  CXIdxEntity_CXXNamespaceAlias     = 18,
  CXIdxEntity_CXXStaticVariable     = 19,
  CXIdxEntity_CXXStaticMethod       = 20,
  CXIdxEntity_CXXInstanceMethod     = 21,
  CXIdxEntity_CXXConstructor        = 22,
  CXIdxEntity_CXXDestructor         = 23,
  CXIdxEntity_CXXConversionFunction = 24,
  CXIdxEntity_CXXTypeAlias          = 25,
  CXIdxEntity_CXXInterface          = 26
} CXIdxEntityKind;
typedef enum {
  CXIdxEntityLang_None = 0,
  CXIdxEntityLang_C    = 1,
  CXIdxEntityLang_ObjC = 2,
  CXIdxEntityLang_CXX  = 3,
  CXIdxEntityLang_Swift  = 4
} CXIdxEntityLanguage;
typedef enum {
  CXIdxEntity_NonTemplate   = 0,
  CXIdxEntity_Template      = 1,
  CXIdxEntity_TemplatePartialSpecialization = 2,
  CXIdxEntity_TemplateSpecialization = 3
} CXIdxEntityCXXTemplateKind;
typedef enum {
  CXIdxAttr_Unexposed     = 0,
  CXIdxAttr_IBAction      = 1,
  CXIdxAttr_IBOutlet      = 2,
  CXIdxAttr_IBOutletCollection = 3
} CXIdxAttrKind;
typedef struct {
  CXIdxAttrKind kind;
  CXCursor cursor;
  CXIdxLoc loc;
} CXIdxAttrInfo;
typedef struct {
  CXIdxEntityKind kind;
  CXIdxEntityCXXTemplateKind templateKind;
  CXIdxEntityLanguage lang;
  const char *name;
  const char *USR;
  CXCursor cursor;
  const CXIdxAttrInfo *const *attributes;
  unsigned numAttributes;
} CXIdxEntityInfo;
typedef struct {
  CXCursor cursor;
} CXIdxContainerInfo;
typedef struct {
  const CXIdxAttrInfo *attrInfo;
  const CXIdxEntityInfo *objcClass;
  CXCursor classCursor;
  CXIdxLoc classLoc;
} CXIdxIBOutletCollectionAttrInfo;
typedef enum {
  CXIdxDeclFlag_Skipped = 0x1
} CXIdxDeclInfoFlags;
typedef struct {
  const CXIdxEntityInfo *entityInfo;
  CXCursor cursor;
  CXIdxLoc loc;
  const CXIdxContainerInfo *semanticContainer;

  const CXIdxContainerInfo *lexicalContainer;
  int isRedeclaration;
  int isDefinition;
  int isContainer;
  const CXIdxContainerInfo *declAsContainer;

  int isImplicit;
  const CXIdxAttrInfo *const *attributes;
  unsigned numAttributes;
  unsigned flags;
} CXIdxDeclInfo;
typedef enum {
  CXIdxObjCContainer_ForwardRef = 0,
  CXIdxObjCContainer_Interface = 1,
  CXIdxObjCContainer_Implementation = 2
} CXIdxObjCContainerKind;
typedef struct {
  const CXIdxDeclInfo *declInfo;
  CXIdxObjCContainerKind kind;
} CXIdxObjCContainerDeclInfo;
typedef struct {
  const CXIdxEntityInfo *base;
  CXCursor cursor;
  CXIdxLoc loc;
} CXIdxBaseClassInfo;
typedef struct {
  const CXIdxEntityInfo *protocol;
  CXCursor cursor;
  CXIdxLoc loc;
} CXIdxObjCProtocolRefInfo;
typedef struct {
  const CXIdxObjCProtocolRefInfo *const *protocols;
  unsigned numProtocols;
} CXIdxObjCProtocolRefListInfo;
typedef struct {
  const CXIdxObjCContainerDeclInfo *containerInfo;
  const CXIdxBaseClassInfo *superInfo;
  const CXIdxObjCProtocolRefListInfo *protocols;
} CXIdxObjCInterfaceDeclInfo;
typedef struct {
  const CXIdxObjCContainerDeclInfo *containerInfo;
  const CXIdxEntityInfo *objcClass;
  CXCursor classCursor;
  CXIdxLoc classLoc;
  const CXIdxObjCProtocolRefListInfo *protocols;
} CXIdxObjCCategoryDeclInfo;
typedef struct {
  const CXIdxDeclInfo *declInfo;
  const CXIdxEntityInfo *getter;
  const CXIdxEntityInfo *setter;
} CXIdxObjCPropertyDeclInfo;
typedef struct {
  const CXIdxDeclInfo *declInfo;
  const CXIdxBaseClassInfo *const *bases;
  unsigned numBases;
} CXIdxCXXClassDeclInfo;
typedef enum {

  CXIdxEntityRef_Direct = 1,

  CXIdxEntityRef_Implicit = 2
} CXIdxEntityRefKind;
typedef enum {
  CXSymbolRole_None = 0,
  CXSymbolRole_Declaration = 1 << 0,
  CXSymbolRole_Definition = 1 << 1,
  CXSymbolRole_Reference = 1 << 2,
  CXSymbolRole_Read = 1 << 3,
  CXSymbolRole_Write = 1 << 4,
  CXSymbolRole_Call = 1 << 5,
  CXSymbolRole_Dynamic = 1 << 6,
  CXSymbolRole_AddressOf = 1 << 7,
  CXSymbolRole_Implicit = 1 << 8
} CXSymbolRole;
typedef struct {
  CXIdxEntityRefKind kind;

  CXCursor cursor;
  CXIdxLoc loc;

  const CXIdxEntityInfo *referencedEntity;

  const CXIdxEntityInfo *parentEntity;

  const CXIdxContainerInfo *container;

  CXSymbolRole role;
} CXIdxEntityRefInfo;
typedef struct {

  int (*abortQuery)(CXClientData client_data, void *reserved);

  void (*diagnostic)(CXClientData client_data,
                     CXDiagnosticSet, void *reserved);
  CXIdxClientFile (*enteredMainFile)(CXClientData client_data,
                                     CXFile mainFile, void *reserved);

  CXIdxClientFile (*ppIncludedFile)(CXClientData client_data,
                                    const CXIdxIncludedFileInfo *);

  CXIdxClientASTFile (*importedASTFile)(CXClientData client_data,
                                        const CXIdxImportedASTFileInfo *);

  CXIdxClientContainer (*startedTranslationUnit)(CXClientData client_data,
                                                 void *reserved);
  void (*indexDeclaration)(CXClientData client_data,
                           const CXIdxDeclInfo *);

  void (*indexEntityReference)(CXClientData client_data,
                               const CXIdxEntityRefInfo *);
} IndexerCallbacks;
 int clang_index_isEntityObjCContainerKind(CXIdxEntityKind);
 const CXIdxObjCContainerDeclInfo *
clang_index_getObjCContainerDeclInfo(const CXIdxDeclInfo *);
 const CXIdxObjCInterfaceDeclInfo *
clang_index_getObjCInterfaceDeclInfo(const CXIdxDeclInfo *);
const CXIdxObjCCategoryDeclInfo *
clang_index_getObjCCategoryDeclInfo(const CXIdxDeclInfo *);
 const CXIdxObjCProtocolRefListInfo *
clang_index_getObjCProtocolRefListInfo(const CXIdxDeclInfo *);
 const CXIdxObjCPropertyDeclInfo *
clang_index_getObjCPropertyDeclInfo(const CXIdxDeclInfo *);
 const CXIdxIBOutletCollectionAttrInfo *
clang_index_getIBOutletCollectionAttrInfo(const CXIdxAttrInfo *);
 const CXIdxCXXClassDeclInfo *
clang_index_getCXXClassDeclInfo(const CXIdxDeclInfo *);
 CXIdxClientContainer
clang_index_getClientContainer(const CXIdxContainerInfo *);
 void
clang_index_setClientContainer(const CXIdxContainerInfo *,CXIdxClientContainer);
 CXIdxClientEntity
clang_index_getClientEntity(const CXIdxEntityInfo *);
 void
clang_index_setClientEntity(const CXIdxEntityInfo *, CXIdxClientEntity);
typedef void *CXIndexAction;
 CXIndexAction clang_IndexAction_create(CXIndex CIdx);
 void clang_IndexAction_dispose(CXIndexAction);
typedef enum {

  CXIndexOpt_None = 0x0,

  CXIndexOpt_SuppressRedundantRefs = 0x1,

  CXIndexOpt_IndexFunctionLocalSymbols = 0x2,

  CXIndexOpt_IndexImplicitTemplateInstantiations = 0x4,

  CXIndexOpt_SuppressWarnings = 0x8,

  CXIndexOpt_SkipParsedBodiesInSession = 0x10
} CXIndexOptFlags;
 int clang_indexSourceFile(CXIndexAction,
                                         CXClientData client_data,
                                         IndexerCallbacks *index_callbacks,
                                         unsigned index_callbacks_size,
                                         unsigned index_options,
                                         const char *source_filename,
                                         const char * const *command_line_args,
                                         int num_command_line_args,
                                         struct CXUnsavedFile *unsaved_files,
                                         unsigned num_unsaved_files,
                                         CXTranslationUnit *out_TU,
                                         unsigned TU_options);
 int clang_indexSourceFileFullArgv(
    CXIndexAction, CXClientData client_data, IndexerCallbacks *index_callbacks,
    unsigned index_callbacks_size, unsigned index_options,
    const char *source_filename, const char *const *command_line_args,
    int num_command_line_args, struct CXUnsavedFile *unsaved_files,
    unsigned num_unsaved_files, CXTranslationUnit *out_TU, unsigned TU_options);
 int clang_indexTranslationUnit(CXIndexAction,
                                              CXClientData client_data,
                                              IndexerCallbacks *index_callbacks,
                                              unsigned index_callbacks_size,
                                              unsigned index_options,
                                              CXTranslationUnit);
 void clang_indexLoc_getFileLocation(CXIdxLoc loc,
                                                   CXIdxClientFile *indexFile,
                                                   CXFile *file,
                                                   unsigned *line,
                                                   unsigned *column,
                                                   unsigned *offset);
CXSourceLocation clang_indexLoc_getCXSourceLocation(CXIdxLoc loc);
typedef enum CXVisitorResult (*CXFieldVisitor)(CXCursor C,
                                               CXClientData client_data);
 unsigned clang_Type_visitFields(CXType T,
                                               CXFieldVisitor visitor,
                                               CXClientData client_data);
	]==========]
return {}
