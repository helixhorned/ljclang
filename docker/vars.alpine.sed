s/@DISTRO_IMAGE@/alpine:3.14.1/g
s/@DO_update_packages@//g
s/@adduser@/adduser -D/g
s/@install@/apk add/g
s/@luarocks@/luarocks-5.1/g
s/$pkg_libc_dev/libc-dev/g
s/$pkg_libclang_dev/clang-dev/g
s/$pkg_luarocks/luarocks5.1/g
s/$pkg_liblua51_dev/lua5.1-dev/g
s/@llvm_version@/11.1.0/g
s|@llvm_incdir@|/usr/include|g
s|@llvm_libdir@|/does-not-exist-and-not-relevant-here|g
s/@SHELL@/sh/g
