// Support library for POSIX functionality.
// Copyright (C) 2013-2020 Philipp Kutin
// See LICENSE for license information.

#define _LARGEFILE64_SOURCE 1
#include <dirent.h>

const char *ljclang_getDirent64Name(const struct dirent64 *dirent) {
    return dirent ? dirent->d_name : "";
}
