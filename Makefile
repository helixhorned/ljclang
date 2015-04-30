
OS := $(shell uname -s)
MINGW := $(findstring MINGW,$(OS))
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))


########## PATHS ##########

ifeq ($(OS),Linux)
    inc := /usr/include
    libdir := /usr/lib
    lib := -L$(libdir) -lclang
    so := .so
else
 ifeq ($(MINGW),MINGW)
    rdir := /f/g/mod/clang3.3_march2013
    inc := $(rdir)/include
    lib := $(rdir)/lib/libclang.lib $(rdir)/libclang.dll
    so := .dll
 else
    $(error unknown platform)
 endif
endif

luajit := luajit
asciidoc := asciidoctor


########## OPTIONS ##########

OPTLEV ?= 2
DEBUG ?= 0
SAN ?= 0
WARN := -std=c99 -pedantic -Wall -Werror-implicit-function-declaration
CFLAGS :=

ifneq ($(SAN),0)
    CFLAGS += -fsanitize=address,undefined
endif

ifneq ($(DEBUG),0)
    CFLAGS += -g
endif

ifeq ($(OS),Linux)
    CFLAGS += -I$(inc) -fPIC
else
 ifeq ($(MINGW),MINGW)
    CFLAGS += -I$(inc) $(lib)
 endif
endif


########## RULES ##########

libljclang_support$(so): ljclang_support.c Makefile
	$(CC) $(CFLAGS) $(WARN) -O$(OPTLEV) -shared $< $(lib) -o $@


.PHONY: clean bootstrap doc

clean:
	rm -f libljclang_support$(so)

CKIND_LUA := ljclang_cursor_kind.lua
EXTRACT_OPTS := -R -p '^CXCursor_' -x '_First' -x '_Last' -x '_GCCAsmStmt' -x '_MacroInstantiation' -s '^CXCursor_' \
    -1 'return { name={' -2 '}, }' -Q

# Generate list of CXCursorKind names
bootstrap:
	@echo 'return {}' > $(CKIND_LUA)
	@LD_LIBRARY_PATH=$(THIS_DIR) $(luajit) ./extractdecls.lua $(EXTRACT_OPTS) $(inc)/clang-c/Index.h > $(CKIND_LUA).tmp
	@mv $(CKIND_LUA).tmp $(CKIND_LUA)
	@printf "\033[1mGenerated $(CKIND_LUA)\033[0m\n"

doc:
	$(asciidoc) README.adoc
