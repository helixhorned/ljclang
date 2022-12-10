
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

# Use '--no-cache'?
NOCACHE ?=

# If non-empty, will build images up to and including the LuaJIT build step, tagged
# 'LJ_SHA' instead of the Git commit hash of this repository. Running a container
# with an appropriate '--entrypoint', the SHA-256 hashes of all LuaJIT builds can
# be obtained. (This is especially useful in combination with building
# foreign-architecture images, see below.)
LJ_SHA_ONLY ?=

## Protected: for derivatives only

# Prefix for files named '*.<distro>.arg', each required to contain lines
# completely matching BUILD_ARGS_LINE_EREGEX below, after having comments
# (whitespace followed by '#' until the end of a line) stripped.
BUILD_ARGS_FILE_PREFIX ?=
SUFFIX_DOCKERFILE_IN ?=
OVERRIDE_IMAGE_NAME ?=
OVERRIDE_IMAGE_TAG ?=
ADDITIONAL_CONTEXT_REPO ?=

ifneq ($(SUFFIX_DOCKERFILE_IN),)
  ifneq ($(LJ_SHA_ONLY),)
    $(error When passing SUFFIX_DOCKERFILE_IN, must not pass LJ_SHA_ONLY)
  endif

  ifeq ($(OVERRIDE_IMAGE_NAME),)
    $(error When passing SUFFIX_DOCKERFILE_IN, must pass OVERRIDE_IMAGE_NAME)
  endif
  ifeq ($(OVERRIDE_IMAGE_TAG),)
    $(error When passing SUFFIX_DOCKERFILE_IN, must pass OVERRIDE_IMAGE_TAG)
  endif
endif

## Private

# NOTE: '\x23' is '#'. GNU Make 4.2.1 of Raspberry Pi OS has issues with the latter.
BUILD_ARGS_LINE_SEDCMD := 's/[[:space:]]*\x23.*//g'
BUILD_ARGS_LINE_EREGEX := '--build-arg [A-Za-z_-][A-Za-z_0-9-]*=[A-Za-z_0-9-]*'

# For '(eval $(call ...))'.
#  Argument: <distro>
#  Effects: if $(BUILD_ARGS_FILE_PREFIX) is non-empty,
#   1. Sets variable 'build_args_file_<distro>'.
#   2. Reads contents of the so named file into variable 'build_args_<distro>',
#    sanitizing its contents so that they are suitable as args to 'docker build'.
#   (Otherwise, the two variables are set to the empty string.)
define do_build_args =
  build_args_file_$(1) := $$(if $$(BUILD_ARGS_FILE_PREFIX),$$(BUILD_ARGS_FILE_PREFIX).$(1).arg)
  build_args_$(1) := $$(if $$(BUILD_ARGS_FILE_PREFIX),$$(shell \
    sed $(BUILD_ARGS_LINE_SEDCMD) < $$(build_args_file_$(1)) | \
    grep -E --line-regexp -- $(BUILD_ARGS_LINE_EREGEX)))
endef

$(eval $(call do_build_args,alpine))
$(eval $(call do_build_args,debian))
$(eval $(call do_build_args,ubuntu))
$(eval $(call do_build_args,ubuntu-bionic))

commit := $(shell git rev-parse --short=12 HEAD)
tmproot := /dev/shm

native_machine := $(shell uname -m)
# The architecture part of Docker image names:
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

equals = $(findstring ~$(1)~,~$(2)~)
qemuSuffixFromArch = $(strip \
$(if $(call equals,arm32v7,$(1)),arm,\
$(if $(call equals,arm64v8,$(1)),aarch64,\
$(if $(call equals,amd64,$(1)),x86_64))))

# To build the foreign-architecture images, static builds of qemu-<arch> are required
# on the host system. Exception: Armv7 can be built and run on an Armv8 host directly.
#
# Example arguments to qemu's 'configure':
#  --target-list=aarch64-linux-user,arm-linux-user --disable-system --static
#
# These binaries need to be registered with binfmt_misc (again, on the host). Example:
#
# $ <qemu-checkout>/scripts/qemu-binfmt-conf.sh --debian --exportdir <template-dir>
# $ (Remove all but the necessary templates...)
# $ sudo mkdir /usr/local/share/binfmts && sudo cp <template-dir>/qemu-* /usr/local/share/binfmts
# For each available architecture <arch>:
#  $ sudo update-binfmts --importdir /usr/local/share/binfmts --import qemu-<arch>
# (See '<qemu-checkout>/scripts/qemu-binfmt-conf.sh --help'.)
# (See '/proc/sys/fs/binfmt_misc/qemu-*' which are then created.)
qemu_prefix := /usr/local/bin/qemu-
haveQemu = $(realpath $(qemu_prefix)$(1))
# Return: empty (false) or non-empty (true)
canRunLowerVersion_ = $(and $(call equals,arm64v8,$(native_arch)),$(call equals,arm32v7,$(1)))
canRunNatively_ = $(or $(call equals,$(1),$(native_arch)),$(call canRunLowerVersion_,$(1)))
canRunEmulated_ = $(and $(call qemuSuffixFromArch,$(1)),$(call haveQemu,$(call qemuSuffixFromArch,$(1))))
# Return: empty (false), 1 (can run natively) or 2 (can run emulated)
canRunNatively = $(if $(call canRunNatively_,$(1)),1)
canRunEmulated = $(if $(call canRunEmulated_,$(1)),2)
canRun = $(or $(call canRunNatively,$(1)),$(call canRunEmulated,$(1)))

