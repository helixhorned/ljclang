s/@DISTRO_IMAGE@/alpine:3.12.0/g
s/@adduser@/adduser -D/g
s/@install@/apk add/g
s/@luarocks@/luarocks-5.1/g
s/$pkg_libc_dev/libc-dev/g
s/$pkg_libclang_dev/clang-dev/g
s/$pkg_luarocks/luarocks5.1/g
s/$pkg_liblua51_dev/lua5.1-dev/g
