s/@DISTRO_IMAGE@/ubuntu:focal-20201008/g
s!@DO_update_packages@!RUN apt update > /tmp/apt-update.log \&\& grep -v -q '^\(E:\|Err:\|W:\)' /tmp/apt-update.log!g
s/@adduser@/adduser --disabled-password/g
s/@install@/DEBIAN_FRONTEND=noninteractive apt install -y/g
s/@luarocks@/luarocks/g
s/$pkg_libc_dev/libc6-dev/g
s/$pkg_libclang_dev/libclang-10-dev/g
s/$pkg_luarocks/luarocks/g
s/$pkg_liblua51_dev/liblua5.1-0-dev/g
s/@llvm_version@/10.0.0/g
s|@llvm_incdir@|/usr/lib/llvm-10/include|g
s|@llvm_libdir@|/usr/lib/llvm-10/lib|g
s/@SHELL@/bash/g