# For target '_get-tmpdir' invoked recursively from this Makefile.
ARCH ?= null
DISTRO ?= null
# Check out a specific LuaJIT commit:
#  "Merge branch 'master' into v2.1" after
#  "Correct fix for stack check when recording BC_VARG."
LJ_GIT_HASH := 8625eee71f16a3a780ec92bc303c17456efc7fb3
LJ_SHA256 ?= null
#
qemu_suffix :=
ifeq ($(call canRun,$(ARCH)),2)
  qemu_suffix := $(call qemuSuffixFromArch,$(ARCH))
endif

########## RULES ##########

.SILENT: _get-exists _get-tmpdir
.PHONY: _get-exists _get-tmpdir all run clean-all-temp

image_name_prefix := $(or $(OVERRIDE_IMAGE_NAME),ljclang-dev)
image_tag := $(or $(OVERRIDE_IMAGE_TAG),$(if $(LJ_SHA_ONLY),LJ_SHA,$(commit)))

all:
	@echo 'Usage:'
	@echo ' $$ make ljclang-dev-<arch>/<distro>'
	@echo '  Build a Docker image. It has the given name and is tagged'
	@echo '  with the short-commit-SHA of *this* Git repository (ljclang).'
	@echo ' $$ make run IMAGE=ljclang-dev-<arch>/<distro>'
	@echo '  Run the specified Docker image.'
	@echo ''
	@echo " Passing NOCACHE=1 will add '--no-cache' to the 'docker build' invocation(s)."
	@echo ''
	@echo ' $$ LJ_SHA_ONLY=1 make ljclang-dev-<arch>/<distro>'
	@echo "  Build Docker images tagged 'LJ_SHA' only up to LuaJIT build."
	@echo ' $$ make run-lj-sha-only'
	@echo "  Run all LJ_SHA-tagged images, printing SHA256 of each 'luajit'."

_get-exists:
	docker image inspect "$(image_name_prefix)-$(ARCH)/$(DISTRO):$(image_tag)" > /dev/null 2>&1 && \
	echo "yes" || echo "no"

ifneq ($(qemu_suffix),)
  _get-tmpdir-in1 = echo "INFO: Building image using '$(qemu_prefix)$(qemu_suffix)'." 1>&2
  _get-tmpdir-in2 = cp '$(qemu_prefix)$(qemu_suffix)' "$$tmpdir/context"
  _get-tmpdir-in4 = sedcmds="$$sedcmds; s/^\#@if-foreign://g; s/@qemu-suffix@/$(qemu_suffix)/g"
else
  _get-tmpdir-in1 = true
  _get-tmpdir-in2 = true
  _get-tmpdir-in4 = true
endif

ifeq ($(ARCH)~$(DISTRO),arm32v7~debian)
  _get-tmpdir-in5 = sedcmds="$$sedcmds; s/^\#@if-ljrM://g"
else
  _get-tmpdir-in5 = true
endif

Dockerfile_in := Dockerfile.in

ifneq ($(LJ_SHA_ONLY),)
  _get-tmpdir-in3 = true
  _tmp-lnum := $(shell grep -m1 -n '^RUN make -j4' $(Dockerfile_in) | sed 's/:.*//g')
  ifeq ($(_tmp-lnum),)
    $(error INTERNAL: Failed obtaining line number of LuaJIT build invocation)
  endif
  _cat_Dockerfile_in := head -q -n "$(_tmp-lnum)" $(Dockerfile_in)
else
  _get-tmpdir-in3 = git clone --bare ../ "$$tmpdir/context/ljclang.git" > /dev/null 2>&1
  _cat_Dockerfile_in := cat $(Dockerfile_in) $(SUFFIX_DOCKERFILE_IN)
endif

ifneq ($(ADDITIONAL_CONTEXT_REPO),)
  _clone_additional_repo := \
    git clone --bare '$(ADDITIONAL_CONTEXT_REPO)' "$$tmpdir/context/additional.git" > /dev/null 2>&1
else
  _clone_additional_repo := true
