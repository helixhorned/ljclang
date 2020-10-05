
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
# 'LJ_SHA' instead of the Git commit hash of this repository. Instead of the shell,
# the ENTRYPOINTs of these images will be 'sha256 <path-to>/luajit'. This way, the
# SHA-256 hashes of all LuaJIT builds can be obtained conveniently. (Especially in
# combination with building foreign-architecture images, see below.)
LJ_SHA_ONLY ?=

## Semi-private

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

# To build the foreign-architecture images, statics builds of qemu-<arch> are required
# on the host system.
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
canRunNatively_ = $(call equals,$(1),$(native_arch))
canRunEmulated_ = $(and $(call qemuSuffixFromArch,$(1)),$(call haveQemu,$(call qemuSuffixFromArch,$(1))))
# Return: empty (false), 1 (can run natively) or 2 (can run emulated)
canRunNatively = $(if $(call canRunNatively_,$(1)),1)
canRunEmulated = $(if $(call canRunEmulated_,$(1)),2)
canRun = $(or $(call canRunNatively,$(1)),$(call canRunEmulated,$(1)))

# For target '_get-tmpdir' invoked recursively from this Makefile.
ARCH ?= null
DISTRO ?= null
# Check out a specific LuaJIT commit:
#  "Add support for full-range 64 bit lightuserdata."
LJ_GIT_HASH := e9af1abec542e6f9851ff2368e7f196b6382a44c
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
  _tmp-ENTRYPOINT := 'ENTRYPOINT sha256sum /home/user/luajit-2.1/src/luajit'
  _cat_Dockerfile_in := echo $(_tmp-ENTRYPOINT) | head -q -n "$(_tmp-lnum)" $(Dockerfile_in) -
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
	for i in $$images; do echo "$$i" && docker run -it --rm "$$i"; done

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
define check_or_make_image =
  test x`$(MAKE) --silent _get-exists ARCH=$$arch DISTRO=$$distro` = x'yes' || ( \
  tmpdir=`$(MAKE) --silent _get-tmpdir ARCH=$$arch DISTRO=$$distro LJ_SHA256=$$lj_sha256` && \
  DOCKER_BUILDKIT=1 docker build $(_opts) --tag $(_image_name):$(image_tag) -f "$$tmpdir/Dockerfile" "$$tmpdir/context")
endef

ifneq ($(canRunArm32),)
ljclang-dev-arm32v7/ALL: ljclang-dev-arm32v7/alpine ljclang-dev-arm32v7/debian ljclang-dev-arm32v7/ubuntu ljclang-dev-arm32v7/ubuntu-bionic
ljclang-dev-ALL/ALL: ljclang-dev-arm32v7/ALL

ljclang-dev-arm32v7/alpine:
	arch=arm32v7 distro=alpine && \
	lj_sha256=5163532344acf05b382f60282198c1833f2377966db1b535ef0ed0968b28c621 && \
	$(check_or_make_image)

ljclang-dev-arm32v7/debian:
	arch=arm32v7 distro=debian && \
	lj_sha256=094096907f92f3c6516cf65dba830bdd887d0c2ff046027632b3460e9bc053a6 && \
	$(check_or_make_image)

# NOTE: when building the Docker on an RPi OS (32-bit) host, can get
#  "GPG error (...) invalid signature" / "repository (...) not signed".
#  See:
#   https://askubuntu.com/questions/1263284/apt-update-throws-signature-error-in-ubuntu-20-04-container-on-arm
#   https://github.com/moby/moby/issues/40734
ljclang-dev-arm32v7/ubuntu:
	arch=arm32v7 distro=ubuntu && \
	lj_sha256=8bf5e7508b48bc167f2b8509114ec17be5395a8efa00002cf49288d88ef33234 && \
	$(check_or_make_image)
#
# Docker image of Ubuntu 18.04 as a workaround for the above issue.
ljclang-dev-arm32v7/ubuntu-bionic:
	arch=arm32v7 distro=ubuntu-bionic && \
	lj_sha256=8e62df54c0868087dbbae2f408fd1fc6a998b8897aef3cde7de0fb206ba66804 && \
	$(check_or_make_image)
endif

ifneq ($(canRunArm64),)
ljclang-dev-arm64v8/ALL: ljclang-dev-arm64v8/alpine ljclang-dev-arm64v8/debian ljclang-dev-arm64v8/ubuntu
ljclang-dev-ALL/ALL: ljclang-dev-arm64v8/ALL

ljclang-dev-arm64v8/alpine:
	arch=arm64v8 distro=alpine && \
	lj_sha256=19caf908d426d56a2475797c4995b64919c909e97d00f8a1bac53d71c53915b8 && \
	$(check_or_make_image)

ljclang-dev-arm64v8/debian:
	arch=arm64v8 distro=debian && \
	lj_sha256=95fc66e4724f8ed03bf518ba709c6922e96487d04b8b2f79c566a04906c8a4ba && \
	$(check_or_make_image)

ljclang-dev-arm64v8/ubuntu:
	arch=arm64v8 distro=ubuntu && \
	lj_sha256=d68c7c0567336393fbd7b6449c8c06c5c80830fa2419dd88fefd8a4e73b24e62 && \
	$(check_or_make_image)
endif

ifneq ($(canRunAmd64),)
ljclang-dev-amd64/ALL: ljclang-dev-amd64/alpine ljclang-dev-amd64/debian ljclang-dev-amd64/ubuntu
ljclang-dev-ALL/ALL: ljclang-dev-amd64/ALL

ljclang-dev-amd64/alpine:
	arch=amd64 distro=alpine && \
	lj_sha256=71fcdb9fa88a2d9ed1bb5acfb9113470f3f6ca54c4d6d940374f7df8a5d0ac8a && \
	$(check_or_make_image)

ljclang-dev-amd64/debian:
	arch=amd64 distro=debian && \
	lj_sha256=5377c69a60f7883d6c8d67c7b564229f03261b4019e0ca458c14bce258e7e5bf && \
	$(check_or_make_image)

ljclang-dev-amd64/ubuntu:
	arch=amd64 distro=ubuntu && \
	lj_sha256=dce1077ef83cf6428da89b100d9f746ed4bb869dc99201ae2ee395dc0b73e358 && \
	$(check_or_make_image)
endif