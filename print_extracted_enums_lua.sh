#!/bin/bash

if [ -z "$incdir" ]; then
    echo 'need $incdir'
    exit 1
fi

# NOTE: this script has not been tested with $incdir containing whitespace.

EXTRACT_OPTS_KINDS=(-w 'EnumConstantDecl' -Q -R -e 'CXCursorKind' -p '^CXCursor_' -s '^CXCursor_'
 -x '_First' -x '_Last' -x '_GCCAsmStmt' -x '_MacroInstantiation'
 -1 'CursorKindName = {' -2 '},')

EXTRACT_OPTS_ENUM_COMMON=(-Q
 -f "return f('    static const int %s = %s;', k:sub(enumPrefixLength+1), k)")

# NOTE: update counter in loop below when adding enums
ENUM_NAMES=(ErrorCode SaveError DiagnosticSeverity ChildVisitResult RefQualifierKind)

EXTRACT_CMD=(./extractdecls.lua -A -I"${incdir}")

##########

echo 'local ffi=require"ffi"'
echo 'return {'

# Enums
for i in {0..4}; do
    ourEnumName=${ENUM_NAMES[i]}
    cEnumName=CX${ourEnumName}

    if [ $i -eq 0 ]; then
        # It seems that starting with Clang 7, the translation unit does not contain the
        # #include'd portion any more. Therefore, use the file containing 'enum CXErrorCode'
        # manually.
        headerFile=CXErrorCode.h
    else
        headerFile=Index.h
    fi

    "${EXTRACT_CMD[@]}" "${incdir}"/clang-c/$headerFile "${EXTRACT_OPTS_ENUM_COMMON[@]}" \
        -e "^${cEnumName}$" \
        -1 "${ourEnumName} = ffi.new[[struct{" -2 "}]],"
done

# Cursor kinds
"${EXTRACT_CMD[@]}" "${incdir}"/clang-c/Index.h "${EXTRACT_OPTS_KINDS[@]}"

echo '}'
