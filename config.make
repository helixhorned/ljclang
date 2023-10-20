
# Directory to install applications. The resulting scripts reference THIS_DIR (i.e. the
# development directory) if doing 'install-dev'.
BINDIR ?= $(HOME)/bin

LLVM_MAJOR_VERSION=17
LLVM_CONFIG ?= llvm-config-$(LLVM_MAJOR_VERSION)

luajit := luajit

# Will use this Markdown processor for .md -> .html if it is found:
MARKDOWN := cmark
