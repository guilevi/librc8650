/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Replacements for the parts of the standalone simulator that librc8650 does
 * not link: main.c, the bfd-based loader in load.c, the CGEN disassembler in
 * trace.c, and the hosted-newlib syscall layer in syscalls.c.  Keeping these
 * as stubs is what lets the library build against libc alone.  */

#include "cpu.h"

/* load.c owns this; m32c_set_cpu() points it at decode_r8c or decode_m32c. */
int (*decode_opcode) (void) = 0;

/* main.c owns this; the library never turns disassembly on. */
int m32c_disassemble = 0;

/* trace.c.  Only sim_disasm_one() is reachable from the core, and only when
 * m32c_disassemble is set. */
void
sim_disasm_one (void)
{
}

void
sim_disasm_init (void *prog)
{
  (void) prog;
}

/* syscalls.c.  The firmware is bare metal and the library always sets
 * m32c_baremetal, which stops the core routing anything here. */
void
m32c_syscall (int id)
{
  (void) id;
}
