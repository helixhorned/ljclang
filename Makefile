
OS := $(shell uname -s)
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# User configuration
include config.make

llvm-config := $(shell which $(LLVM_CONFIG))

markdown := $(shell which $(MARKDOWN))

ifeq ($(llvm-config),)
    $(error "$(LLVM_CONFIG) not found, use LLVM_CONFIG=<path/to/llvm-config> make")
endif

full_llvm_version := $(shell $(llvm-config) --version)
llvm_version := $(full_llvm_version:git=)

########## PATHS ##########

ifneq ($(OS),Linux)
    $(error "Unsupported OS")
endif

bindir := $(shell $(llvm-config) --bindir)
incdir := $(shell $(llvm-config) --includedir)
libdir := $(shell $(llvm-config) --libdir)
lib := -L$(libdir) -lclang

# TODO: error or warn if directory does not exist. Ideally, remove.
llvm_libdir_include := $(libdir)/clang/$(llvm_version)/include

########## COMPILER OPTIONS ##########

common_flags := -I$(incdir) -fPIC -O2
common_flags += -DLJCLANG_LLVM_VERSION='"$(llvm_version)"'
common_flags += -Werror -Wall -Wextra -pedantic

cflags := -std=c99 $(common_flags)

# Development convenience, for test_data/*.cpp only:
cxxflags := -std=c++17 $(common_flags) -Wold-style-cast
ifneq ($(findstring clang,$(CXX)),)
    cxxflags += -Wno-unused-const-variable
endif

########## RULES ##########

INDEX_H_LUA := ljclang_Index_h.lua
LIBDIR_INCLUDE_LUA := ./llvm_libdir_include.lua
EXTRACTED_ENUMS_LUA := ljclang_extracted_enums.lua
EXTRACTED_ENUMS_LUA_TMP := $(EXTRACTED_ENUMS_LUA).tmp
linux_decls_lua := ljclang_linux_decls.lua
linux_decls_lua_tmp := $(linux_decls_lua).tmp
posix_decls_lua := posix_decls.lua
posix_decls_lua_tmp := $(posix_decls_lua).tmp
posix_types_lua := posix_types.lua
posix_types_lua_tmp := $(posix_types_lua).tmp

LJCLANG_SUPPORT_SO := libljclang_support.so
SHARED_LIBRARIES := $(LJCLANG_SUPPORT_SO)

GENERATED_FILES_STAGE_1 := $(INDEX_H_LUA) $(LIBDIR_INCLUDE_LUA)
GENERATED_FILES_STAGE_2 := $(GENERATED_FILES_STAGE_1) $(EXTRACTED_ENUMS_LUA) $(posix_types_lua)

.PHONY: all app_dependencies apps clean veryclean bootstrap doc test install install-dev _install_common
.PHONY: committed-generated

all: $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_2)

apps := extractdecls.app.lua watch_compile_commands.app.lua
apps: $(apps)

committed-generated: $(INDEX_H_LUA) $(EXTRACTED_ENUMS_LUA)

clean:
	rm -f $(SHARED_LIBRARIES) $(apps)

veryclean: clean
	rm -f $(GENERATED_FILES_STAGE_2) $(EXTRACTED_ENUMS_LUA_TMP) $(EXTRACTED_ENUMS_LUA).reject \
		$(linux_decls_lua) $(linux_decls_lua_tmp) $(linux_decls_lua).reject \
		$(posix_decls_lua) $(posix_decls_lua_tmp) $(posix_decls_lua).reject

bootstrap: $(EXTRACTED_ENUMS_LUA)

# ---------- Build ----------

$(LJCLANG_SUPPORT_SO): ljclang_support.c Makefile
	$(CC) $(cflags) -shared $< $(lib) -o $@

