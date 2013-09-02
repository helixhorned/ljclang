
clang-c := /usr/local/include/clang-c
so := .so

THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
luajit=luajit

OPTLEV ?= 2
DEBUG ?= 0
SAN ?= 0
WARN := -pedantic -Wall -Werror-implicit-function-declaration
CFLAGS :=

ifneq ($(SAN),0)
    CFLAGS += -fsanitize=address,undefined
endif

ifneq ($(DEBUG),0)
    CFLAGS += -g
endif

libljclang_support$(so): ljclang_support.c Makefile
	$(CC) $(CFLAGS) $(WARN) -O$(OPTLEV) -shared -fPIC $< -lclang -o $@


.PHONY: clean bootstrap

clean:
	rm -f libljclang_support$(so)

CKIND_LUA := ljclang_cursor_kind.lua
EXTRACT_OPTS := -R -p '^CXCursor_' -x '_First' -x '_Last' -x '_GCCAsmStmt' -x '_MacroInstantiation' -s '^CXCursor_' \
    -1 'return { name={' -2 '}, }' -Q

# Generate list of CXCursorKind names
bootstrap:
	@echo 'return {}' > $(CKIND_LUA)
	@LD_LIBRARY_PATH=$(THIS_DIR) $(luajit) ./extractdecls.lua $(EXTRACT_OPTS) $(clang-c)/Index.h > $(CKIND_LUA).tmp
	@mv $(CKIND_LUA).tmp $(CKIND_LUA)
	@printf "\033[1mGenerated $(CKIND_LUA)\033[0m\n"