endif

_get-tmpdir:
	test -d $(tmproot)
	test -f vars.$(DISTRO).sed
	test `echo $(tmproot)/ljclang-tmp-* | wc -w` -lt 10 || \
	echo "INFO: Consider running 'make clean-all-temp' after the current build." 1>&2
	$(_get-tmpdir-in1)
	tmpdir=`mktemp -d $(tmproot)/ljclang-tmp-XXXXXXXX` && \
	mkdir "$$tmpdir/context" && \
	$(_get-tmpdir-in2) && \
	$(_get-tmpdir-in3) && \
	$(_clone_additional_repo) && \
	test `git rev-parse --short=12 HEAD` = "$(commit)" && \
	test -n "$(ARCH)" && \
	sedcmds='s/@ARCH@/$(ARCH)/; s/@LUAJIT_GIT_HASH@/$(LJ_GIT_HASH)/; s/@LUAJIT_SHA256@/$(LJ_SHA256)/' && \
	$(_get-tmpdir-in4) && \
	$(_get-tmpdir-in5) && \
	$(_cat_Dockerfile_in) | sed -e "$$sedcmds" -f vars.$(DISTRO).sed > "$$tmpdir/Dockerfile" && \
	echo "$$tmpdir"

replace_NATIVE = $(subst NATIVE,$(native_arch),$(1))
image_to_run := $(call replace_NATIVE,$(IMAGE))

define get_sha_only_images :=
  docker images -q --filter=reference='ljclang-dev-*/*:LJ_SHA'
endef

define get_sha_only_images_repo-tag :=
  $(get_sha_only_images) --format "{{.Repository}}:{{.Tag}}"
endef

define clean_sha_only_images :=
  images=`$(get_sha_only_images)` && (test -z "$$images" || docker rmi $$images)
endef

run:
	@test -n "$(image_to_run)"
	docker run -it --rm "$(image_to_run):$(image_tag)"

run-lj-sha-only:
	@images=`$(get_sha_only_images_repo-tag)` && \
	(test -n "$$images" || (echo "ERROR: no LJ_SHA-tagged images." 1>&2 && false)) && \
	for i in $$images; do echo "$$i" && docker run --rm --entrypoint sha256sum "$$i" src/luajit 2>&1 | \
	grep -v "WARNING: The requested image's platform "; done

# For manual invocation when no other build is running:
clean-all-temp:
	rm -rf $(tmproot)/ljclang-tmp-*
	$(clean_sha_only_images)

## Rules for the actual Docker images

canRunArm32 := $(call canRun,arm32v7)
canRunArm64 := $(call canRun,arm64v8)
canRunAmd64 := $(call canRun,amd64)

ifeq ($(canRunArm32)$(canRunArm64)$(canRunAmd64),)
  $(error Cannot build any Docker image: unsupported architecture)
else
.PHONY: ljclang-dev-ALL/ALL
endif

ifneq ($(canRunArm32),)
.PHONY: ljclang-dev-arm32v7/alpine ljclang-dev-arm32v7/debian ljclang-dev-arm32v7/ubuntu
.PHONY: ljclang-dev-arm32v7/ubuntu-bionic
.PHONY: ljclang-dev-arm32v7/ALL
endif
ifneq ($(canRunArm64),)
.PHONY: ljclang-dev-arm64v8/alpine ljclang-dev-arm64v8/debian ljclang-dev-arm64v8/ubuntu
.PHONY: ljclang-dev-arm64v8/ALL
endif
ifneq ($(canRunAmd64),)
.PHONY: ljclang-dev-amd64/alpine ljclang-dev-amd64/debian ljclang-dev-amd64/ubuntu
.PHONY: ljclang-dev-amd64/ALL
endif

.PHONY: ljclang-dev-NATIVE/alpine ljclang-dev-NATIVE/debian ljclang-dev-NATIVE/ubuntu
ljclang-dev-NATIVE/alpine: ljclang-dev-$(native_arch)/alpine
ljclang-dev-NATIVE/debian: ljclang-dev-$(native_arch)/debian
ljclang-dev-NATIVE/ubuntu: ljclang-dev-$(native_arch)/ubuntu

.PHONY: ljclang-dev-NATIVE/ALL
ljclang-dev-NATIVE/ALL: ljclang-dev-NATIVE/alpine ljclang-dev-NATIVE/debian ljclang-dev-NATIVE/ubuntu

_image_name = $(subst ljclang-dev,$(image_name_prefix),$@)
_opts := $(if $(NOCACHE),--no-cache)
#
define _docker_build =
  DOCKER_BUILDKIT=1 docker build $(_opts) $(call build_args_$(1)) --tag $(_image_name):$(image_tag) \
    -f "$$tmpdir/Dockerfile" "$$tmpdir/context"
