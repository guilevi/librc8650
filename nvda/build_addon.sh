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

for f in synthDrivers/rc8650/rc8650_64.dll synthDrivers/rc8650/rc8650_32.dll; do
    [[ -f "$f" ]] || { echo "missing $f - see README.md" >&2; exit 1; }
done

# The firmware, whichever name and form it was supplied under. Kept in step
# with _FIRMWARE_NAMES in synthDrivers/rc8650/__init__.py.
FW=()
for f in rc8650_m4_valid.srec rc8650_m4_valid.srec.gz rc8650.srec rc8650.srec.gz; do
    [[ -f "synthDrivers/rc8650/$f" ]] && FW+=("synthDrivers/rc8650/$f")
done

rm -f rc8650.nvda-addon
if [[ $WITH_FW == 1 ]]; then
    [[ ${#FW[@]} -gt 0 ]] || { echo "no firmware image to bundle" >&2; exit 1; }
    zip -r -q rc8650.nvda-addon manifest.ini synthDrivers doc
    echo "wrote rc8650.nvda-addon (PRIVATE build - bundles the proprietary firmware, do not distribute)"
else
    EXCLUDES=()
    for f in "${FW[@]}"; do EXCLUDES+=(-x "$f"); done
    zip -r -q rc8650.nvda-addon manifest.ini synthDrivers doc "${EXCLUDES[@]}"
    echo "wrote rc8650.nvda-addon (no firmware - the user must supply their own image)"
fi
unzip -l rc8650.nvda-addon
