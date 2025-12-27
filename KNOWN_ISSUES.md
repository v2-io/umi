# Known Issues and Unreproduced Failures

## Issue #3: Hang in "message storm while shutting down" (2024-12-26)

**Observed:** SEED=111102372768351170074946859026545758313

**Symptom:** Test hung for 180s, watchdog killed it. Stack trace shows stuck in join() -> receive_message, with ~4900 dead timer threads accumulated.

**Root cause:** My "fix" for Issue #2 introduced a new problem!

The fix had death_thread wait for stdout_thread.join before sending [:process_died]:
```ruby
death_thread = Thread.new do
  status = wait_thr.value
  stdout_thread.join  # <-- BLOCKS if stdout has lots of buffered data!
  stderr_thread.join
  inbox.send([:process_died, ...])
end
```

In the "message storm" test:
1. Process outputs "spam\n" in infinite loop, filling pipe buffer (~64KB)
2. We kill the process
3. death_thread waits for stdout_thread to drain ALL buffered data
4. stdout_thread slowly reads and sends [:stdout] for each line
5. join() receives each [:stdout], loops, creates new timer thread each time
6. This takes forever if there's lots of buffered data
7. [:process_died] never arrives until ALL stdout is drained

**The tension:**
- Issue #2 fix: need to guarantee stdout arrives before process_died
- This test: need process_died to arrive even when stdout is flooding

**Better fix needed:** Instead of blocking death_thread on stdout_thread.join, we should:
1. Have death_thread send [:process_died] immediately when process exits
2. BUT also send [:stdout_drained] after stdout_thread.join
3. join() should wait for [:stdout_drained] OR timeout, not [:process_died]

Or simpler: Keep the drain_remaining_to_buffer approach but don't block death_thread.

**Status:** FIXED by reverting death_thread blocking approach

The correct fix is `drain_remaining_to_buffer()` on the receiving side (in receive()):
- When we get [:process_died], immediately do a non-blocking drain of inbox
- Any [:stdout] messages that were "in flight" get captured
- Then check buffer before raising ProcessExited

This approach handles both cases:
- Fast processes: stdout arrives after process_died, we capture it
- Flooding processes: process_died arrives quickly, no hang

---

## Issue #2: Fast process output lost when process_died arrives first (2024-12-26)

**Observed:** During stress test with SEED=39196096427564143127199106449205316907

**Symptom:** `100 Shellacs with proper cleanup` failed with:
```
ROTP::Shellac::ProcessExited: Process exited with code 0
```

The test runs `echo testN` 100 times. Sometimes, despite the process outputting successfully (exit code 0), we get ProcessExited instead of the output.

**Root cause analysis:**
1. `echo` runs and outputs "testN\n", then exits immediately
2. stdout_thread sends `[:stdout, "testN\n"]` to inbox
3. death_thread sends `[:process_died, ...]` to inbox
4. We call `receive()`, `@exited` is false
5. `drain_until_stdout()` calls `inbox_receive_raw()`
6. **Race:** inbox_receive_raw may return `[:process_died]` before `[:stdout]`
7. We handle death, raise ProcessExited
8. **Bug:** The `[:stdout]` message is still in inbox, never read!

**Status:** FIXED

**Fix applied:** Added `drain_remaining_to_buffer()` method that non-blocking drains any remaining messages from inbox when `[:process_died]` is received. Also added `@pending_death` to track death info while returning remaining buffered stdout.

The fix ensures that even if `[:process_died]` arrives before `[:stdout]` in the inbox (due to thread scheduling), we still capture and return any stdout that was sent before the process died.

---

## Issue #1: fork-bomb-lite missing output (2024-12-26)

**Observed:** During stress test run with SEED=87353162095778721563299067702172199368

**Symptom:** The `process with child processes` test failed with:
```
expected 'done' in ["parent\n"]
```

The fork-bomb-lite fixture should output:
- "parent" (immediately)
- "child0", "child1", "child2" (after 0.5s each, from forked children)
- "done" (after all children complete)

But we only received "parent".

**Possible causes:**
1. Race condition between process_died notification and remaining stdout data
2. Child process output not being captured (stdout sharing issue with fork)
3. ProcessExited raised before all buffered output was drained
4. Timing-dependent issue that only manifests under concurrent Ractor load

**Reproduction attempts:**
- Running fork-bomb-lite 10x solo: PASSED (all output received)
- Running 20x with concurrent cat shellacs: PASSED
- Running in full stress test suite: Has not failed again yet

**Status:** LIKELY FIXED by Issue #2 fix

The root cause was probably the same race condition: `[:process_died]` arriving before all `[:stdout]` messages were drained, causing output to be lost.

After fixing Issue #2, this test has not failed in subsequent runs. If it fails again, we'll need deeper investigation.
