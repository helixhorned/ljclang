// Support library for POSIX functionality.
// Copyright (C) 2013-2020 Philipp Kutin
// See LICENSE for license information.

#define _LARGEFILE64_SOURCE 1
#include <sys/select.h>
#include <dirent.h>
#include <signal.h>

// ---------- fd_set ----------

// TODO: we could also check assumptions here and implement the functions in Lua.

void ljclang_FD_CLR(int fd, fd_set *set) {
    FD_CLR(fd, set);
}

int  ljclang_FD_ISSET(int fd, fd_set *set) {
    return FD_ISSET(fd, set);
}

void ljclang_FD_SET(int fd, fd_set *set) {
    FD_SET(fd, set);
}

// NOTE: we do not expose FD_ZERO().
// We just assume that it is the same as zeroing its bytes.
// See
//  - glibc on Ubuntu/Raspbian: /usr/include/<triple>/bits/select.h
//  - musl on Alpine: /usr/include/sys/select.h

const char *ljclang_getDirent64Name(const struct dirent64 *dirent) {
    return dirent ? dirent->d_name : "";
}

void ljclang_setSigintHandlingToDefault()
{
    signal(SIGINT, SIG_DFL);
}
