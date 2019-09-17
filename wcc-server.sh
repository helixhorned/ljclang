#!/bin/bash

TEMPDIR=/tmp/ljclang

pid=$$
FIFO=$TEMPDIR/wcc-${pid}-request.sink

FIFO_LINK_BASENAME=wcc-request.sink
FIFO_LINK=$TEMPDIR/$FIFO_LINK_BASENAME
link_status=1

function cleanup()
{
    echo "Removing $FIFO"
    rm "$FIFO"

    if [ $link_status -eq 0 ]; then
        echo "Removing $FIFO_LINK"
        rm "$FIFO_LINK"
    fi
}

if [ ${#@} -ne 0 ]; then
    mkdir -p "$TEMPDIR" || exit 1

    mkfifo "$FIFO" || exit 1
    echo "Server: created FIFO $FIFO"

    ln -s -T "$FIFO" "$FIFO_LINK"
    link_status=$?

    if [ $link_status -eq 0 ]; then
        echo "Server: created symlink $FIFO_LINK"
    fi

    trap cleanup EXIT
fi

watch_compile_commands -m "$FIFO" "$@"
