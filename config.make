
# Directory to install scripts (referencing THIS_DIR, i.e. the development directory).
BINDIR ?= /usr/local/bin

LLVM_CONFIG ?= llvm-config-7

luajit := luajit

# Will use this Markdown processor for .md -> .html if it is found:
MARKDOWN := cmark