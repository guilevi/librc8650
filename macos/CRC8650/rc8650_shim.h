/* Acquire/release loads and stores, for the single-producer/single-consumer
 * ring buffer that carries audio from the render thread that produces it to
 * the audio unit render block that consumes it.
 *
 * Swift has no atomics in its standard library at this deployment target, and
 * the render block is the one place where a lock is not an option, so the two
 * ring indices are plain memory published through these.  Acquire on the load
 * and release on the store is exactly enough: it guarantees the consumer sees
 * the samples the producer wrote before it advanced the write index.
 */

#ifndef RC8650_SHIM_H
#define RC8650_SHIM_H

#include <stdint.h>

#include "../../rcdict/rcdict.h"

/* The address of the RC8650 dictionary profile.
 *
 * rcdict_new BORROWS the profile it is given -- it stores the pointer -- and
 * rcdict_rc8650 is a const global, which Swift imports as a `let`.
 * withUnsafePointer(to:) on a `let` may hand back the address of a temporary
 * COPY, and a dictionary holding a pointer into a dead temporary is a bug that
 * would show up as garbage phonemes long after the fact, if at all.  Asking C
 * for the address of the real object is the only way to be sure of getting it.
 *
 * (The same trap in the other binding: from ctypes the address has to be taken
 * with ctypes.addressof(ctypes.c_char.in_dll(...)), because c_void_p.in_dll
 * would read the struct's first field and return that as a pointer.)
 */
static inline const rcdict_profile *
rc8650_dict_profile (void)
{
  return &rcdict_rc8650;
}

static inline uint64_t
rc8650_atomic_load (const uint64_t *p)
{
  return __atomic_load_n (p, __ATOMIC_ACQUIRE);
}

static inline void
rc8650_atomic_store (uint64_t *p, uint64_t v)
{
  __atomic_store_n (p, v, __ATOMIC_RELEASE);
}

/* Relaxed: for flags whose exact moment of visibility does not matter, only
   that they eventually become visible (the cancel flag). */
static inline uint32_t
rc8650_atomic_load_relaxed (const uint32_t *p)
{
  return __atomic_load_n (p, __ATOMIC_RELAXED);
}

static inline void
rc8650_atomic_store_relaxed (uint32_t *p, uint32_t v)
{
  __atomic_store_n (p, v, __ATOMIC_RELAXED);
}

#endif /* RC8650_SHIM_H */
