#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Run the driver's dictionary tests outside NVDA, against the real emulator.
#
#   ./run.sh                     # uses ../../librc8650.dylib and the repo's firmware
#   FIRMWARE=path ./run.sh       # a firmware image elsewhere
#
# The driver is Windows-only in production (it loads rc8650_64.dll), but nothing
# about the dictionary path is: the tests stage a copy of the driver package
# with the host's shared library standing in for the DLL, which is why this
# works on a Mac or a Linux box with no NVDA in sight.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

LIB=${LIB:-}
if [[ -z "$LIB" ]]; then
    for candidate in ../../librc8650.dylib ../../librc8650.so; do
        [[ -f "$candidate" ]] && LIB=$candidate && break
    done
fi
[[ -n "$LIB" && -f "$LIB" ]] || {
    echo "no shared librc8650 - run 'make -C ../.. shared' first" >&2; exit 1; }

FIRMWARE=${FIRMWARE:-}
if [[ -z "$FIRMWARE" ]]; then
    for candidate in ../../../rc8650_m4_valid.srec ../synthDrivers/rc8650/rc8650_m4_valid.srec; do
        [[ -f "$candidate" ]] && FIRMWARE=$candidate && break
    done
fi
[[ -n "$FIRMWARE" && -f "$FIRMWARE" ]] || {
    echo "no firmware image - set FIRMWARE=<path to an S-record>" >&2; exit 1; }

echo "== dictionary file ordering"
python3 test_dictfiles.py ../synthDrivers/rc8650

echo
echo "== the driver, against the emulator"
python3 test_dictionaries.py ../synthDrivers/rc8650 "$LIB" "$FIRMWARE"
