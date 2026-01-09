# Ruby Bug Report: Race condition in Ractor UBF leads to use-after-free

**Ruby Version:** 4.0.0 (2025-12-25 revision 553f1675f3) +PRISM [arm64-darwin25]

**Platform:** macOS 26.1 (Darwin 25.1.0), ARM64

## Summary

A race condition between `ubf_ractor_wait()` and `ubf_clear()` can cause a
use-after-free of a stack-allocated `struct ractor_waiter`, leading to SEGFAULT.

## Crash Details

```
Exception: EXC_BAD_ACCESS (SIGSEGV)
Address: 0x0000000000000010
Signal: KERN_INVALID_ADDRESS at 0x0000000000000010

Crashed Thread Backtrace:
  ubf_ractor_wait        (ractor_sync.c)
  threadptr_trap_interrupt (thread.c)
  timer_thread_func      (thread_pthread.c)
```

The crash address 0x10 corresponds to accessing `waiter->th` (at offset 8) when
`waiter` has become a garbage pointer value (e.g., 8) after stack reuse.

## Root Cause Analysis

### The Race Condition

In `thread_pthread.c`, `ubf_clear()` checks `th->unblock.func` without holding
the lock:

```c
static void
ubf_clear(rb_thread_t *th)
{
    if (th->unblock.func) {  // CHECK WITHOUT LOCK
        rb_native_mutex_lock(&th->interrupt_lock);
        {
            th->unblock.func = NULL;
            th->unblock.arg  = NULL;
        }
        rb_native_mutex_unlock(&th->interrupt_lock);
    }
}
```

But in `ractor_sync.c`, `ubf_ractor_wait()` clears the func while holding the
lock, releases the lock, then continues accessing `waiter`:

```c
static void
ubf_ractor_wait(void *ptr)
{
    struct ractor_waiter *waiter = (struct ractor_waiter *)ptr;

    rb_thread_t *th = waiter->th;
    rb_ractor_t *r = th->ractor;

    // clear ubf and nobody can kick UBF
    th->unblock.func = NULL;
    th->unblock.arg  = NULL;

    rb_native_mutex_unlock(&th->interrupt_lock);  // RELEASE LOCK
    {
        RACTOR_LOCK(r);
        {
            if (waiter->wakeup_status == wakeup_none) {  // ACCESS waiter HERE
                waiter->wakeup_status = wakeup_by_interrupt;
                ccan_list_del(&waiter->node);
                rb_ractor_sched_wakeup(r, waiter->th);
            }
        }
        RACTOR_UNLOCK(r);
    }
    rb_native_mutex_lock(&th->interrupt_lock);
}
```

### Timeline of the Race

```
Thread A (in ractor_wait)              Timer Thread (in UBF)
─────────────────────────              ─────────────────────
struct ractor_waiter waiter;
  (stack-allocated)
rb_ractor_sched_wait() called
  sets ubf = ubf_ractor_wait
  sets ubf_arg = &waiter
  thread sleeps...
                                       ubf_ractor_wait(&waiter) called
                                       th = waiter->th      // valid
                                       r = th->ractor       // valid
                                       th->unblock.func = NULL
                                       th->unblock.arg = NULL
                                       UNLOCK(interrupt_lock)
                                       |
Thread A wakes (other event)           | Race window: waiter accessible
ubf_clear(th):                         | but Thread A holds no lock
  if (th->unblock.func) <- NULL!       |
  return immediately (no lock)         |
returns from ractor_wait()             |
waiter stack frame DESTROYED           |
stack reused (garbage values)          v
                                       RACTOR_LOCK(r)
                                       waiter->wakeup_status  <- CRASH!
                                       (waiter now points to garbage)
```

### Why Address 0x10?

`struct ractor_waiter` layout:
- offset 0-3: `wakeup_status` (enum, 4 bytes)
- offset 4-7: padding
- offset 8-15: `th` (pointer, 8 bytes)
- offset 16-31: `node` (ccan_list_node, 16 bytes)

