
# From the 'GNU make' manual:
#  "recipes will be invoked as if the shell had been passed the '-e' flag:
#   the first failing command in a recipe will cause the recipe to fail
#   immediately."
.POSIX:

########## VARIABLES ##########

## User

# For target 'run', to be used interactively, e.g.
#  $ make run ljc<TAB...>                       --(completion)-->
#  $ make run ljclang-dev-arm32v7/alpine        --(edit)-->
#  $ make run IMAGE=ljclang-dev-arm32v7/alpine  <--(invoke this)
IMAGE ?=

## Private

commit := $(shell git rev-parse --short=12 HEAD)
tmproot := /dev/shm

native_machine := $(shell uname -m)
native_arch = null

ifeq ($(native_machine),armv7l)
    native_arch := arm32v7
endif
ifeq ($(native_machine),aarch64)
	native_arch := arm64v8
endif

# For target '_get-tmpdir' invoked recursively from this Makefile.
ARCH ?= null
DISTRO ?= null
# Check out a specific LuaJIT commit:
#  "Fix lua_yield() from C hook."
LJ_GIT_HASH := dd5032ed844c56964347c7916db66b0eb11d8091
LJ_SHA256 ?= null

########## RULES ##########

.SILENT: _get-exists _get-tmpdir
.PHONY: _get-exists _get-tmpdir all run clean-all-temp

all:
	@echo 'Usage:'
	@echo ' $$ make ljclang-dev-<arch>/<distro>'
	@echo '  The created Docker image has the given name and is tagged'
	@echo '  with the short-commit-SHA.'
	@echo ''
	@echo ' $$ make run IMAGE=ljclang-dev-<arch>/<distro>'

_get-exists:
	docker image inspect "ljclang-dev-$(ARCH)/$(DISTRO):$(commit)" > /dev/null 2>&1 && \
	echo "yes" || echo "no"

_get-tmpdir:
	test -d $(tmproot)
	test `echo $(tmproot)/ljclang-tmp-* | wc -w` -lt 10 || \
	echo "INFO: Consider running 'make clean-all-temp' after the current build." 1>&2
	tmpdir=`mktemp -d $(tmproot)/ljclang-tmp-XXXXXXXX` && \
	mkdir "$$tmpdir/context" && \
	git clone --bare ../ "$$tmpdir/context/ljclang.git" > /dev/null 2>&1 && \
	test `git rev-parse --short=12 HEAD` = "$(commit)" && \
	test -n "$(ARCH)" && \
	sedcmds='s/@ARCH@/$(ARCH)/; s/@LUAJIT_GIT_HASH@/$(LJ_GIT_HASH)/; s/@LUAJIT_SHA256@/$(LJ_SHA256)/' && \
	sed "$$sedcmds" Dockerfile.$(DISTRO).in > "$$tmpdir/Dockerfile" && \
	echo "$$tmpdir"

run:
	@test -n "$(IMAGE)"
	docker run -it --rm "$(IMAGE):$(commit)"

# For manual invocation when no other build is running:
clean-all-temp:
	rm -rf $(tmproot)/ljclang-tmp-*

## Alpine Linux

.PHONY: ljclang-dev-native/alpine ljclang-dev-arm32v7/alpine ljclang-dev-arm64v8/alpine

ljclang-dev-native/alpine: ljclang-dev-$(native_arch)/alpine

ljclang-dev-arm32v7/alpine:
	arch=arm32v7 distro=alpine && \
	test x`$(MAKE) --silent _get-exists ARCH=$$arch DISTRO=$$distro` = x'yes' || ( \
	lj_sha256=79aecd984c3dbfbb12cb67282d5862c58b48e771d5ea7b3445dd5303ad71bab5 && \
	tmpdir=`$(MAKE) --silent _get-tmpdir ARCH=$$arch DISTRO=$$distro LJ_SHA256=$$lj_sha256` && \
	DOCKER_BUILDKIT=1 docker build --tag $@:$(commit) -f "$$tmpdir/Dockerfile" "$$tmpdir/context")

ljclang-dev-arm64v8/alpine:
	arch=arm64v8 distro=alpine && \
	test x`$(MAKE) --silent _get-exists ARCH=$$arch DISTRO=$$distro` = x'yes' || ( \
	lj_sha256=c3e2322da1e9942fabb8eeee08e120580aaa11277d8cc6c0abd4ed736e4311ae && \
	tmpdir=`$(MAKE) --silent _get-tmpdir ARCH=$$arch DISTRO=$$distro LJ_SHA256=$$lj_sha256` && \
	DOCKER_BUILDKIT=1 docker build --tag $@:$(commit) -f "$$tmpdir/Dockerfile" "$$tmpdir/context")
