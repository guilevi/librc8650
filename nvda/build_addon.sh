#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Package the NVDA add-on. Expects the two DLLs already in
# synthDrivers/rc8650/ (make -C .. windows, then copy them in - see README.md).
#
# The default build does NOT include the firmware image: it is RC Systems'
# copyrighted code, and the driver reports itself unavailable until the user
# supplies one. Pass --with-firmware for a personal build that bundles it;
# that package must not be distributed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WITH_FW=0
[[ "${1:-}" == "--with-firmware" ]] && WITH_FW=1

# Refresh the DLLs from the build tree if they are newer there. Copying them in
# by hand is easy to forget, and forgetting it produces the worst kind of bug:
# a package that builds, installs and runs, but ships the previous library. If
# the parent copy is missing, whatever is here already is used.
for f in rc8650_64.dll rc8650_32.dll; do
    if [[ -f "../$f" ]] && ! cmp -s "../$f" "synthDrivers/rc8650/$f"; then
        cp "../$f" "synthDrivers/rc8650/$f"
        echo "refreshed synthDrivers/rc8650/$f from ../$f"
    fi
done

for f in synthDrivers/rc8650/rc8650_64.dll synthDrivers/rc8650/rc8650_32.dll; do
    [[ -f "$f" ]] || { echo "missing $f - run 'make -C .. windows' first" >&2; exit 1; }
done

# The firmware, whichever name and form it was supplied under. Kept in step
# with _FIRMWARE_NAMES in synthDrivers/rc8650/__init__.py.
FW=()
for f in rc8650_m4_valid.srec rc8650_m4_valid.srec.gz rc8650.srec rc8650.srec.gz; do
    [[ -f "synthDrivers/rc8650/$f" ]] && FW+=("synthDrivers/rc8650/$f")
done

# globalPlugins/ carries the dictionaries settings category. It has to be a
# global plugin rather than part of the driver - a driver module comes and goes
# with the synthesizer, and a settings category cannot - so it is a second
# directory in the package and easy to leave out of these lines.
rm -f rc8650.nvda-addon
EXCLUDES=(-x "*/__pycache__/*")
if [[ $WITH_FW == 1 ]]; then
    [[ ${#FW[@]} -gt 0 ]] || { echo "no firmware image to bundle" >&2; exit 1; }
    zip -r -q rc8650.nvda-addon manifest.ini synthDrivers globalPlugins doc "${EXCLUDES[@]}"
    echo "wrote rc8650.nvda-addon (PRIVATE build - bundles the proprietary firmware, do not distribute)"
else
    for f in "${FW[@]}"; do EXCLUDES+=(-x "$f"); done
    zip -r -q rc8650.nvda-addon manifest.ini synthDrivers globalPlugins doc "${EXCLUDES[@]}"
    echo "wrote rc8650.nvda-addon (no firmware - the user must supply their own image)"
fi
unzip -l rc8650.nvda-addon
