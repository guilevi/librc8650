#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Turn RC Systems' RCStudio firmware containers into images librc8650 loads.

RCStudio keeps each chipset's firmware as two files in its Bin folder: the
firmware proper (flash 0x7A0000, ~340 KB) and its BIOS/boot block (flash
0x7FC000, 16 KB).  Each file is a container:

    u32  flash_addr      little-endian
    u32  length
    u8   payload[length] stored as a running XOR: plain[i] = stored[i] ^ plain[i-1],
                         with plain[-1] = 0x80
    u16  checksum        sum of the preceding 8 + length bytes, mod 2^16

The two are joined into one Motorola S-record image at CPU addresses (flash
address with the top nibble masked off), with the firmware's validity marker
(the word at +8) set to 0000: RCStudio's loader writes that last, once the
image is programmed and verified, and the BIOS refuses to start firmware that
still says FF FF.

    rcstudio2srec.py --all "C:/Program Files/RCStudio/Bin" -o firmware/
    rcstudio2srec.py 'm$1a6c3f.bin' 'm$12a73d.bin' -o rc8660.srec
    rcstudio2srec.py --info 'm$*.bin'

Which BIOS goes with which firmware is the board's business, not the files':
RCStudio picks the pair with a Select Case on the chip's model byte.  KNOWN
below is that table as of the RCStudio release that ships these twelve files.
A later release's files are converted by naming the pair explicitly.

Output names say what is inside: rc8650-v2.60-m4.srec, rc8660-v3.44-m1.srec.
The NVDA add-on and the Mac app list a folder of such images by reading the
same header, so the names are for people.

The images are RC Systems' copyrighted code; this only rearranges a copy you
already have.
"""

import argparse
import glob
import gzip
import os
import struct
import sys

SEED = 0x80
ADDR_MASK = 0xFFFFF
COMMIT_OFF = 8
RECORD_BYTES = 32

# firmware container, BIOS container, as RCStudio pairs them.
KNOWN = [
    ("m$195a22", "m$11f9aa"),   # RC8650 v2.60, model 1
    ("m$28a5f8", "m$2a11b2"),   # RC8650 v2.60, model 2
    ("m$4a95b2", "m$4f8c6a"),   # RC8650 v2.60, model 4
    ("m$4b39ca", "m$4f92e7"),   # RC8650 v2.60, model 7
    ("m$29c1d3", "m$2b71e1"),   # RC8650 v2.60, model 8
    ("m$1a6c3f", "m$12a73d"),   # RC8660 v3.44, model 1
]

FAMILIES = {0x04: "rc8650", 0x05: "rc8660"}


def read_container(path):
    blob = open(path, "rb").read()
    if len(blob) < 10:
        raise ValueError("%s: too short to be a container" % path)
    addr, length = struct.unpack_from("<II", blob, 0)
    if len(blob) != length + 10:
        raise ValueError("%s: header says %d bytes, file holds %d"
                         % (path, length + 10, len(blob)))
    stored = struct.unpack_from("<H", blob, 8 + length)[0]
    if stored != sum(blob[:8 + length]) & 0xFFFF:
        raise ValueError("%s: checksum does not match" % path)
    plain = bytearray(length)
    acc = SEED
    for i, b in enumerate(blob[8:8 + length]):
        acc ^= b
        plain[i] = acc
    return addr & ADDR_MASK, plain


def header(firmware):
    """(chip name, version string, model) from the firmware's 13-byte header."""
    if len(firmware) < 13 or firmware[0] != 0xFE:
        return None
    return (FAMILIES.get(firmware[7], "unknown%02x" % firmware[7]),
            "%x.%02x" % (firmware[5], firmware[4]), firmware[6])


def record(rtype, addr, data, addr_bytes):
    body = addr.to_bytes(addr_bytes, "big") + bytes(data)
    count = len(body) + 1
    return "S%s%02X%s%02X" % (rtype, count, body.hex().upper(),
                              ~(count + sum(body)) & 0xFF)


def srec(segments):
    out = [record("0", 0, b"HDR", 2)]
    for base, data in segments:
        for off in range(0, len(data), RECORD_BYTES):
            out.append(record("3", base + off, data[off:off + RECORD_BYTES], 4))
    out.append(record("7", 0, b"", 4))
    return "\n".join(out) + "\n"


def convert(fw_path, bios_path):
    """Return (default file name, S-record text)."""
    fw_addr, firmware = read_container(fw_path)
    bios_addr, bios = read_container(bios_path)
    if len(firmware) < len(bios):
        raise ValueError("%s looks like the BIOS: give the firmware first" % fw_path)
    info = header(firmware)
    if info is None:
        raise ValueError("%s has no firmware header" % fw_path)
    firmware[COMMIT_OFF:COMMIT_OFF + 2] = b"\x00\x00"
    name = "%s-v%s-m%d.srec" % info
    return name, srec([(fw_addr, firmware), (bios_addr, bios)])


def write(path, text, compress):
    if compress:
        with gzip.open(path + ".gz", "wt") as f:
            f.write(text)
        return path + ".gz"
    with open(path, "w") as f:
        f.write(text)
    return path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="a firmware container and its BIOS")
    ap.add_argument("--all", metavar="BINDIR",
                    help="convert every pair RCStudio knows that is in BINDIR")
    ap.add_argument("--info", action="store_true",
                    help="describe the given containers instead of converting")
    ap.add_argument("-o", "--output",
                    help="output file, or folder with --all (default: here)")
    ap.add_argument("-z", "--gzip", action="store_true",
                    help="write .srec.gz (about a tenth of the size)")
    args = ap.parse_args(argv)

    if args.info:
        paths = [p for f in args.files for p in (glob.glob(f) or [f])]
        for path in paths:
            try:
                addr, plain = read_container(path)
            except ValueError as exc:
                print("%-16s %s" % (os.path.basename(path), exc))
                continue
            info = header(plain) if addr == 0xA0000 else None
            what = ("%s v%s model %d" % info) if info else "BIOS / data"
            print("%-16s 0x%05X  %7d bytes  %s"
                  % (os.path.basename(path), addr, len(plain), what))
        return 0

    if args.all:
        outdir = args.output or "."
        os.makedirs(outdir, exist_ok=True)
        done = 0
        for fw, bios in KNOWN:
            fw_path = os.path.join(args.all, fw + ".bin")
            bios_path = os.path.join(args.all, bios + ".bin")
            if not (os.path.isfile(fw_path) and os.path.isfile(bios_path)):
                continue
            name, text = convert(fw_path, bios_path)
            print("%s + %s -> %s" % (fw, bios, write(os.path.join(outdir, name),
                                                     text, args.gzip)))
            done += 1
        if not done:
            print("no known firmware pairs in %s" % args.all, file=sys.stderr)
            return 1
        return 0

    if len(args.files) != 2:
        ap.error("give a firmware container and its BIOS, or --all BINDIR")
    name, text = convert(*args.files)
    print(write(args.output or name, text, args.gzip))
    return 0


if __name__ == "__main__":
    sys.exit(main())
