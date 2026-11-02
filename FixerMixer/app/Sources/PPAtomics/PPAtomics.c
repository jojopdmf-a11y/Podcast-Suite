#include "PPAtomics.h"

#include <stdatomic.h>

_Static_assert(sizeof(pp_atomic_u64) >= sizeof(_Atomic uint64_t), "pp_atomic_u64 too small");

void pp_atomic_init(pp_atomic_u64 *a) {
    atomic_store_explicit((_Atomic uint64_t *)&a->v, 0, memory_order_relaxed);
}

uint64_t pp_load_acquire(pp_atomic_u64 *a) {
    return atomic_load_explicit((_Atomic uint64_t *)&a->v, memory_order_acquire);
}

void pp_store_release(pp_atomic_u64 *a, uint64_t v) {
    atomic_store_explicit((_Atomic uint64_t *)&a->v, v, memory_order_release);
}

uint64_t pp_fetch_add(pp_atomic_u64 *a, uint64_t delta) {
    return atomic_fetch_add_explicit((_Atomic uint64_t *)&a->v, delta, memory_order_acq_rel);
}
