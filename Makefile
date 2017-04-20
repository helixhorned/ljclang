
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
EXTRACT_OPTS := -R -p '^CXCursor_' -x '_First' -x '_Last' -x '_GCCAsmStmt' -x '_MacroInstantiation' -s '^CXCursor_' \
    -1 'return { name={' -2 '}, }' -Q

# Generate list of CXCursorKind names
bootstrap: libljclang_support$(so)
	@echo 'return {}' > $(CKIND_LUA)
	LD_LIBRARY_PATH="$(libdir):$(THIS_DIR)" $(luajit) ./extractdecls.lua $(EXTRACT_OPTS) $(incdir)/clang-c/Index.h > $(CKIND_LUA).tmp
	@mv $(CKIND_LUA).tmp $(CKIND_LUA)
	@printf "\033[1mGenerated $(CKIND_LUA)\033[0m\n"

doc: README.md.in ljclang.lua
	$(luajit) $(THIS_DIR)/make_docs.lua $^ > README.md
	which $(MARKDOWN) && $(MARKDOWN) README.md > README.html

test: libljclang_support$(so)
	LLVM_LIBDIR="$(libdir)" $(SHELL) $(THIS_DIR)/run_tests.sh

install: libljclang_support$(so)
	sed "s|LJCLANG_DEV_DIR|$(THIS_DIR)|g; s|LLVM_LIBDIR|$(libdir)|g;" ./mgrep.sh.in > $(BINDIR)/mgrep
	chmod +x $(BINDIR)/mgrep
