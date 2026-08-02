# SPDX-License-Identifier: GPL-3.0-or-later
#
# librc8650 --- static + shared library and the rc8650say CLI.
#
#   make            build lib + CLI
#   make static     libr8650.a only
#   make shared     shared library only
#   make install    PREFIX=/usr/local
#   make win64      rc8650_64.dll  (mingw-w64 cross build, for the NVDA add-on)
#   make win32      rc8650_32.dll  (ditto, for NVDA older than 2025.2)
#   make windows    both DLLs
#
# The emulator core is the patched gdb-14.2 sim/m32c tree; SIM points at it.
# sim/rc865x-sim.patch reconstructs that tree from a stock gdb-14.2 -- see
# "Getting the emulator core" in README.md.

# The simulator sources have lived under both gdb-14.2/sim and gdb-14.2/gdbsim;
# take whichever is there. A -I pointing at a directory that does not exist is
# not an error, so getting this wrong does not fail the compile - it fails the
# *link*, or worse leaves a stale archive in place looking like a fresh build.
SIM     ?= $(firstword $(wildcard ../gdb-14.2/gdbsim/m32c ../gdb-14.2/sim/m32c))
PREFIX  ?= /usr/local

ifeq ($(SIM),)
$(error cannot find the m32c simulator sources: looked for \
../gdb-14.2/gdbsim/m32c and ../gdb-14.2/sim/m32c. Set SIM=<path> to override)
endif

# Two of the core's sources -- the r8c and m32c instruction decoders -- are
# generated from .opc files by opc2c, a build-time tool that ships in the
# simulator tree. Configuring and building all of gdb just to get them is not
# necessary: opc2c is a standalone program, and the only header it wants that
# a gdb build tree would have generated is defs.h, which is shimmed here. So
# generate them into build/gen by default, while still deferring to an
# existing gdb sim build directory if one happens to be next door.
GEN     ?= $(firstword $(wildcard ../build-sim/sim/m32c) build/gen)

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SHLIB   := librc8650.dylib
  SHFLAGS := -dynamiclib -install_name @rpath/$(SHLIB)
else
  SHLIB   := librc8650.so
  SHFLAGS := -shared -Wl,-soname,$(SHLIB)
endif

CC      ?= cc
CFLAGS  ?= -O2 -g
# The vendored simulator sources predate several of clang's default warnings;
# they are not ours to clean up, so quiet them rather than drown real ones.
WARNOFF := -Wno-implicit-function-declaration -Wno-incompatible-pointer-types \
           -Wno-int-conversion -Wno-unused-result
CFLAGS  += -fPIC -I. -I$(SIM) -I$(GEN) $(WARNOFF)
# The output stage's biquad is designed with cos()/sin().
LDLIBS  += -lm

CORE    := $(SIM)/mem.c $(SIM)/reg.c $(SIM)/srcdest.c $(SIM)/misc.c \
           $(SIM)/int.c $(GEN)/r8c.c $(GEN)/m32c.c
LIBSRC  := rc8650.c stubs.c $(CORE)
LIBOBJ  := $(addprefix build/,$(notdir $(LIBSRC:.c=.o)))

GENSRC  := $(GEN)/r8c.c $(GEN)/m32c.c

.PHONY: all static shared clean install test gen
all: static shared rc8650say

static: librc8650.a
shared: $(SHLIB)
gen: $(GENSRC)

build build/gen:
	@mkdir -p $@

# opc2c runs on the build machine even when the library is being cross
# compiled, so it is built with $(CC) and never with $(WINCC*).
build/opc2c: $(SIM)/opc2c.c | build
	$(CC) -O2 -w -I. -o $@ $<

build/gen/%.c: $(SIM)/%.opc build/opc2c | build/gen
	build/opc2c -l $@.log $< > $@.tmp && mv $@.tmp $@

build/%.o: %.c | build
	$(CC) $(CFLAGS) -c $< -o $@
build/%.o: $(SIM)/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@
build/%.o: $(GEN)/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

librc8650.a: $(LIBOBJ)
	$(AR) rcs $@ $^

$(SHLIB): $(LIBOBJ)
	$(CC) $(SHFLAGS) -o $@ $^ $(LDFLAGS) $(LDLIBS)

rc8650say: rc8650say.c librc8650.a
	$(CC) $(CFLAGS) -o $@ rc8650say.c librc8650.a $(LDFLAGS) $(LDLIBS)

# --- Windows cross build (mingw-w64) --------------------------------------
#
# For the NVDA add-on: NVDA 2025.2 and later run as a 64-bit process, earlier
# versions as a 32-bit one, so both are built and shipped side by side.
#
# win-compat/ carries the two things a Windows host does not have: an empty
# <sys/select.h>, and (force-included) the console-input symbols the m32c
# core's standalone-simulator fallback names.  Both only exist to let dead
# scaffolding compile - see win-compat/rc8650-win.h.  -static-libgcc drops the
# libgcc DLL dependency, so each DLL stands alone next to the driver.

WINCC64 ?= x86_64-w64-mingw32-gcc
WINCC32 ?= i686-w64-mingw32-gcc
WINCFLAGS := -O2 -I. -Iwin-compat -include win-compat/rc8650-win.h \
             -I$(SIM) -I$(GEN) $(WARNOFF)

.PHONY: windows win64 win32
windows: win64 win32
win64: rc8650_64.dll
win32: rc8650_32.dll

rc8650_64.dll: $(LIBSRC)
	$(WINCC64) $(WINCFLAGS) -shared -static-libgcc -o $@ $(LIBSRC)

rc8650_32.dll: $(LIBSRC)
	$(WINCC32) $(WINCFLAGS) -shared -static-libgcc -o $@ $(LIBSRC)

test: rc8650say
	./rc8650say --chip-id
	./rc8650say -o /tmp/rc8650-test.wav "Library test, one two three."
	@echo "wrote /tmp/rc8650-test.wav"

install: all
	install -d $(PREFIX)/lib $(PREFIX)/include $(PREFIX)/bin
	install -m 644 librc8650.a $(SHLIB) $(PREFIX)/lib/
	install -m 644 rc8650.h $(PREFIX)/include/
	install -m 755 rc8650say $(PREFIX)/bin/

clean:
	rm -rf build librc8650.a librc8650.dylib librc8650.so rc8650say \
	       rc8650_64.dll rc8650_32.dll
