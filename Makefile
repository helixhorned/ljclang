
OS := $(shell uname -s)
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Directory to install scripts (referencing THIS_DIR, i.e. the development directory).
BINDIR ?= /usr/local

LLVM_CONFIG ?= llvm-config
llvm-config := $(shell which $(LLVM_CONFIG))

luajit := luajit

# Will use this Markdown processor for .md -> .html if it is found:
markdown := cmark

ifeq ($(llvm-config),)
    $(error "$(LLVM_CONFIG) not found, use LLVM_CONFIG=<path/to/llvm-config> make")
endif

llvm_version := $(shell $(llvm-config) --version)


########## PATHS ##########

ifneq ($(OS),Linux)
    $(error "Unsupported OS")
endif

incdir := $(shell $(llvm-config) --includedir)
libdir := $(shell $(llvm-config) --libdir)
lib := -L$(libdir) -lclang


########## OPTIONS ##########

cxxflags := -std=c++14 -I$(incdir) -fPIC
cxxflags += -DLJCLANG_LLVM_VERSION='"$(llvm_version)"'
cxxflags += -Werror -Wall -Wextra -Wold-style-cast -pedantic

# NOTE: Additional flags (such as for enabling sanitizers or debugging symbols)
# can be specified with CXXFLAGS on the command-line, and they will be appended.
CXXFLAGS ?=
cxxflags += $(CXXFLAGS)


########## RULES ##########

INDEX_H_LUA := ljclang_Index_h.lua
CKIND_LUA := ljclang_cursor_kind.lua
CKIND_LUA_TMP := $(CKIND_LUA).tmp

LJCLANG_SUPPORT_SO := libljclang_support.so

GENERATED_FILES_STAGE_1 := $(INDEX_H_LUA)
GENERATED_FILES_STAGE_2 := $(GENERATED_FILES_STAGE_1) $(CKIND_LUA)

.PHONY: all clean veryclean bootstrap doc test install

all: $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_2)

clean:
	rm -f $(LJCLANG_SUPPORT_SO)

veryclean: clean
	rm -f $(GENERATED_FILES_STAGE_2) $(CKIND_LUA_TMP)

bootstrap: $(CKIND_LUA)

# ---------- Build ----------

$(LJCLANG_SUPPORT_SO): ljclang_support.cpp Makefile
	$(CXX) $(cxxflags) -shared $< $(lib) -o $@

$(INDEX_H_LUA): ./createheader.lua $(incdir)/clang-c/*
	@$(luajit) ./createheader.lua $(incdir)/clang-c > $@
	@printf "* \033[1mGenerated $@ from files in $(incdir)/clang-c \033[0m\n"

EXTRACT_OPTS_KINDS := -Q -R -p '^CXCursor_' -s '^CXCursor_' \
    -x '_First' -x '_Last' -x '_GCCAsmStmt' -x '_MacroInstantiation' \
    -1 'CursorKindName = {' -2 '},'

EXTRACT_OPTS_ENUM := -Q \
    -f "return f('    static const int %s = %s;', k:sub(enumPrefixLength+1), k)" \
    -1 "$$enumName = ffi.new[[struct{" -2 "}]],"

ENUMS := ErrorCode SaveError DiagnosticSeverity ChildVisitResult

EXTRACT_CMD_ENV := LD_LIBRARY_PATH="$(libdir):$(THIS_DIR)"
EXTRACT_CMD := $(EXTRACT_CMD_ENV) ./extractdecls.lua -A -I$(incdir) $(incdir)/clang-c/Index.h

.SILENT: $(CKIND_LUA)

# Generate list of CXCursorKind names
$(CKIND_LUA): $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_1) $(incdir)/clang-c/*
	echo 'return {}' > $(CKIND_LUA)
    # -- Extract enums
	echo 'local ffi=require"ffi"' > $(CKIND_LUA_TMP)
	echo 'return {' >> $(CKIND_LUA_TMP)
	for enumName in $(ENUMS); do \
	    $(EXTRACT_CMD) $(EXTRACT_OPTS_ENUM) -e "^CX$$enumName$$" >> $(CKIND_LUA_TMP); \
	done
    # -- Extract cursor kinds
	$(EXTRACT_CMD) $(EXTRACT_OPTS_KINDS) >> $(CKIND_LUA_TMP)
	echo '}' >> $(CKIND_LUA_TMP)
    # -- Done extracting
	mv $(CKIND_LUA_TMP) $(CKIND_LUA)
	printf "* \033[1mGenerated $(CKIND_LUA)\033[0m\n"

# ---------- Post-build ----------

.SILENT: doc

doc: README.md.in ljclang.lua ./make_docs.lua
	$(luajit) ./make_docs.lua $^ > README.md \
	    && printf "* \033[1mGenerated README.md\033[0m\n"
	(which $(markdown) > /dev/null && $(markdown) README.md > README.html \
	    && printf "* \033[1mGenerated README.html\033[0m\n") \
	|| echo "* Did not generate README.html"

test: $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_2)
	LLVM_LIBDIR="$(libdir)" $(SHELL) ./run_tests.sh

install: $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_2)
	sed "s|LJCLANG_DEV_DIR|$(THIS_DIR)|g; s|LLVM_LIBDIR|$(libdir)|g;" ./mgrep.sh.in > $(BINDIR)/mgrep
	chmod +x $(BINDIR)/mgrep
