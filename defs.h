/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Minimal replacement for the autoconf-generated defs.h that the gdb sim
 * sources include.  The m32c core only needs HAVE_TERMIOS_H (for the
 * standalone simulator's raw console, which librc8650 does not use) and
 * ARRAY_SIZE (srcdest.c's only use of libiberty.h), so a hand-written header
 * keeps the library free of the gdb and binutils build trees.  */

#ifndef RC8650_DEFS_H
#define RC8650_DEFS_H

#if defined(__unix__) || defined(__APPLE__)
# define HAVE_TERMIOS_H 1
#endif

#ifndef ARRAY_SIZE
# define ARRAY_SIZE(a) (sizeof (a) / sizeof ((a)[0]))
#endif

#endif /* RC8650_DEFS_H */
