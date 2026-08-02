/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Force-included (-include) into every source of the Windows cross build.
 *
 * The m32c core's serial-receive path has a fallback that reads the host's
 * stdin when no rc865x_hook_rx is installed.  That fallback is standalone-
 * simulator scaffolding: librc8650 always installs the hook, so it is dead
 * code here.  It nevertheless has to compile, and it names two things that
 * only exist when HAVE_TERMIOS_H is defined - which it is not on mingw (see
 * defs.h), because Windows has no termios.
 *
 * Supplying them here keeps the vendored gdb sources untouched.  Reading from
 * fd -1 fails, which is the same "no console input" answer the guarded code
 * would give.  */

#ifndef RC8650_WIN_H
#define RC8650_WIN_H

#define m32c_console_ifd (-1)

static inline int
stdin_ready (void)
{
  return 0;
}

#endif /* RC8650_WIN_H */
