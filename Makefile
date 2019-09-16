
OS := $(shell uname -s)
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# User configuration
include config.make

llvm-config := $(shell which $(LLVM_CONFIG))

markdown := $(shell which $(MARKDOWN))

ifeq ($(llvm-config),)
    $(error "$(LLVM_CONFIG) not found, use LLVM_CONFIG=<path/to/llvm-config> make")
endif

llvm_version := $(shell $(llvm-config) --version)


########## PATHS ##########

ifneq ($(OS),Linux)
    $(error "Unsupported OS")
endif

bindir := $(shell $(llvm-config) --bindir)
incdir := $(shell $(llvm-config) --includedir)
libdir := $(shell $(llvm-config) --libdir)
lib := -L$(libdir) -lclang


########## OPTIONS ##########

cxxflags := -std=c++17 -I$(incdir) -fPIC
cxxflags += -DLJCLANG_LLVM_VERSION='"$(llvm_version)"'
cxxflags += -Werror -Wall -Wextra -Wold-style-cast -pedantic
ifneq ($(findstring clang,$(CXX)),)
    cxxflags += -Wno-unused-const-variable
endif

# NOTE: Additional flags (such as for enabling sanitizers or debugging symbols)
# can be specified with CXXFLAGS on the command-line, and they will be appended.
CXXFLAGS ?=
cxxflags += $(CXXFLAGS)


########## RULES ##########

INDEX_H_LUA := ljclang_Index_h.lua
EXTRACTED_ENUMS_LUA := ljclang_extracted_enums.lua
EXTRACTED_ENUMS_LUA_TMP := $(EXTRACTED_ENUMS_LUA).tmp
inotify_decls_lua := inotify_decls.lua
inotify_decls_lua_tmp := $(inotify_decls_lua).tmp
posix_decls_lua := posix_decls.lua
posix_decls_lua_tmp := $(posix_decls_lua).tmp

LJCLANG_SUPPORT_SO := libljclang_support.so

GENERATED_FILES_STAGE_1 := $(INDEX_H_LUA)
GENERATED_FILES_STAGE_2 := $(GENERATED_FILES_STAGE_1) $(EXTRACTED_ENUMS_LUA)

.PHONY: all clean veryclean bootstrap doc test install

all: $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_2)

clean:
	rm -f $(LJCLANG_SUPPORT_SO)

veryclean: clean
	rm -f $(GENERATED_FILES_STAGE_2) $(EXTRACTED_ENUMS_LUA_TMP) $(EXTRACTED_ENUMS_LUA).reject \
		$(inotify_decls_lua) $(inotify_decls_lua_tmp) \
		$(posix_decls_lua) $(posix_decls_lua_tmp)

bootstrap: $(EXTRACTED_ENUMS_LUA)

# ---------- Build ----------

$(LJCLANG_SUPPORT_SO): ljclang_support.cpp Makefile
	$(CXX) $(cxxflags) -shared $< $(lib) -o $@

