
OS := $(shell uname -s)
MACHINE := $(shell uname -m)
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
ifeq ($(MACHINE),armv7l)
    # On Raspbian, assume that a recent LLVM is used.
    CXX=clang++
endif

bindir := $(shell $(llvm-config) --bindir)
incdir := $(shell $(llvm-config) --includedir)
libdir := $(shell $(llvm-config) --libdir)
lib := -L$(libdir) -lclang

llvm_libdir_include := $(libdir)/clang/$(llvm_version)/include

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
LIBDIR_INCLUDE_LUA := ./llvm_libdir_include.lua
EXTRACTED_ENUMS_LUA := ljclang_extracted_enums.lua
EXTRACTED_ENUMS_LUA_TMP := $(EXTRACTED_ENUMS_LUA).tmp
linux_decls_lua := ljclang_linux_decls.lua
linux_decls_lua_tmp := $(linux_decls_lua).tmp
posix_decls_lua := posix_decls.lua
posix_decls_lua_tmp := $(posix_decls_lua).tmp

LJCLANG_SUPPORT_SO := libljclang_support.so
LJPOSIX_SO := libljposix.so
SHARED_LIBRARIES := $(LJCLANG_SUPPORT_SO) $(LJPOSIX_SO)

GENERATED_FILES_STAGE_1 := $(INDEX_H_LUA) $(LIBDIR_INCLUDE_LUA)
GENERATED_FILES_STAGE_2 := $(GENERATED_FILES_STAGE_1) $(EXTRACTED_ENUMS_LUA)

.PHONY: all app_dependencies apps clean veryclean bootstrap doc test install install-dev _install_common

all: $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_2)

apps: extractdecls.app.lua watch_compile_commands.app.lua

clean:
	rm -f $(SHARED_LIBRARIES) $(apps)

veryclean: clean
	rm -f $(GENERATED_FILES_STAGE_2) $(EXTRACTED_ENUMS_LUA_TMP) $(EXTRACTED_ENUMS_LUA).reject \
		$(linux_decls_lua) $(linux_decls_lua_tmp) \
		$(posix_decls_lua) $(posix_decls_lua_tmp)

bootstrap: $(EXTRACTED_ENUMS_LUA)

# ---------- Build ----------

$(LJCLANG_SUPPORT_SO): ljclang_support.cpp Makefile
	$(CXX) $(cxxflags) -shared $< $(lib) -o $@

$(LJPOSIX_SO): ljposix.cpp Makefile
	$(CXX) $(cxxflags) -shared $< -o $@

