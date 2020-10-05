#!/bin/sh

# Obtained with:
#  $ luarocks path | sed -r "s|;(/[^h]\|[^/])[^;']*||g"
# This assumes that the 'busted' Lua unit test framework has been installed like this:
#  $ luarocks --local install busted
LUA_PATH="$HOME/.luarocks/share/lua/5.1/?.lua;$HOME/.luarocks/share/lua/5.1/?/init.lua"
LUA_CPATH="$HOME/.luarocks/lib/lua/5.1/?.so"

d=`pwd`
LUA_PATH=";;$d/?.lua;$LUA_PATH"
LD_LIBRARY_PATH="$LLVM_LIBDIR:$d"

if [ -z "$LLVM_LIBDIR" ]; then
    echo "ERROR: Must pass 'LLVM_LIBDIR'"
    exit 1
fi

export LUA_PATH LUA_CPATH LD_LIBRARY_PATH

luajit "$d/tests.lua" "$@"
