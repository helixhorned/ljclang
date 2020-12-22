
# Directory to install applications. The resulting scripts reference THIS_DIR (i.e. the
# development directory) if doing 'install-dev'.
BINDIR ?= $(HOME)/bin

LLVM_CONFIG ?= llvm-config-11

luajit := luajit

# Will use this Markdown processor for .md -> .html if it is found:
MARKDOWN := cmark
