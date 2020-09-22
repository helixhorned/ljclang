
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

# For target 'prepare' invoked recursively from this Makefile.
ARCH ?= null
DISTRO ?= null
# Check out a specific LuaJIT commit:
#  "Fix lua_yield() from C hook."
LJ_GIT_HASH := dd5032ed844c56964347c7916db66b0eb11d8091
LJ_SHA256 ?= null

########## RULES ##########

.SILENT: prepare
.PHONY: prepare clean-all-temp ljclang-dev-arm32v7/alpine

prepare:
	test -d $(tmproot)
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

# For manual invocation:
clean-all-temp:
	rm -rf $(tmproot)/ljclang-tmp-*

## Alpine Linux

ljclang-dev-arm32v7/alpine:
	@lj_sha256=79aecd984c3dbfbb12cb67282d5862c58b48e771d5ea7b3445dd5303ad71bab5 && \
	tmpdir=`$(MAKE) --silent prepare ARCH=arm32v7 DISTRO=alpine LJ_SHA256=$$lj_sha256` && \
	DOCKER_BUILDKIT=1 docker build --tag $@:$(commit) -f "$$tmpdir/Dockerfile" "$$tmpdir/context"
