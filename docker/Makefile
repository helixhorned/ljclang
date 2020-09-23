
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
ifeq ($(native_machine),x86_64)
	native_arch := amd64
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
	test -f vars.$(DISTRO).sed
	test `echo $(tmproot)/ljclang-tmp-* | wc -w` -lt 10 || \
	echo "INFO: Consider running 'make clean-all-temp' after the current build." 1>&2
	tmpdir=`mktemp -d $(tmproot)/ljclang-tmp-XXXXXXXX` && \
	mkdir "$$tmpdir/context" && \
	git clone --bare ../ "$$tmpdir/context/ljclang.git" > /dev/null 2>&1 && \
	test `git rev-parse --short=12 HEAD` = "$(commit)" && \
	test -n "$(ARCH)" && \
	sedcmds='s/@ARCH@/$(ARCH)/; s/@LUAJIT_GIT_HASH@/$(LJ_GIT_HASH)/; s/@LUAJIT_SHA256@/$(LJ_SHA256)/' && \
	sed -e "$$sedcmds" -f vars.$(DISTRO).sed Dockerfile.in > "$$tmpdir/Dockerfile" && \
	echo "$$tmpdir"

run:
	@test -n "$(IMAGE)"
	docker run -it --rm "$(IMAGE):$(commit)"

# For manual invocation when no other build is running:
clean-all-temp:
	rm -rf $(tmproot)/ljclang-tmp-*

## Rules for the actual Docker images

.PHONY: ljclang-dev-native/alpine ljclang-dev-arm32v7/alpine ljclang-dev-arm64v8/alpine ljclang-dev-amd64/alpine
.PHONY: ljclang-dev-native/debian ljclang-dev-arm32v7/debian ljclang-dev-arm64v8/debian ljclang-dev-amd64/debian
.PHONY: ljclang-dev-native/ubuntu ljclang-dev-arm32v7/ubuntu ljclang-dev-arm64v8/ubuntu ljclang-dev-amd64/ubuntu
.PHONY: ljclang-dev-arm32v7/ubuntu-bionic
.PHONY: ljclang-dev-native/ALL

ljclang-dev-native/alpine: ljclang-dev-$(native_arch)/alpine
ljclang-dev-native/debian: ljclang-dev-$(native_arch)/debian
ljclang-dev-native/ubuntu: ljclang-dev-$(native_arch)/ubuntu

ljclang-dev-native/ALL: ljclang-dev-native/alpine ljclang-dev-native/debian ljclang-dev-native/ubuntu

override define check_or_make_image =
  test x`$(MAKE) --silent _get-exists ARCH=$$arch DISTRO=$$distro` = x'yes' || ( \
  tmpdir=`$(MAKE) --silent _get-tmpdir ARCH=$$arch DISTRO=$$distro LJ_SHA256=$$lj_sha256` && \
  DOCKER_BUILDKIT=1 docker build --tag $@:$(commit) -f "$$tmpdir/Dockerfile" "$$tmpdir/context")
endef

# FIXME: on amd64, apparently non-deterministic (!) failure:
#  posix.lua tests fd_set_t
#  /home/user/ljclang/tests.lua:116: Expected objects to be equal.
#  Passed in: (number) 10
#  Expected: (number) 9
# (Note, 'passed in' and 'expected' are swapped.)

ljclang-dev-arm32v7/alpine:
	arch=arm32v7 distro=alpine && \
	lj_sha256=79aecd984c3dbfbb12cb67282d5862c58b48e771d5ea7b3445dd5303ad71bab5 && \
	$(check_or_make_image)

ljclang-dev-arm64v8/alpine:
	arch=arm64v8 distro=alpine && \
	lj_sha256=c3e2322da1e9942fabb8eeee08e120580aaa11277d8cc6c0abd4ed736e4311ae && \
	$(check_or_make_image)

ljclang-dev-amd64/alpine:
	arch=amd64 distro=alpine && \
	lj_sha256=e651a92e93f80015e506d1271fca0be39e33a8f85b81d2995338c251db63e82a && \
	$(check_or_make_image)

ljclang-dev-arm32v7/debian:
	arch=arm32v7 distro=debian && \
	lj_sha256=45b69b1e3b14969121c28e5a1b5d23b3c6c0f531d5b8768d5cf8356b237a4ca3 && \
	$(check_or_make_image)

ljclang-dev-arm64v8/debian:
	arch=arm64v8 distro=debian && \
	lj_sha256=75bcc032114b2c3c1f91aa732bce00647405ef4d4e0b1c66a39f72b7084b3737 && \
	$(check_or_make_image)

ljclang-dev-amd64/debian:
	arch=amd64 distro=debian && \
	lj_sha256=74ddbab26cc4dd89c5ca4df688152db7be5720f1fc01c44a0f5de0673525b23d && \
	$(check_or_make_image)

# NOTE: when building the Docker on an RPi OS (32-bit) host, can get
#  "GPG error (...) invalid signature" / "repository (...) not signed".
#  See:
#   https://askubuntu.com/questions/1263284/apt-update-throws-signature-error-in-ubuntu-20-04-container-on-arm
#   https://github.com/moby/moby/issues/40734
ljclang-dev-arm32v7/ubuntu:
	arch=arm32v7 distro=ubuntu && \
	lj_sha256=TODO && \
	$(check_or_make_image)
#
# Docker image of Ubuntu 18.04 as a workaround for the above issue.
ljclang-dev-arm32v7/ubuntu-bionic:
	arch=arm32v7 distro=ubuntu-bionic && \
	lj_sha256=80448776cfa0625f455cef100528756230094b9eebf857b8e2937e6d1aebb4c2 && \
	$(check_or_make_image)

ljclang-dev-arm64v8/ubuntu:
	arch=arm64v8 distro=ubuntu && \
	lj_sha256=67a8f44f5dd6343f160418ff64af257ff6e614e17c694695da56fd0a0d9c4e39 && \
	$(check_or_make_image)

ljclang-dev-amd64/ubuntu:
	arch=amd64 distro=ubuntu && \
	lj_sha256=02af36870213c5609ab9777da18ba3e92deb38c6928ae292fdf14e457b0d03c1 && \
	$(check_or_make_image)