$(INDEX_H_LUA): ./dev/createheader.lua $(incdir)/clang-c/*
	@$(luajit) ./dev/createheader.lua $(incdir)/clang-c > $@
	@printf "* \033[1mGenerated $@ from files in $(incdir)/clang-c \033[0m\n"

$(LIBDIR_INCLUDE_LUA): Makefile config.make
	@echo "return { '$(llvm_libdir_include)' }" > $@

EXTRACT_CMD_ENV := LD_LIBRARY_PATH="$(libdir):$(THIS_DIR)"

CHECK_EXTRACTED_ENUMS_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require('ffi').cdef[[typedef int time_t;]]" \
    -e "require '$(subst .lua,,$(INDEX_H_LUA))'" \
    -e "l=require '$(subst .lua,,$(EXTRACTED_ENUMS_LUA))'" \
    -e "assert(l.CursorKindName[1] ~= nil)"

# Because we have comments in the executable portion of the rule.
.SILENT: $(EXTRACTED_ENUMS_LUA)

$(EXTRACTED_ENUMS_LUA): $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_1)
$(EXTRACTED_ENUMS_LUA): ./dev/$(EXTRACTED_ENUMS_LUA).in $(incdir)/clang-c/*
    # Make loading ljclang.lua not fail. We must not use any "extracted enums" though since
    # we are about to generate them.
	echo 'return {}' > $(EXTRACTED_ENUMS_LUA)
    # Do the extraction.
	$(EXTRACT_CMD_ENV) ./mkdecls.sh $< -A -I"${incdir}" "${incdir}/clang-c/Index.h" > $(EXTRACTED_ENUMS_LUA_TMP)
    # Check that we can load the generated file in Lua.
	mv $(EXTRACTED_ENUMS_LUA_TMP) $@
	($(CHECK_EXTRACTED_ENUMS_CMD) && \
	    printf "* \033[1mGenerated $@\033[0m\n") \
	|| (printf "* \033[1;31mError\033[0m generating $@\n" && \
	    mv $@ $@.reject && false)

# Linux-specific functionality exposed to us

sys_h := ./dev/sys.h

CHECK_EXTRACTED_INOTIFY_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require'ljclang_linux_decls'"

$(linux_decls_lua): ./dev/ljclang_linux_decls.lua.in $(EXTRACTED_ENUMS_LUA) $(sys_h) Makefile
	@$(EXTRACT_CMD_ENV) ./mkdecls.sh $< > $(linux_decls_lua_tmp)
	@mv $(linux_decls_lua_tmp) $@
	@($(CHECK_EXTRACTED_INOTIFY_CMD) && \
	    printf "* \033[1mGenerated $@\033[0m\n") \
	|| (printf "* \033[1;31mError\033[0m generating $@\n" && \
	    mv $@ $@.reject && false)

# POSIX functionality exposed to us

$(posix_types_lua): ./dev/posix_types.lua.in $(EXTRACTED_ENUMS_LUA) $(sys_h) Makefile
	@$(EXTRACT_CMD_ENV) ./mkdecls.sh $< > $(posix_types_lua_tmp)
	@mv $(posix_types_lua_tmp) $@
	@($(EXTRACT_CMD_ENV) $(luajit) -e "require'posix_types'" && \
	    printf "* \033[1mGenerated $@\033[0m\n") \
	|| (printf "* \033[1;31mError\033[0m generating $@\n" && \
	    mv $@ $@.reject && false)

$(posix_decls_lua): ./dev/posix_decls.lua.in $(EXTRACTED_ENUMS_LUA) $(sys_h) Makefile $(posix_types_lua)
	@$(EXTRACT_CMD_ENV) ./mkdecls.sh $< > $(posix_decls_lua_tmp)
	@mv $(posix_decls_lua_tmp) $@
	@($(EXTRACT_CMD_ENV) $(luajit) -e "require'posix_decls'" && \
	    printf "* \033[1mGenerated $@\033[0m\n") \
	|| (printf "* \033[1;31mError\033[0m generating $@\n" && \
	    mv $@ $@.reject && false)

# ---------- Post-build ----------

.SILENT: doc

doc: README.md.in ljclang.lua ./make_docs.lua
	$(luajit) ./make_docs.lua $^ > README.md \
	    && printf "* \033[1mGenerated README.md\033[0m\n"
ifneq ($(markdown),)
	$(markdown) README.md > README.html \
	    && printf "* \033[1mGenerated README.html\033[0m\n"
else
	echo "* Did not generate README.html: '$(MARKDOWN)' not installed"
endif

test: $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_2)
	LLVM_LIBDIR="$(libdir)" $(SHELL) ./run_tests.sh

sed_common_commands := s|@LJCLANG_DEV_DIR@|$(THIS_DIR)|g; s|@LLVM_BINDIR@|$(bindir)|g; s|@LLVM_LIBDIR@|$(libdir)|g;

app_dependencies: $(linux_decls_lua) $(posix_decls_lua)

extractdecls.app.lua: extractdecls.lua mkapp.lua $(GENERATED_FILES_STAGE_1) app_dependencies
	@$(EXTRACT_CMD_ENV) $(luajit) -l mkapp $< -Q > /dev/null && \
		printf "* \033[1mCreated $@\033[0m\n"

watch_compile_commands.app.lua: watch_compile_commands.lua mkapp.lua $(GENERATED_FILES_STAGE_2) app_dependencies
	@$(EXTRACT_CMD_ENV) $(luajit) -l mkapp $< -x > /dev/null && \
		printf "* \033[1mCreated $@\033[0m\n"

pre := dev/app-prefix.sh.in
post := dev/app-suffix.sh.in

_install_common:
	install $(THIS_DIR)/wcc-server.sh $(BINDIR)/wcc-server
	install $(THIS_DIR)/wcc-client.sh $(BINDIR)/wcc-client

# Notes:
#  - the check using grep for 'EOF' is stricter than necessary -- we append 80 '_' chars.
#  - the overhead of the generated Bash script (reading the here document line-by-line?) is
#    noticable on a Raspberry Pi (approx. 100ms on a Pi 4).
install: $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_2) apps _install_common
	@if grep -c EOF extractdecls.app.lua > /dev/null; then echo "ERROR: 'EOF' in Lua source!"; false; else true; fi
	sed "$(sed_common_commands)" $(pre) | cat - extractdecls.app.lua $(post) > $(BINDIR)/extractdecls
	@rm -f extractdecls.app.lua
	@chmod +x $(BINDIR)/extractdecls
	@if grep -c EOF watch_compile_commands.app.lua > /dev/null; then echo "ERROR: 'EOF' in Lua source!"; false; else true; fi
	sed "$(sed_common_commands)" $(pre) | cat - watch_compile_commands.app.lua $(post) > $(BINDIR)/watch_compile_commands
	@rm -f watch_compile_commands.app.lua
	@chmod +x $(BINDIR)/watch_compile_commands

install-dev: $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_2) app_dependencies _install_common
	sed "$(sed_common_commands) s|@APPLICATION@|extractdecls|g" ./dev/app.sh.in > $(BINDIR)/extractdecls
	@chmod +x $(BINDIR)/extractdecls
	sed "$(sed_common_commands) s|@APPLICATION@|watch_compile_commands|g" ./dev/app.sh.in > $(BINDIR)/watch_compile_commands
	@chmod +x $(BINDIR)/watch_compile_commands

# This target is merely there to create compile_commands.json entries for the test
# source files in case we are invoked with 'bear'.
compile_commands.json: $(patsubst %.cpp,%.o,$(wildcard test_data/*.cpp))

test_data/%.o: test_data/%.cpp
	$(CXX) -c $(subst -Werror,,$(cxxflags)) $< -o /dev/null
