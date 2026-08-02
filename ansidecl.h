/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Minimal stand-in for binutils' ansidecl.h.  The generated opcode decoders
 * use exactly one macro from it, so shimming it here keeps librc8650 buildable
 * without the binutils/gdb include tree.  */

#ifndef RC8650_ANSIDECL_H
#define RC8650_ANSIDECL_H

#ifndef ATTRIBUTE_UNUSED
# ifdef __GNUC__
#  define ATTRIBUTE_UNUSED __attribute__ ((__unused__))
# else
#  define ATTRIBUTE_UNUSED
# endif
#endif

#endif
