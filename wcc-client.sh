#!/bin/bash

TEMPDIR=/tmp/ljclang

pid=$$
FIFO=$TEMPDIR/wcc-client-${pid}.fifo

REQUEST_SINK=$TEMPDIR/wcc-request.sink

## Usage

function usage()
{
    echo "Usage:"
    echo " $0 check [<command> [command options...]]"
    echo "   Validate client invocation (and optionally, the well-formedness"
    echo "   of the command and its arguments)."
    echo " $0 [-n] <command> [command options...]"
    echo "   Send command to be processed by the watch_compile_commands server."
    echo ""
    echo "Recognized options:"
    echo "  '-n': exit immediately after sending the command."
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

if [ x"$1" == x"check" ]; then
    # Output *something* as a workaround for the fact wrapping Emacs's
    # (process-lines) in (with-demoted-errors) was not successful.
    echo "OK"
    exit 0
fi

## Handle the command

if [ $block == yes ]; then
    # The FIFO must *first* be opened for reading: the server opens it with
    # O_NONBLOCK | O_WRONLY, thus failing with ENXIO otherwise.
    # Also, dummy-open it for writing because otherwise we would hang (chicken & egg).
    exec {resultFd}<> "$FIFO"

    # Send the command, informing the server of our ID.
    echo -E $pid "$cmdLine" >> "$REQUEST_SINK"

    # Read the server's acknowledgement of the request receival, waiting for merely a
    # second. (The expectation is that the server sends the acknowledgement immediately.)
    read -rs -N 3 -u ${resultFd} -t 1.0 ack

    if [ $? -gt 128 ]; then
        echo "ERROR: receival of the request acknowledgement timed out."
        exit 100
    elif [ x"$ack" != x"ACK" ]; then
        echo "ERROR: malformed acknowledgement message."
        exit 101
    fi

    # Read the success status of the request, waiting for a bit longer.
    #
    # TODO: elaborate timing expectations/requirements (e.g. it may be OK for the server to
    #  delay a computation until the respective compile command has been processed).
    read -rs -N 3 -u ${resultFd} -t 10.0 res

    if [ $? -gt 128 ]; then
        echo "ERROR: timed out waiting for the result."
        exit 110
    elif [[ x"$res" != x"rOK" && x"$res" != x"rER" ]]; then
        echo "ERROR: malformed success status message."
        exit 111
    fi

    if [ "$res" == rER ]; then
        echo -n "remote: ERROR: "
    fi

    # The server has sent all data (2 items of header data checked above and the payload) in
    # a single write(). Hence, we can read in a loop with timeout 0 (meaning, to check for
    # data availability) at the outer level.
    #
    # The background of doing it this way is that attempts to plainly read it from bash or
    # using /bin/cat led to the read *hanging*, even if 'resultFd' was previously closed.
    # [In the /bin/cat case, that is; in the 'read' builtin case, the distinction of closing
    #  "for reading" or "for writing" ('<&-' or '>&-', respectively) seems to be merely
    #  decorative: in either case, the *single* previously open file descriptor is closed].
    #
    # NOTE: There could be data lost if the total message size exceeds 'PIPE_BUF' bytes (in
    #  which case the OS is allowed to split up the message, see POSIX).
    # TODO: detect data loss?

    readArgs=(-rs -u ${resultFd})

    while read ${readArgs[@]} -t 0 data_available_check_; do
        read ${readArgs[@]} -t 0.1 line
        # NOTE: do not guard against 'line' being '-n', '-e' or '-E' (options to 'echo').
        echo "$line"
    done

    if [ "$res" == rER ]; then
        exit 200
    fi
else
    # Send the command as an anonymous request.
    echo -E - "$cmdLine" >> "$REQUEST_SINK"
fi