$(INDEX_H_LUA): ./createheader.lua $(incdir)/clang-c/*
	@$(luajit) ./createheader.lua $(incdir)/clang-c > $@
	@printf "* \033[1mGenerated $@ from files in $(incdir)/clang-c \033[0m\n"

EXTRACT_CMD_ENV := LD_LIBRARY_PATH="$(libdir):$(THIS_DIR)" incdir="$(incdir)"

CHECK_EXTRACTED_ENUMS_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require('ffi').cdef[[typedef int time_t;]]" \
    -e "require '$(subst .lua,,$(INDEX_H_LUA))'" \
    -e "l=require '$(subst .lua,,$(EXTRACTED_ENUMS_LUA))'" \
    -e "assert(l.CursorKindName[1] ~= nil)"

.SILENT: $(EXTRACTED_ENUMS_LUA)

$(EXTRACTED_ENUMS_LUA): $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_1) $(incdir)/clang-c/*
	echo 'return {}' > $(EXTRACTED_ENUMS_LUA)
    # Do the extraction.
	$(EXTRACT_CMD_ENV) ./print_extracted_enums_lua.sh > $(EXTRACTED_ENUMS_LUA_TMP)
    # Check that we can load the generated file in Lua.
	mv $(EXTRACTED_ENUMS_LUA_TMP) $@
	($(CHECK_EXTRACTED_ENUMS_CMD) && \
	    printf "* \033[1mGenerated $@\033[0m\n") \
	|| (printf "* \033[1;31mError\033[0m generating $@\n" && \
	    mv $@ $@.reject && false)

# Linux-specific functionality exposed to us

inotify_h ?= /usr/include/x86_64-linux-gnu/sys/inotify.h

CHECK_EXTRACTED_INOTIFY_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require'inotify_decls'"

$(inotify_decls_lua): $(EXTRACTED_ENUMS_LUA) $(inotify_h)
	@echo 'local ffi=require"ffi"' > $(inotify_decls_lua_tmp)
	@echo 'ffi.cdef[[' >> $(inotify_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w FunctionDecl -p '^inotify_' $(inotify_h) >> $(inotify_decls_lua_tmp)
	@echo ']]' >> $(inotify_decls_lua_tmp)
	@echo 'return ffi.new[[struct {' >> $(inotify_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -C -p '^IN_' -s '^IN_' $(inotify_h) >> $(inotify_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^IN_' -s '^IN_' $(inotify_h) >> $(inotify_decls_lua_tmp)
	@echo '}]]' >> $(inotify_decls_lua_tmp)
	@mv $(inotify_decls_lua_tmp) $@
	@($(CHECK_EXTRACTED_INOTIFY_CMD) && \
	    printf "* \033[1mGenerated $@\033[0m\n") \
	|| (printf "* \033[1;31mError\033[0m generating $@\n" && \
	    mv $@ $@.reject && false)

# POSIX functionality exposed to us

poll_h ?= /usr/include/x86_64-linux-gnu/sys/poll.h
errno_h ?= /usr/include/errno.h
fcntl_h ?= /usr/include/fcntl.h
signal_h ?= /usr/include/signal.h

CHECK_EXTRACTED_POSIX_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require'posix_decls'"

$(posix_decls_lua): $(EXTRACTED_ENUMS_LUA) $(poll_h)
	@echo 'local ffi=require"ffi"' > $(posix_decls_lua_tmp)
	@echo 'return { POLL = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^POLLIN' -s '^POLL' $(poll_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'E = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^EAGAIN' -s '^E' $(errno_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'O = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^O_RDONLY' -s '^O_' $(fcntl_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^O_WRONLY' -s '^O_' $(fcntl_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^O_NONBLOCK' -s '^O_' $(fcntl_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'SIG = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^SIGINT' -s '^SIG' $(signal_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^SIGPIPE' -s '^SIG' $(signal_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^SIG_BLOCK' -s '^SIG_' $(signal_h) >> $(posix_decls_lua_tmp)
	@echo '}]] }' >> $(posix_decls_lua_tmp)
	@mv $(posix_decls_lua_tmp) $@
	@($(CHECK_EXTRACTED_POSIX_CMD) && \
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

test: $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_2)
	LLVM_LIBDIR="$(libdir)" $(SHELL) ./run_tests.sh

sed_common_commands := s|@LJCLANG_DEV_DIR@|$(THIS_DIR)|g; s|@LLVM_BINDIR@|$(bindir)|g; s|@LLVM_LIBDIR@|$(libdir)|g;

install: $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_2) $(inotify_decls_lua) $(posix_decls_lua)
	sed "$(sed_common_commands) s|@APPLICATION@|mgrep|g" ./app.sh.in > $(BINDIR)/mgrep
	sed "$(sed_common_commands) s|@APPLICATION@|watch_compile_commands|g" ./app.sh.in > $(BINDIR)/watch_compile_commands
	chmod +x $(BINDIR)/mgrep
	chmod +x $(BINDIR)/watch_compile_commands

# This target is merely there to create compile_commands.json entries for the test
# source files in case we are invoked with 'bear'.
compile_commands.json: $(patsubst %.cpp,%.o,$(wildcard test_data/*.cpp))

test_data/%.o: test_data/%.cpp
	$(CXX) -c $(subst -Werror,,$(cxxflags)) $< -o /dev/null
