#!/bin/bash

set -e

# NOTE: this program expects an environment suitable for running:
EXTRACTDECLS=./extractdecls.lua
extractdecls="$(realpath -e $EXTRACTDECLS)"

inFile="$1"

function usageAndExit() {
    echo
    echo "Usage: $0 <template-file>"
    echo "  Reads the template file line by line, copying each one to stdout"
    echo "  except those starting with '@@', who are taken as arguments to $EXTRACTDECLS"
    echo "  which is then run and on success, its output is substituted for the '@@' line."
    echo "  On the first error from $EXTRACTDECLS, exits with the same exit code as it."
    echo
    exit 1
}

if [ -z "$inFile" ]; then
    usageAndExit
fi

exec {resultFd}< "$inFile"

while IFS='' read -r -u $resultFd line; do
    if [ x"${line:0:2}" == x'@@' ]; then
        args="${line:2}"
        "$extractdecls" $args
    else
        echo -E "$line"
    fi
done
