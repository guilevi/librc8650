/* SPDX-License-Identifier: GPL-3.0-or-later */
/* mingw-w64 has no <sys/select.h>.  The m32c core includes it unconditionally
 * for the standalone simulator's stdin_ready(), which lives inside
 * #ifdef HAVE_TERMIOS_H and is therefore compiled out on Windows (see
 * defs.h) - so an empty header is all the Windows build needs.  */

#ifndef RC8650_WIN_SYS_SELECT_H
#define RC8650_WIN_SYS_SELECT_H
#endif
