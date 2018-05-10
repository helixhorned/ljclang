
OS := $(shell uname -s)
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Directory to install scripts (referencing THIS_DIR, i.e. the development directory).
BINDIR ?= /usr/local

LLVM_CONFIG ?= llvm-config
llvm-config := $(shell which $(LLVM_CONFIG))

luajit := luajit

# Will use this Markdown processor for .md -> .html if it is found:
MARKDOWN := cmark
markdown := $(shell which $(MARKDOWN))

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

LJCLANG_SUPPORT_SO := libljclang_support.so

GENERATED_FILES_STAGE_1 := $(INDEX_H_LUA)
GENERATED_FILES_STAGE_2 := $(GENERATED_FILES_STAGE_1) $(EXTRACTED_ENUMS_LUA)

.PHONY: all clean veryclean bootstrap doc test install

all: $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_2)

clean:
	rm -f $(LJCLANG_SUPPORT_SO)

veryclean: clean
	rm -f $(GENERATED_FILES_STAGE_2) $(EXTRACTED_ENUMS_LUA_TMP)

bootstrap: $(EXTRACTED_ENUMS_LUA)

# ---------- Build ----------

$(LJCLANG_SUPPORT_SO): ljclang_support.cpp Makefile
	$(CXX) $(cxxflags) -shared $< $(lib) -o $@

$(INDEX_H_LUA): ./createheader.lua $(incdir)/clang-c/*
	@$(luajit) ./createheader.lua $(incdir)/clang-c > $@
	@printf "* \033[1mGenerated $@ from files in $(incdir)/clang-c \033[0m\n"

EXTRACT_OPTS_KINDS := -Q -R -e 'CXCursorKind' -p '^CXCursor_' -s '^CXCursor_' \
    -x '_First' -x '_Last' -x '_GCCAsmStmt' -x '_MacroInstantiation' \
    -1 'CursorKindName = {' -2 '},'

EXTRACT_OPTS_ENUM := -Q \
    -f "return f('    static const int %s = %s;', k:sub(enumPrefixLength+1), k)" \
    -1 "$$enumName = ffi.new[[struct{" -2 "}]],"

ENUMS := ErrorCode SaveError DiagnosticSeverity ChildVisitResult

EXTRACT_CMD_ENV := LD_LIBRARY_PATH="$(libdir):$(THIS_DIR)"
EXTRACT_CMD := $(EXTRACT_CMD_ENV) ./extractdecls.lua -A -I$(incdir) $(incdir)/clang-c/Index.h

CHECK_EXTRACTED_ENUMS_CMD := $(EXTRACT_CMD_ENV) $(luajit) \
    -e "require('ffi').cdef[[typedef int time_t;]]" \
    -e "require '$(subst .lua,,$(INDEX_H_LUA))'" \
    -e "l=require '$(subst .lua,,$(EXTRACTED_ENUMS_LUA))'" \
    -e "assert(l.CursorKindName[1] ~= nil)"

.SILENT: $(EXTRACTED_ENUMS_LUA)

$(EXTRACTED_ENUMS_LUA): $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_1) $(incdir)/clang-c/*
	echo 'return {}' > $(EXTRACTED_ENUMS_LUA)
    # -- Extract enums
	echo 'local ffi=require"ffi"' > $(EXTRACTED_ENUMS_LUA_TMP)
	echo 'return {' >> $(EXTRACTED_ENUMS_LUA_TMP)
	for enumName in $(ENUMS); do \
	    $(EXTRACT_CMD) $(EXTRACT_OPTS_ENUM) -e "^CX$$enumName$$" >> $(EXTRACTED_ENUMS_LUA_TMP); \
	done
    # -- Extract cursor kinds
	$(EXTRACT_CMD) $(EXTRACT_OPTS_KINDS) >> $(EXTRACTED_ENUMS_LUA_TMP)
	echo '}' >> $(EXTRACTED_ENUMS_LUA_TMP)
    # -- Done extracting
	mv $(EXTRACTED_ENUMS_LUA_TMP) $(EXTRACTED_ENUMS_LUA)
	($(CHECK_EXTRACTED_ENUMS_CMD) && \
	    printf "* \033[1mGenerated $(EXTRACTED_ENUMS_LUA)\033[0m\n") \
	|| (printf "* \033[1;31mError\033[0m generating $(EXTRACTED_ENUMS_LUA)\n" && \
	    mv $(EXTRACTED_ENUMS_LUA) $(EXTRACTED_ENUMS_LUA)_ && false)

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

install: $(LJCLANG_SUPPORT_SO) $(GENERATED_FILES_STAGE_2)
	sed "s|LJCLANG_DEV_DIR|$(THIS_DIR)|g; s|LLVM_LIBDIR|$(libdir)|g;" ./mgrep.sh.in > $(BINDIR)/mgrep
	chmod +x $(BINDIR)/mgrep

# This target is merely there to create compile_commands.json entries for the test
# source files in case we are invoked with 'bear'.
compile_commands.json: $(patsubst %.cpp,%.o,$(wildcard test_data/*.cpp))

test_data/%.o: test_data/%.cpp
	$(CXX) -c $(subst -Werror,,$(cxxflags)) $< -o /dev/null
