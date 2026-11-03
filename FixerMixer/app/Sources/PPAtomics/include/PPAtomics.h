#ifndef PPAtomics_h
#define PPAtomics_h

#include <stdint.h>

/* Plain storage so Swift can import the header. Atomics live in PPAtomics.c. */
typedef struct {
    uint64_t v;
} pp_atomic_u64;

void pp_atomic_init(pp_atomic_u64 *a);
uint64_t pp_load_acquire(pp_atomic_u64 *a);
void pp_store_release(pp_atomic_u64 *a, uint64_t v);
uint64_t pp_fetch_add(pp_atomic_u64 *a, uint64_t delta);

#endif
