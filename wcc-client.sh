#!/bin/bash

TEMPDIR=/tmp/ljclang

pid=$$
FIFO=$TEMPDIR/wcc-client-${pid}.fifo

REQUEST_SINK=$TEMPDIR/wcc-request.sink

## Usage

function usage()
{
    echo "Usage: $0 [-n] <command> [command options...]"
    echo " Send command to be processed by the watch_compile_commands server."
    echo ""
    echo "Recognized options:"
    echo " '-n': exit immediately after sending the command."
    exit 1
}

block=yes

if [ x"$1" = x-n ]; then
    block=no
    shift
fi

if [ ${#@} -eq 0 ]; then
    usage
fi

## Setup

function cleanup()
{
    rm "$FIFO"
}

function setup()
{
    if [ ! -w "$REQUEST_SINK" ]; then
        echo "ERROR: $REQUEST_SINK does not exist or is not writable."
        echo " Is wcc-server running?"
        exit 3
    fi

    if [ $block == yes ]; then
        mkfifo "$FIFO" || exit 1
        trap cleanup EXIT
    fi
}

# Validate the command
# NOTE: if this part becomes more complex, it may be reasonable to implement it in Lua.

args=("$@")
numArgs=${#args[@]}

for ((i=0; i < $numArgs; i++)); do
    arg="${args[i]}"

    if [[ "$arg" =~ [[:space:][:cntrl:]] ]]; then
        echo "ERROR: command and arguments must not contain space or control characters."
        exit 2
    fi

    if [[ "$arg" =~ ^-[Een]+$ ]]; then
        # -E, -e and -n are the *only* three options interpreted by Bash's builtin 'echo'.
        # But, they may be passed "compacted" to be interpreted. (E.g. '-En'.)
        # Other combinations are not interpreted: the argument is just printed out as is.
        #  Examples:
        #   -Ena  (-E and -n are special, but the 'a' makes the whole string non-special)
        #   -qwe  (does not contain special characters at all)
        echo "ERROR: command and arguments must not match extended regexp '^-[Een]+$'."
        exit 2
    fi
done

cmdLine="$@"

setup

## Send the command

if [ $block == yes ]; then
    # The FIFO must *first* be opened for reading: the server opens it with
    # O_NONBLOCK | O_WRONLY (thus failing with ENXIO otherwise).

    # Start background process to get and print the result sent by the server.
    /bin/cat "$FIFO" &

    # FIXME: the above is still not adequate and the sleep "solution" is of course a hack.
    #  Since the background process runs asynchronously, we now have a race. This seems like
    #  a sufficient reason to implement this in Lua. (Then, using O_NONBLOCK for
    #  read-opening the FIFO, sending the request, and then poll().)
    sleep 0.1

    echo -E $pid "$cmdLine" >> "$REQUEST_SINK"

    # Wait for the background process to finish.
    # NOTE: if the server terminates before closing the FIFO on its side, this will hang.
    wait
else
    echo -E - "$cmdLine" >> "$REQUEST_SINK"
fi
