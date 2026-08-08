#!/bin/sh
# Mirror rcdict into doubletalk-pc, or check that the mirror is current.
#
# rcdict is BSD-3-Clause and depends on nothing but libc, which is what lets
# the same sources serve librc8650 (GPL-3, because of the GDB simulator core)
# and doubletalk-pc (BSD-3 throughout). The dependency only works in that
# direction: a GPL-3 file could never move the other way, so nothing here may
# acquire a GPL header.
#
# A copy rather than a submodule: an NVDA add-on build with a submodule in it
# is more trouble than the duplication, and `--check` in CI is what keeps the
# two honest.
#
#   sh rcdict/sync-to-doubletalk-pc.sh            copy, reporting what changed
#   sh rcdict/sync-to-doubletalk-pc.sh --check    exit 1 if they differ

set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DST="${RCDICT_DEST:-$SRC/../../doubletalk-pc/doubletalk/rcdict}"

FILES="rcdict.h rcdict.c rcdict_regex.h rcdict_regex.c remimu.h example.dict
DICTIONARY-GUIDE.md"

if [ ! -d "$(dirname "$DST")" ]; then
    echo "no doubletalk-pc tree at $(dirname "$DST")" >&2
    echo "set RCDICT_DEST to point at its rcdict directory" >&2
    exit 2
fi

if [ "$1" = "--check" ]; then
    rc=0
    for f in $FILES; do
        if [ ! -f "$DST/$f" ]; then
            echo "MISSING  $f"
            rc=1
        elif ! cmp -s "$SRC/$f" "$DST/$f"; then
            echo "DIFFERS  $f"
            rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "rcdict mirror is current ($(echo $FILES | wc -w | tr -d ' ') files)"
    exit $rc
fi

mkdir -p "$DST"
for f in $FILES; do
    if [ -f "$DST/$f" ] && cmp -s "$SRC/$f" "$DST/$f"; then
        echo "same     $f"
    else
        cp "$SRC/$f" "$DST/$f"
        echo "copied   $f"
    fi
done
echo "mirrored into $DST"
