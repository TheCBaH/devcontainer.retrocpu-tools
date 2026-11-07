#!/bin/sh
# Builds static asl, p2bin and p2hex from a pristine source tree into $2.
# usage: build-asl.sh <source-dir> <install-prefix>
set -eu
src=$1 prefix=$2
work=$(mktemp -d)
cp -a "$src/." "$work"
cd "$work"
cat > Makefile.def <<MK
OBJDIR =
CC = gcc
CFLAGS = -O2
HOST_OBJEXTENSION = .o
LD = \$(CC)
LDFLAGS = -static
HOST_EXEXTENSION =
TARG_OBJDIR = \$(OBJDIR)
TARG_CC = \$(CC)
TARG_CFLAGS = \$(CFLAGS)
TARG_OBJEXTENSION = \$(HOST_OBJEXTENSION)
TARG_LD = \$(LD)
TARG_LDFLAGS = \$(LDFLAGS)
TARG_EXEXTENSION = \$(HOST_EXEXTENSION)
INSTROOT := $prefix
MK
make -j"$(nproc)" asl p2bin p2hex
mkdir -p "$prefix/bin"
install -m755 asl p2bin p2hex "$prefix/bin"
