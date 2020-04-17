// Support library for POSIX functionality.
// Copyright (C) 2013-2020 Philipp Kutin
// See LICENSE for license information.

#include <sys/select.h>
#include <dirent.h>
#include <poll.h>
#include <signal.h>

extern "C" {
// ---------- fd_set ----------

static_assert(FD_SETSIZE == 8 * sizeof(fd_set));

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
// See /usr/include/<triple>/bits/select.h

}  // extern "C"

namespace {
namespace Check {

struct timeval {
    time_t sec;
    suseconds_t usec;
};

struct timespec {
    time_t sec;
    long   nsec;
};

struct pollfd {
    int   fd;
    short events;
    short revents;
};

}
}

// Check that on our system, the structs we want to expose include *only* the members
// specified by POSIX.
// TODO: move to posix_types.lua
static_assert(sizeof(Check::timeval) == sizeof(struct timeval));
static_assert(sizeof(Check::timespec) == sizeof(struct timespec));
static_assert(sizeof(Check::pollfd) == sizeof(struct pollfd));

extern "C"
const char *ljclang_getDirent64Name(const struct dirent64 &dirent) {
    return dirent.d_name;
}

extern "C"
void ljclang_setSigintHandlingToDefault()
{
    signal(SIGINT, SIG_DFL);
}
