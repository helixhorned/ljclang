
LJClang -- A LuaJIT-based interface to libclang
===============================================

### Table of Contents

**[Introduction](#introduction)**\
**[Requirements](#requirements)**\
**[Building](#building)**\
**[Overview](#overview)**\
**[Example programs](#example-programs)**\
**[Reference](#reference)**\
**[License](#license)**


Introduction
------------

[LuaJIT]: https://luajit.org/
[libclang]: https://clang.llvm.org/doxygen/group__CINDEX.html
[luaclang-parser]: https://github.com/mkottman/luaclang-parser

LJClang is an interface to [libclang] for [LuaJIT], modeled after and mostly
API-compatible with [luaclang-parser] by Michal Kottman.


Requirements
------------

* LuaJIT 2.0 or greater

* LLVM/Clang -- from the Linux distribution or
  [here](https://apt.llvm.org/). Development is done using the latest stable
  version, but older versions should work mostly fine (except that interfaces
  exposed by newer version are not available, of course).


Building
--------

Invoking `make` builds the required support library `libljclang_support.so`,
converts libclang C headers into a form that can be used by LuaJIT (using a Lua
program that essentially strips text that would not be understood by LuaJIT's
`ffi.cdef`) and finally extracts additional information using LJClang itself.

The file `config.make` contains some user-facing configuration.


Overview
--------

LJClang provides a cursor-based, callback-driven API to the abstract syntax
tree (AST) of C/C++ source files. These are the main classes:

* `Index` -- represents a set of translation units that could be linked together
* `TranslationUnit` -- a source file together with everything included by it
  either directly or transitively
* `Cursor` -- points to an element in the AST in a translation unit such as a
  `typedef` declaration or a statement
* `Type` -- the type of an element (for example, that of a variable, structure
  member, or a function's input argument or return value)

To make something interesting happen, you usually create a single `Index`
object, parse into it one or more translation units, and define a callback
function to be invoked on each visit of a `Cursor` by libclang.


Example programs
----------------

### `extractdecls.lua`

[`enum CXCursorKind`]:
 https://clang.llvm.org/doxygen/group__CINDEX.html#gaaccc432245b4cd9f2d470913f9ef0013

The `extractdecls.lua` script accompanied by LJClang can be used to extract
various kinds of C declarations from (usually) headers and print them in
various forms usable as FFI C declarations or descriptive tables with LuaJIT.

~~~~~~~~~~
Usage: extractdecls.lua [our options...] <file.h> [-- [Clang command line args ...]]
Exits with a non-zero code if there were errors or no match, or if filter
patterns (-p) were provided and not all of them produced matches.
 (Our options may also come after the file name.)
  -e <enumNameFilterPattern> (enums only)
  -p <filterPattern1> [-p <filterPattern2>] ... (logically OR'd)
  -x <excludePattern1> [-x <excludePattern2>] ...  (logically OR'd)
  -s <stripPattern>
  -1 <string to print before everything>
  -2 <string to print after everything>
  -A <single Clang command line arg> (same as if specified as positional arg)
  -C: print lines like
       static const int membname = 123;  (enums/macros only)
  -R: reverse mapping, only if one-to-one. Print lines like
       [123] = \"membname\";  (enums/macros only)
  -m <extraction-spec-module>: name of a Lua module to 'require()' which should return a
     function taking the LJClang cursor as a first argument and a table of strings collected
     from the -a option instances as the second argument. In the context of the call to
     'require()' and the module function, the functions 'check' and 'printf' are available.
     The function 'printf' must not be called at module load time.
     Incompatible with -1, -2, -C, -R, -f and -w.
  -a <argument1> [-a <argument2>] ...: arguments passed to the <extraction-spec-module>
     as a table.
     Can only be used with -m.
  -f <formatFunc>: user-provided body for formatting function (enums/macros only)
       Arguments to that function are named
         * 'k' (enum constant / macro name)
         * 'v' (its numeric value)
         * 'enumName' (the name in 'enum <name>', or the empty string)
         * 'enumIntTypeName' (the name of the underlying integer type of an enum)
         * 'enumPrefixLength' (the length of the common prefix of all names; enums only)
       Also, the following is provided:
         * 'f' as a shorthand for 'string.format'
       Must return a formatted line.
       Example:
         "return f('%s = %s%s,', k, k:find('KEY_') and '65536+' or '', v)"
       Incompatible with -C, -R or -f.
  -Q: be quiet
  -w: extract what? Can be
       E+M, EnumConstantDecl (default), MacroDefinition, TypedefDecl, FunctionDecl

~~~~~~~~~~

In fact, the file `ljclang_cursor_kind.lua` is generated by this program and is
used by LJClang to map values of the enumeration [`enum CXCursorKind`] to their
names. The `bootstrap` target in the `Makefile` extracts the relevant
information using these options:

~~~~~~~~~~
-Q -R -e 'CXCursorKind' -p '^CXCursor_' -s '^CXCursor_' \
    -x '_First' -x '_Last' -x '_GCCAsmStmt' -x '_MacroInstantiation' \
    -1 'CursorKindName = {' -2 '},'
~~~~~~~~~~


Thus, the enum constant names are filtered to be taken from `enum CXCursorKind`,
beginning with `CXCursor_` (that prefix being stripped) and all "secondary" names
aliasing the one considered the main one are rejected. (For example,
`CXCursor_AsmStmt` and `CXCursor_GCCAsmStmt` have the same value.) This yields
lines like

~~~~~~~~~~
[215] = "AsmStmt";
~~~~~~~~~~

### `watch_compile_commands.lua`

~~~~~~~~~~
Usage:
   watch_compile_commands.lua [options...] <compile_commands-file>

In this help text, single quotes ("'") are for exposition purposes only.
They are never to be spelled in actual option arguments.

Options:
  -a: Enable automatic generation and usage of precompiled headers. For each PCH configuration
      (state of relevant compiler options) meeting a certain threshold of compile commands that
      it is used with, a PCH file is generated that includes all standard library headers.
      Note that this will remove errors due to forgetting to include a standard library header.
      Only supported for C++11 upwards.
      Precompiled headers are stored in '$HOME/.cache/ljclang'.
  -c <concurrency>: set number of parallel parser invocations. (Minimum: 1)
     'auto' means use hardware concurrency (the default).
  -i <severity-spec>: Enable incremental mode. Stop processing further compile commands on the first
     diagnostic matching the severity specification. Its syntax one of:
      1. a comma-separated list, <severity>(,<severity>)*
         where each <severity> is one of 'note', 'warning', 'error' or 'fatal'.
      2. a single severity suffixed by '+', meaning to select the specified severity
         and more serious ones.
     As a convenience, the specification can also be '-', meaning 'error+'.
  -g [includes|isIncludedBy]: Print inclusion graph as a DOT (of Graphviz) file to stdout and exit.
     Argument specifies the relation between graph nodes (which are file names).
  -l <number>: edge count limit for the graph produced by -g isIncludedBy.
     If exceeded, a placeholder node is placed.
  -r [c<commands>|<seconds>s]: report progress after the specified number of
     processed compile commands or the given time interval.
     Specifying any of 'c0', 'c1' or '0s' effectively prints progress with each compile command.
  -s [-]<selector1> [-s [-]<selector2> ...]: Select compile command(s) to process.
     Selectors are processed in the order they appear on the command line. Each selector can
     be prefixed by '-', which means to remove the matching set of compile commands from the
     current set. If a removal appears first, the initial set contains all compile commands,
     otherwise it is empty.
     Each <selector> can be one of:
      - '@...': by index (see below).
      - '{<pattern>}': by Lua pattern matching the absolute file name in a compile command.
  -N: Print all diagnostics. This disables omission of:
      - diagnostics that follow a Parse Issue error, and
      - diagnostics that were seen in previous compile commands.
  -P: Disable color output.
  -v: Be verbose. Currently: output compiler invocations for Auto-PCH generation failures.
  -x: exit after parsing and displaying diagnostics once.

  If the selector to an option -s starts with '@', it must have one of the following forms,
  where the integral <number> starts with a decimal digit distinct from zero:
    - '@<number>': single compile command, or
    - '@<number>..': range starting with the specified index, or
    - '@<number>..<number>': inclusive range.
~~~~~~~~~~


Reference
---------

The module returned by `require("ljclang")` -- called `clang` from here on --
contains the following:

#### `index = clang.createIndex([excludeDeclarationsFromPCH [, displayDiagnostics]])`

[`clang_createIndex`]:
 http://clang.llvm.org/doxygen/group__CINDEX.html#ga51eb9b38c18743bf2d824c6230e61f93

Binding for [`clang_createIndex`]. Will create an `Index` into which you can
parse `TranslationUnit`s. Both input arguments are optional and default to
**false**.

#### `clang.ChildVisitResult`

[`enum CXChildVisitResult`]:
 https://clang.llvm.org/doxygen/group__CINDEX__CURSOR__TRAVERSAL.html#ga99a9058656e696b622fbefaf5207d715

An object mapping names to values to be returned
from cursor visitor callbacks. The names are identical with those in [`enum
CXChildVisitResult`] with the "`CXChildVisit_`" prefix removed: `Break`,
`Continue`, `Recurse`.

#### `visitorHandle = clang.regCursorVisitor(visitorFunc)`

Registers a child visitor callback function `visitorFunc` with LJClang,
returning a handle which can be passed to `Cursor:children()`. The callback
function receives two input arguments, `(cursor, parent)` -- with the cursors
of the currently visited entity as well as its parent, and must return a value
from the `ChildVisitResult` enumeration to indicate whether or how libclang
should carry on AST visiting.

CAUTION: The `cursor` passed to the visitor callback is only valid during one
particular callback invocation. If it is to be used after the function has
returned, it **must** be copied using the `Cursor` constructor mentioned below.

#### `permanentCursor = clang.Cursor(cursor)`

Creates a permanent cursor from one received by the visitor callback.

#### `clang.ErrorCode`

[`enum CXErrorCode`]:
 https://clang.llvm.org/doxygen/CXErrorCode_8h.html#adba17f287f8184fc266f2db4e669bf0f

An object mapping names to values representing success or various
error conditions. The names are identical to those in [`enum CXErrorCode`] with
the "`CXError_`" prefix removed.

### Index

#### `translationUnit, errorCode = index:parse(sourceFileName, cmdLineArgs [, opts])`

[`clang_parseTranslationUnit2`]:
 http://clang.llvm.org/doxygen/group__CINDEX__TRANSLATION__UNIT.html#ga494de0e725c5ae40cbdea5fa6081027d

[`CXTranslationUnit_*`]:
 http://clang.llvm.org/doxygen/group__CINDEX__TRANSLATION__UNIT.html#enum-members

Binding for [`clang_parseTranslationUnit2`]. This will parse a given source
file named `sourceFileName` with the command line arguments `cmdLineArgs` given
to the compiler, containing e.g. include paths or defines. If `sourceFile` is
the empty string, the source file is expected to be named in `cmdLineArgs`.

The optional argument `opts` is expected to be a sequence containing
[`CXTranslationUnit_*`] enum names without the `"CXTranslationUnit_"` prefix,
for example `{ "DetailedPreprocessingRecord", "SkipFunctionBodies" }`.

NOTE: Both `cmdLineArgs` and `opts` (if given) must not contain an element at index 0.

On failure, `translationUnit` is `nil` and `errorCode` (comparable against
values in `clang.ErrorCode`) can be examined.


License
-------

Copyright (C) 2013-2020 Philipp Kutin. MIT licensed. See LICENSE for details.