endef

# We want to detect whether we are invoked with potentially-parallel execution
# (-j/--jobs) and if so, redirect output from 'docker build' to a file.
#
# Unfortunately, this logic cannot be pulled into Makefile code: the thing to keep
# in mind is that the special MAKEFLAGS variable evaluates to a (normalized)
# representation of passed command line arguments *only in recipe context*.
#
# NOTE: this handles both the long form '--jobs' (because GNU Make maps that to the
#  short form for the internal variable) as well as a plain option without argument.
define invoke_docker_build
  if expr match '$(MAKEFLAGS)' '[[:space:]]-j[0-9]*\>' > /dev/null; then \
    $(call _docker_build,$(1)) > $$tmpdir/docker-build.log 2>&1; else $(call _docker_build,$(1)); \
  fi
endef

define check_or_make_image =
  test x`$(MAKE) --silent _get-exists ARCH=$(1) DISTRO=$(2)` = x'yes' || ( \
  tmpdir=`$(MAKE) --silent _get-tmpdir ARCH=$(1) DISTRO=$(2) LJ_SHA256=$(3)` && \
  $(call invoke_docker_build,$(2)))
endef

ifneq ($(canRunArm32),)
ljclang-dev-arm32v7/ALL: ljclang-dev-arm32v7/alpine ljclang-dev-arm32v7/debian ljclang-dev-arm32v7/ubuntu ljclang-dev-arm32v7/ubuntu-bionic
ljclang-dev-ALL/ALL: ljclang-dev-arm32v7/ALL

ljclang-dev-arm32v7/alpine:
	+$(call check_or_make_image,arm32v7,alpine,fcaf58ac192f64f860ab790ff699473cc72b858a1a32cb533327a3dda1b2957b)

ljclang-dev-arm32v7/debian:
	+$(call check_or_make_image,arm32v7,debian,a649bc28b5e5cbc1988c7b7bf33ec5450bd149bf00d4688edaaa6ccc048c31d2)

# NOTE: when building the Docker on an RPi OS (32-bit) host, can get
#  "GPG error (...) invalid signature" / "repository (...) not signed".
#  See:
#   https://askubuntu.com/questions/1263284/apt-update-throws-signature-error-in-ubuntu-20-04-container-on-arm
#   https://github.com/moby/moby/issues/40734
ljclang-dev-arm32v7/ubuntu:
	+$(call check_or_make_image,arm32v7,ubuntu,2ddfa6edfbf8fe0b7c40f51d714bb671d92fb0256bacd4439ab9ec370d5e4b06)
#
# Docker image of Ubuntu 18.04 as a workaround for the above issue.
ljclang-dev-arm32v7/ubuntu-bionic:
	+$(call check_or_make_image,arm32v7,ubuntu-bionic,adffbf7d30923e9d628db2e4486b3332fbb952f5ed751e72f52f8f7403007a52)
endif

ifneq ($(canRunArm64),)
ljclang-dev-arm64v8/ALL: ljclang-dev-arm64v8/alpine ljclang-dev-arm64v8/debian ljclang-dev-arm64v8/ubuntu
ljclang-dev-ALL/ALL: ljclang-dev-arm64v8/ALL

ljclang-dev-arm64v8/alpine:
	+$(call check_or_make_image,arm64v8,alpine,d6111f801dd2a9fab68db79a7a0d1ab8b16744498ad6619a5b4cf875f1cc47ff)

ljclang-dev-arm64v8/debian:
	+$(call check_or_make_image,arm64v8,debian,bdf473f287b8e20364b99c8ef374e487b67c1379ccefb0b699f308f6c795e05e)

ljclang-dev-arm64v8/ubuntu:
	+$(call check_or_make_image,arm64v8,ubuntu,65a1991f658060f485c0c0ae5453c4955a19d978924961cdb63b9dcf8685682c)
endif

ifneq ($(canRunAmd64),)
ljclang-dev-amd64/ALL: ljclang-dev-amd64/alpine ljclang-dev-amd64/debian ljclang-dev-amd64/ubuntu
ljclang-dev-ALL/ALL: ljclang-dev-amd64/ALL

ljclang-dev-amd64/alpine:
	+$(call check_or_make_image,amd64,alpine,14615b356c1f15c77e73d3c0692ba1c9cfb7700b8ef4a19ddbd09c31e28747aa)

ljclang-dev-amd64/debian:
	+$(call check_or_make_image,amd64,debian,7755777e17c41d4fbf00096537b46035a7447655fecd3f868b8ef965bc3bb88a)

ljclang-dev-amd64/ubuntu:
	+$(call check_or_make_image,amd64,ubuntu,dbb468e539f85ba012417dca9af8cf81c1767c7a0ab5cd44afda57f631091c80)
endif
