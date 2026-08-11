#ifndef UnfairLock_h
#define UnfairLock_h

#include <os/lock.h>

/**
 BasicLockable wrapper over os_unfair_lock — the fastest blocking lock on
 Darwin. Drive it with std::lock_guard<UnfairMutex>.

 Prefer this over SpinLock for any critical section that can block (syscalls,
 objc runtime calls, allocation) or that can see bursty contention: waiters
 sleep in the kernel and donate their priority to the holder, while SpinLock
 busy-waits in userspace, invisible to the scheduler. Benchmarked on an
 M-series host: under an 8-thread burst on a short section os_unfair_lock is
 ~30x faster than SpinLock at ~33x less CPU, and against a holder that sleeps
 mid-section waiters cost ~100x less CPU. SpinLock stays marginally faster
 (~0.2 ns/op) only for uncontended nanosecond-scale sections — its documented
 niche (selector caching).

 NATIVESCRIPT_UNFAIR_LOCK_ADAPTIVE_SPIN opts lock() into
 os_unfair_lock_lock_with_options() with kernel-informed adaptive spinning —
 the approach Firefox adopted for its nanosecond-hot allocator locks:
 https://hacks.mozilla.org/2022/10/improving-firefox-responsiveness-on-macos/

 Experiments only, never ship it:
 - PRIVATE API (os/lock_private.h); App Review flags the symbol.
 - It only wins for nanosecond-scale sections at low contention with the
   holder on-core (measured ~2x over plain os_unfair_lock at 2 threads).
   Under bursty contention it degenerates to spinlock behavior (~30x slower,
   ~30x more CPU at 8 threads), it is the worst option under QoS inversion,
   and it changes nothing when the holder sleeps.
 */

#ifdef NATIVESCRIPT_UNFAIR_LOCK_ADAPTIVE_SPIN
extern "C" void os_unfair_lock_lock_with_options(os_unfair_lock_t lock,
                                                 uint32_t options);
// Values from os/lock_private.h (ADAPTIVE_SPIN requires iOS 13+).
#define NATIVESCRIPT_OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION 0x00010000u
#define NATIVESCRIPT_OS_UNFAIR_LOCK_ADAPTIVE_SPIN 0x00040000u
#endif

struct UnfairMutex {
  os_unfair_lock lock_ = OS_UNFAIR_LOCK_INIT;

  inline void lock() noexcept {
#ifdef NATIVESCRIPT_UNFAIR_LOCK_ADAPTIVE_SPIN
    os_unfair_lock_lock_with_options(
        &lock_, NATIVESCRIPT_OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION |
                    NATIVESCRIPT_OS_UNFAIR_LOCK_ADAPTIVE_SPIN);
#else
    os_unfair_lock_lock(&lock_);
#endif
  }

  inline bool try_lock() noexcept { return os_unfair_lock_trylock(&lock_); }

  inline void unlock() noexcept { os_unfair_lock_unlock(&lock_); }
};

#endif /* UnfairLock_h */
