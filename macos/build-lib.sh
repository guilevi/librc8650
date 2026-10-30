#!/bin/sh
# Build librc8650 as a universal (arm64 + x86_64) static library for the Mac
# app and its speech-synthesis extension to link against.
#
# The project Makefile next door builds for the host architecture only, which
# is enough for the CLI but not for an app bundle that should run on both kinds
# of Mac.  Same sources, same flags, twice.
set -eu

cd "$(dirname "$0")"
LIB=$(cd .. && pwd)
ROOT=$(cd "$LIB/.." && pwd)
OUT=$(pwd)/lib

SIM=${SIM:-}
if [ -z "$SIM" ]; then
	for d in "$ROOT/gdb-14.2/gdbsim/m32c" "$ROOT/gdb-14.2/sim/m32c"; do
		[ -d "$d" ] && SIM=$d && break
	done
fi

# The instruction decoders: from a GDB sim build next door if there is one,
# otherwise have the project Makefile run opc2c into its build/gen, exactly as
# a plain `make` would.
GEN=${GEN:-}
if [ -z "$GEN" ]; then
	if [ -f "$ROOT/build-sim/sim/m32c/r8c.c" ]; then
		GEN=$ROOT/build-sim/sim/m32c
	elif [ -n "$SIM" ]; then
		make -C "$LIB" SIM="$SIM" GEN=build/gen gen >&2
		GEN=$LIB/build/gen
	fi
fi

if [ -z "$SIM" ] || [ ! -f "$GEN/r8c.c" ]; then
	echo "cannot find the m32c simulator sources (SIM=$SIM GEN=$GEN)" >&2
	echo "set SIM= and GEN= to override" >&2
	exit 1
fi

# rcdict is the pronunciation-dictionary layer: BSD-3-Clause, libc only, and
# shared verbatim with doubletalk-pc.  It is linked in for the same reason the
# project Makefile links it -- without it rc8650_set_dictionary has nothing to
# be given, and the app's dictionaries silently do nothing.
#
# rcdict_regex.c is listed apart because it is the only translation unit that
# includes vendored remimu.h, which is not clean under the default warnings;
# quieting just that object keeps every warning switched on for our own code.
SRC="$LIB/rc8650.c $LIB/stubs.c $LIB/rcdict/rcdict.c \
     $SIM/mem.c $SIM/reg.c $SIM/srcdest.c \
     $SIM/misc.c $SIM/int.c $GEN/r8c.c $GEN/m32c.c"
QUIET_SRC="$LIB/rcdict/rcdict_regex.c"

# The vendored simulator sources predate several of clang's default warnings.
WARNOFF="-Wno-implicit-function-declaration -Wno-incompatible-pointer-types \
         -Wno-int-conversion -Wno-unused-result"

mkdir -p "$OUT"
for arch in arm64 x86_64; do
	obj=$OUT/obj-$arch
	mkdir -p "$obj"
	for f in $SRC; do
		o=$obj/$(basename "$f" .c).o
		[ -f "$o" ] && [ "$o" -nt "$f" ] && continue
		cc -arch $arch -O2 -g -fPIC -mmacosx-version-min=13.0 \
		   -I"$LIB" -I"$LIB/rcdict" -I"$SIM" -I"$GEN" $WARNOFF -c "$f" -o "$o"
	done
	for f in $QUIET_SRC; do
		o=$obj/$(basename "$f" .c).o
		[ -f "$o" ] && [ "$o" -nt "$f" ] && continue
		cc -arch $arch -O2 -g -fPIC -mmacosx-version-min=13.0 \
		   -I"$LIB/rcdict" -w -c "$f" -o "$o"
	done
	ar rcs "$OUT/librc8650-$arch.a" "$obj"/*.o
done

lipo -create "$OUT/librc8650-arm64.a" "$OUT/librc8650-x86_64.a" \
     -output "$OUT/librc8650.a"
lipo -info "$OUT/librc8650.a"