When `waiter` becomes a garbage value like 8 (from stack reuse):
- `waiter->th` = `*(rb_thread_t**)(8 + 8)` = access at address **0x10**

## Reproduction

This is a timing-dependent race that manifests under heavy Ractor load. We
observed it running parallel Ractor tests that create/destroy many Ractors
rapidly. The crash is intermittent.

Test context: Running Umi (Ruby OTP-like library) Proctor tests which spawn
multiple Ractors managing external processes. The crash occurred during
Enumerable iteration tests over Ractor-wrapped process output.

Crash report saved: `ruby-ractor-crash-2026-01-09.ips` (macOS DiagnosticReports)

## Suggested Fix

The fundamental issue is that `ubf_clear()` can return before the UBF has
finished executing, allowing the calling thread to destroy stack state the UBF
still needs.

### Option 1: Always acquire lock in ubf_clear()

```c
static void
ubf_clear(rb_thread_t *th)
{
    rb_native_mutex_lock(&th->interrupt_lock);
    {
        th->unblock.func = NULL;
        th->unblock.arg  = NULL;
    }
    rb_native_mutex_unlock(&th->interrupt_lock);
}
```

This ensures `ubf_clear()` waits if the UBF is currently holding the lock (i.e.,
hasn't released it yet). However, this doesn't fully solve the problem since the
UBF releases the lock before finishing.

### Option 2: Add UBF-in-progress flag

Add a flag to indicate UBF execution is in progress:

```c
struct rb_unblock_callback {
    rb_unblock_function_t *func;
    void *arg;
    bool in_progress;  // NEW
};
```

UBF sets `in_progress = true` before releasing lock, clears it at end.
`ubf_clear()` spins/waits while `in_progress` is true.

### Option 3: Don't use stack-allocated waiter

Allocate `struct ractor_waiter` on heap or embed it in a longer-lived structure
(e.g., the thread struct). This sidesteps the lifetime issue entirely.

### Option 4: UBF copies what it needs before releasing lock

```c
static void
ubf_ractor_wait(void *ptr)
{
    struct ractor_waiter *waiter = (struct ractor_waiter *)ptr;

    rb_thread_t *th = waiter->th;
    rb_ractor_t *r = th->ractor;

    // Copy everything we need BEFORE releasing lock
    enum ractor_wakeup_status *status_ptr = &waiter->wakeup_status;
    struct ccan_list_node *node_ptr = &waiter->node;

    th->unblock.func = NULL;
    th->unblock.arg  = NULL;

    // Actually, this doesn't work - we still need to write to waiter
    // and it could be freed...
}
```

This doesn't fully work because we need to *write* to `waiter->wakeup_status`.

### Recommended: Option 2

The cleanest fix is adding explicit synchronization for UBF completion. The
`in_progress` flag with proper memory ordering ensures `ubf_clear()` doesn't
return until the UBF has completely finished accessing its argument.

## Related Code Locations

- `ractor_sync.c:1001-1029` - `ubf_ractor_wait()`
- `ractor_sync.c:1031-1067` - `ractor_wait()` (allocates waiter on stack)
- `thread_pthread.c:1056-1066` - `ubf_clear()`
- `thread_pthread.c:1332-1364` - `rb_ractor_sched_wait()` (calls ubf_clear)
- `thread.c:367-369` - UBF invocation in `threadptr_set_interrupt_locked()`

## Additional Notes

The comment at line 1009 in `ractor_sync.c` says "clear ubf and nobody can kick
UBF" - this is true (no *new* UBF call), but the *current* UBF execution
continues past that point, and `ubf_clear()` doesn't wait for it.

Other UBF implementations (e.g., `ubf_waiting` in thread_pthread.c:1069) have
similar patterns but may not suffer this issue if their `arg` has longer
lifetime. The Ractor wait case is particularly vulnerable because `waiter` is
stack-allocated with a short lifetime tied to `ractor_wait()`.
