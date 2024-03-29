#!/bin/bash

set -e

# NOTE: this program expects an environment suitable for running:
extractdecls=${LJCLANG_EXTRACTDECLS:-./extractdecls.lua}
test -x "$extractdecls" || \
    (echo "ERROR: '$extractdecls' not found or not executable." >&2 && exit 1)

inFile="$1"

function usageAndExit() {
    echo
    echo "Usage: $0 <template-file> [arguments-to-extractdecls...]"
    echo "  Reads the template file line by line, copying each one to stdout"
    echo "  except those starting with '@@', who are taken as arguments to $extractdecls"
    echo "  which is then run and on success, its output is substituted for the '@@' line."
    echo "  The trailing arguments from the command line are likewise passed to $extractdecls,"
    echo "  after the ones from the template file."
    echo "  On the first error from $extractdecls, exits with the same exit code as it."
    echo
    exit 1
}

if [ -z "$inFile" ]; then
    usageAndExit
fi

shift

if grep '\\.' "$inFile"; then
    # We allow line continuations, but disallow any other use of the backslash because
    # 'read' without '-r' would not retain them.
    echo "ERROR: in $inFile, found backslash not at the end of a line." >&2
    exit 2
fi

exec {resultFd}< "$inFile"

while IFS='' read -u $resultFd line; do
    if [ x"${line:0:2}" == x'@@' ]; then
        args="${line:2}"
        "$extractdecls" $args "$@"
    else
        echo -E "$line"
    fi
done
