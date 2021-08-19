s/@DISTRO_IMAGE@/debian:buster-20210511/g
s!@DO_update_packages@!RUN apt update > /tmp/apt-update.log \&\& grep -v -q '^\(E:\|Err:\|W:\)' /tmp/apt-update.log!g
s/@adduser@/adduser --disabled-password/g
s/@install@/DEBIAN_FRONTEND=noninteractive apt install -y/g
s/@luarocks@/luarocks/g
s/$pkg_libc_dev/libc6-dev/g
s/$pkg_libclang_dev/libclang-7-dev/g;  # Ancient, but let's give it a try
s/$pkg_luarocks/luarocks/g
s/$pkg_liblua51_dev/liblua5.1-0-dev/g
s/@llvm_version@/7.0.1/g
s|@llvm_incdir@|/usr/lib/llvm-7/include|g
s|@llvm_libdir@|/usr/lib/llvm-7/lib|g
s/@SHELL@/bash/g
