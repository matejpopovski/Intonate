#ifndef CATOMICSHIM_H
#define CATOMICSHIM_H

#include <stdatomic.h>
#include <stdint.h>

// The ring buffer runs on the real-time audio thread and supports iOS 17, which rules out the
// Synchronization module (iOS 18). These inline wrappers give Swift acquire/release access to a
// plain UInt64 it allocated itself, with no lock, allocation or Objective-C runtime call.
static inline uint64_t intonate_load_acquire(const uint64_t *location) {
    return atomic_load_explicit((const _Atomic(uint64_t) *)location, memory_order_acquire);
}

static inline uint64_t intonate_load_relaxed(const uint64_t *location) {
    return atomic_load_explicit((const _Atomic(uint64_t) *)location, memory_order_relaxed);
}

static inline void intonate_store_release(uint64_t *location, uint64_t value) {
    atomic_store_explicit((_Atomic(uint64_t) *)location, value, memory_order_release);
}

static inline void intonate_add_relaxed(uint64_t *location, uint64_t value) {
    atomic_fetch_add_explicit((_Atomic(uint64_t) *)location, value, memory_order_relaxed);
}

#endif
