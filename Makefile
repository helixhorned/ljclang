
OS := $(shell uname -s)
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Directory to install scripts (referencing THIS_DIR, i.e. the development directory).
BINDIR ?= /usr/local

LLVM_CONFIG ?= llvm-config
llvm-config := $(shell which $(LLVM_CONFIG))

MARKDOWN := cmark

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
so := .so

luajit := luajit
asciidoc := asciidoctor


########## OPTIONS ##########

OPTLEV ?= 2
DEBUG ?= 0
SAN ?= 0
WARN := -std=c++14 -Wall -Wextra -Wold-style-cast -pedantic
CXXFLAGS ?=

ifneq ($(SAN),0)
    CXXFLAGS += -fsanitize=address,undefined
endif

ifneq ($(DEBUG),0)
    CXXFLAGS += -g
endif

CXXFLAGS += -I$(incdir) -fPIC
CXXFLAGS += -DLJCLANG_LLVM_VERSION='"$(llvm_version)"'

########## RULES ##########

all: libljclang_support$(so) ljclang_Index_h.lua bootstrap

libljclang_support$(so): ljclang_support.cpp Makefile
	$(CXX) $(CXXFLAGS) $(WARN) -O$(OPTLEV) -shared $< $(lib) -o $@


.PHONY: clean ljclang_Index_h.lua bootstrap doc

clean:
	rm -f libljclang_support$(so)

ljclang_Index_h.lua:
	$(luajit) ./createheader.lua $(incdir)/clang-c > $@

CKIND_LUA := ljclang_cursor_kind.lua
CKIND_LUA_TMP := $(CKIND_LUA).tmp

EXTRACT_OPTS_KINDS := -Q -R -p '^CXCursor_' -s '^CXCursor_' \
    -x '_First' -x '_Last' -x '_GCCAsmStmt' -x '_MacroInstantiation' \
    -1 'CursorKindName = {' -2 '},'

EXTRACT_OPTS_ENUM := -Q \
    -f "return f('    static const int %s = %s;', k:sub(enumPrefixLength+1), k)" \
    -1 "$$enumName = ffi.new[[struct{" -2 "}]],"

ENUMS := ErrorCode SaveError DiagnosticSeverity ChildVisitResult

EXTRACT_CMD_ENV := LD_LIBRARY_PATH="$(libdir):$(THIS_DIR)"
EXTRACT_CMD := $(EXTRACT_CMD_ENV) ./extractdecls.lua -A -I$(incdir) $(incdir)/clang-c/Index.h

.SILENT: bootstrap

# Generate list of CXCursorKind names
bootstrap: libljclang_support$(so)
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

doc: README.md.in ljclang.lua
	$(luajit) ./make_docs.lua $^ > README.md
	which $(MARKDOWN) && $(MARKDOWN) README.md > README.html

test: libljclang_support$(so)
	LLVM_LIBDIR="$(libdir)" $(SHELL) ./run_tests.sh

install: libljclang_support$(so)
	sed "s|LJCLANG_DEV_DIR|$(THIS_DIR)|g; s|LLVM_LIBDIR|$(libdir)|g;" ./mgrep.sh.in > $(BINDIR)/mgrep
	chmod +x $(BINDIR)/mgrep