$(INDEX_H_LUA): ./createheader.lua $(incdir)/clang-c/*
	@$(luajit) ./createheader.lua $(incdir)/clang-c > $@
	@printf "* \033[1mGenerated $@ from files in $(incdir)/clang-c \033[0m\n"

$(LIBDIR_INCLUDE_LUA): Makefile config.make
	@echo "return { '$(llvm_libdir_include)' }" > $@

EXTRACT_CMD_ENV := LD_LIBRARY_PATH="$(libdir):$(THIS_DIR)" incdir="$(incdir)"

CHECK_EXTRACTED_ENUMS_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require('ffi').cdef[[typedef int time_t;]]" \
    -e "require '$(subst .lua,,$(INDEX_H_LUA))'" \
    -e "l=require '$(subst .lua,,$(EXTRACTED_ENUMS_LUA))'" \
    -e "assert(l.CursorKindName[1] ~= nil)"

.SILENT: $(EXTRACTED_ENUMS_LUA)

$(EXTRACTED_ENUMS_LUA): ./print_extracted_enums_lua.sh $(incdir)/clang-c/*
$(EXTRACTED_ENUMS_LUA): $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_1)
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

mman_h ?= /usr/include/asm-generic/mman.h
sys_h := ./dev/sys.h

CHECK_EXTRACTED_INOTIFY_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require'ljclang_linux_decls'"

$(linux_decls_lua): $(EXTRACTED_ENUMS_LUA) $(sys_h) Makefile
	@echo 'local ffi=require"ffi"' > $(linux_decls_lua_tmp)
	@echo 'ffi.cdef[[' >> $(linux_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w FunctionDecl -p '^inotify_' $(sys_h) >> $(linux_decls_lua_tmp)
	@echo ']]' >> $(linux_decls_lua_tmp)
	@echo 'return { IN = ffi.new[[struct {' >> $(linux_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -C -p '^IN_' -s '^IN_' $(sys_h) >> $(linux_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^IN_' -s '^IN_' $(sys_h) >> $(linux_decls_lua_tmp)
	@echo '}]], ' >> $(linux_decls_lua_tmp)
	@echo 'MAP = ffi.new[[struct {' >> $(linux_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^MAP_ANONYMOUS$$' -s '^MAP_' $(mman_h) >> $(linux_decls_lua_tmp)
	@echo '}]], ' >> $(linux_decls_lua_tmp)
	@echo '}' >> $(linux_decls_lua_tmp)
	@mv $(linux_decls_lua_tmp) $@
	@($(CHECK_EXTRACTED_INOTIFY_CMD) && \
	    printf "* \033[1mGenerated $@\033[0m\n") \
	|| (printf "* \033[1;31mError\033[0m generating $@\n" && \
	    mv $@ $@.reject && false)

# POSIX functionality exposed to us

errno_h ?= /usr/include/errno.h
fcntl_h ?= /usr/include/fcntl.h
signal_h ?= /usr/include/signal.h
time_h ?= /usr/include/time.h
unistd_h ?= /usr/include/unistd.h

CHECK_EXTRACTED_POSIX_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require'posix_decls'"

$(posix_decls_lua): $(EXTRACTED_ENUMS_LUA) $(sys_h) Makefile
	@echo 'local ffi=require"ffi"' > $(posix_decls_lua_tmp)
	@echo 'return { POLL = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^POLLIN$$' -s '^POLL' $(sys_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'AF = ffi.new[[struct {' >> $(posix_decls_lua_tmp)  # NOTE: PF -> AF
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^PF_INET$$' -s '^PF_' $(sys_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'CLOCK = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^CLOCK_MONOTONIC$$' -s '^CLOCK_' $(time_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'E = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^EAGAIN$$' -s '^E' $(errno_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^EPIPE$$' -s '^E' $(errno_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'MAP = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^MAP_[SPF][HRI][AIX][^_]+$$' -s '^MAP_' $(mman_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'O = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^O_RDONLY$$' -s '^O_' $(fcntl_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^O_WRONLY$$' -s '^O_' $(fcntl_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^O_RDWR$$' -s '^O_' $(fcntl_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^O_NONBLOCK$$' -s '^O_' $(fcntl_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'PROT = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^PROT_[RWN]' -s '^PROT_' $(mman_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo '_SC = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w EnumConstantDecl -C -p '^_SC_PAGESIZE$$' -s '^_SC_' $(unistd_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'SIG = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^SIGINT$$' -s '^SIG' $(signal_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^SIGPIPE$$' -s '^SIG' $(signal_h) >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w MacroDefinition -C -p '^SIG_BLOCK$$' -s '^SIG_' $(signal_h) >> $(posix_decls_lua_tmp)
	@echo '}]], ' >> $(posix_decls_lua_tmp)
	@echo 'SOCK = ffi.new[[struct {' >> $(posix_decls_lua_tmp)
	@$(EXTRACT_CMD_ENV) ./extractdecls.lua -w EnumConstantDecl -C -p '^SOCK_STREAM$$' -s '^SOCK_' $(sys_h) >> $(posix_decls_lua_tmp)
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

test: $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_2)
	LLVM_LIBDIR="$(libdir)" $(SHELL) ./run_tests.sh

sed_common_commands := s|@LJCLANG_DEV_DIR@|$(THIS_DIR)|g; s|@LLVM_BINDIR@|$(bindir)|g; s|@LLVM_LIBDIR@|$(libdir)|g;

app_dependencies: $(linux_decls_lua) $(posix_decls_lua)

extractdecls.app.lua: extractdecls.lua mkapp.lua $(GENERATED_FILES_STAGE_1) app_dependencies
	@$(EXTRACT_CMD_ENV) $(luajit) -l mkapp $< -Q > /dev/null
	@printf "* \033[1mCreated $@\033[0m\n"

watch_compile_commands.app.lua: watch_compile_commands.lua mkapp.lua $(GENERATED_FILES_STAGE_2) app_dependencies
	@$(EXTRACT_CMD_ENV) $(luajit) -l mkapp $< -x > /dev/null
	@printf "* \033[1mCreated $@\033[0m\n"

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
	chmod +x $(BINDIR)/extractdecls
	@if grep -c EOF watch_compile_commands.app.lua > /dev/null; then echo "ERROR: 'EOF' in Lua source!"; false; else true; fi
	sed "$(sed_common_commands)" $(pre) | cat - watch_compile_commands.app.lua $(post) > $(BINDIR)/watch_compile_commands
	@rm -f watch_compile_commands.app.lua
	chmod +x $(BINDIR)/watch_compile_commands

install-dev: $(SHARED_LIBRARIES) $(GENERATED_FILES_STAGE_2) app_dependencies _install_common
	sed "$(sed_common_commands) s|@APPLICATION@|extractdecls|g" ./app.sh.in > $(BINDIR)/extractdecls
	chmod +x $(BINDIR)/extractdecls
	sed "$(sed_common_commands) s|@APPLICATION@|watch_compile_commands|g" ./app.sh.in > $(BINDIR)/watch_compile_commands
	chmod +x $(BINDIR)/watch_compile_commands

# This target is merely there to create compile_commands.json entries for the test
# source files in case we are invoked with 'bear'.
compile_commands.json: $(patsubst %.cpp,%.o,$(wildcard test_data/*.cpp))

test_data/%.o: test_data/%.cpp
	$(CXX) -c $(subst -Werror,,$(cxxflags)) $< -o /dev/null
