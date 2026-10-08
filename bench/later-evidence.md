# LATER implementation and evidence — work in progress

This branch starts at published main `46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4`.
It is intentionally unlanded for R6. No main update, merge-tier dispatch,
release, tag, adoption, or rival trial is part of this batch.

## Row audit

“Main” below means the exact published revision above, not an inferred future
implementation. Its historical three-OS CI is [37792438992](https://github.com/pedronaugusto/reactor/actions/runs/37792438992).
The existing implementations were preserved. Newly selected regressions and
native ownership checks live in `src/later_test.zig` and `src/r1_regression_test.zig`.

| Row | Main implementation/proof | LATER implementation and checks |
| --- | --- | --- |
| Callback API (L1) | `Loop.Op.callback`, `start`, delivery and `reap`; embedding tests | Preserved. Eight callback resubmissions, no duplicate reap delivery, zero inflight operations. |
| Per-task stack size (L2) | One runtime-wide pool | Init-reserved classes, smallest fitting available class, bounded capacity and reuse; `concurrentWith`; class allocation failure rollback with shakedown NoResize. `src/ext/tasks_test.zig`. |
| CPU/disk priorities (L3) | One CPU queue and lane FIFO | Separate latency queues, bounded burst of eight, task priority propagated to lane jobs. CPU and controlled disk-lane fairness regressions. |
| Registered buffers (L4) | Provided receive buffers; no fixed file-buffer API | Optional `Receiver.Pool.registered`, sparse per-ring slots, owner registration/unregistration, READ_FIXED/WRITE_FIXED range validation and retained users. Fixed read/write, canceled pipe read with poisoning, exhausted-table rollback, worker-adoption/teardown checks. |
| Zero-copy send (L5) | Ordinary send | Probed contiguous SEND_ZC; primary and notification ownership independent, notification-first handling, cancellation drain, ordinary-send fallback for unsupported requests. Native byte validation before buffer poisoning. Opt-in `zero_copy_min`; default disabled by measurements. |
| SQPOLL (L6) | No option | Explicit setup, optional CPU affinity, idle wake handling, no backend downgrade. Idle NOP and published fixed-file close-reference fence checks. |
| Fixed files (R1) | `backend/uring/Files.zig`; `files_test.zig` covers rewriting unsubmitted references. Regular files only; sockets/pipes excluded. | Preserved; SQPOLL consumption fence added before unregister. Existing cross-ring close proof retained in `uring_ext_test.zig`. |
| Cross-ring messages (R1) | Eventfd wakes | MSG_RING target CQ wake; target deferred task work entered before inspection; eventfd fallback on unavailable/failed messaging. Repeated wakes coalesce until target consumption. Shutdown keeps direct eventfd wakes because stop joins without another source poll. |
| Linked timeouts (R1) | Wheel cancellation | IO_LINK plus absolute LINK_TIMEOUT, reserved two-entry submission, primary/timer lifetime drain, timeout mapping and batch retry. All generated completion permutations plus native blocked TCP read and retry. |
| Native open/stat (R1) | File worker/lane routes | Linux OPENAT/STATX, exact std flags/errors and lock behavior; native path bypasses inline general lane. Differential file content, size, resize, missing/exclusive errors and fault injection. Windows metadata remains on its designed file worker/lane route. |
| Native process waits (R1) | Linux pidfd; Windows wait-completion packets in `runtime/io_ops.zig`/`iocp_test.zig` | Linux WAITID where probed, pidfd fallback preserved; BSD/macOS process-watch wait before reaping. Zero wait-lane counters; historical Windows process tests preserved and rerun. |
| Idle trimming (R1) | Pool trimming function existed, unused by scheduler | Off-stack trimming below saved live SP; ended-task discard, retained diagnostic watermarks, opt-in overall painting. Linux discarded-page regression; deep/shallow parked byte preservation. Windows discard is disabled because the platform implementation is a no-op. |
| Lane backpressure (R1) | Queue already bounded by task frames; existing 1050-call/cap-one proof. Executor rejection ran inline; cap zero queued forever. | Explicit rejection completes without invoking user code; cap-zero refuses immediately. Failing-before regressions. No queue-full inline fallback. Narrow/void rejection contract remains an owner decision below. |
| Fault seam (R1) | PRNG fake scheduling, no injectable submit errors | One shared shakedown Source, fallible custom submit seam, failure sweep and ownership counters; FaultIo error/short/cancellation sweeps over native file operations. |
| Threaded differential (R1) | Individual conformance examples | 64 generated file sequences and 32 generated stream/EOF/batch-retry/futex-cancel sequences; semantic results compared with Threaded. Linux exercises io_uring and epoll; other native OSes use their backend. |
| Shrinking (R1) | No shared replay source | Production scheduler fake consumes the property Source; expected failing witness shrinks and its tape replays exactly; retained regression tapes. |
| Overflow deaths (R1) | No death fixture | Test child exhausts guarded stack, marker proves entry; POSIX requires guard-fault signal, Windows requires terminal failure. Portable runner selection; no personal config or signal-handler edits outside the child. |
| V3(a) | Owned Threaded lanes and cancel forwarding existed | Native blocked pipe-read cancellation on POSIX and Windows, with no inline lane call. |
| V6 | Windows TIB switch, commit growth, large-frame/recursion/stack-walk checks | Test-only C fixture crosses `__chkstk`, parks inside an SEH scope, raises and unwinds through finally/handler. Native Windows check. |
| V7 | Wait-completion packets and high-resolution waitable timers | Preserved process and precise timer tests rerun on native Windows. |
| V11 | Parked watermarks discarded with task records; no complete family-suite measurements | Retained parked statistics and optional overall painting implemented and tested. Actual uplink/cloak/conduit/airlock/relic suite measurements are still owed; default stack size has not been retuned from uncollected measurements. |
| Local address/interface | `net.connect` options and platform bind calls existed | Preserved, native/foreign loopback address and interface proof; Linux uses BINDTOIFINDEX to avoid Threaded’s unimplemented reverse name lookup. No uplink change. |
| Airlock adapter | `ext/blocking.zig` supplies `blockingHook`; `ext_test.zig` sync-lane proof | Preserved and covered by existing tests. Airlock remains a leaf; its adoption is a separate batch. |

Additional bugs found during this batch: group emptiness was published before
all stack releases, and Debug backend dispatch copied mutable native engines.
Groups now release under their lock, then publish empty; native engines have
stable storage allocated at loop initialization. Targeted stress and TSan are
the regression evidence. No user callback runs during SQ/CQ pressure draining,
and batch list mutations remain deferred to the owner’s poll.

## Napkin math and measurement method

Size classes reserve address space at initialization; touched pages dominate
resident cost. Explicit class selection scans the short class table; default
spawn avoids that scan. Priorities add a second bounded queue and one ordinary
fast-path check; eight latency turns bound starvation. Fixed buffers avoid
repeated page pinning. MSG_RING should remove the eventfd write syscall but
adds a source SQE and a target CQE. Linked deadlines add one SQE/CQE in exchange
for removing a wheel-driven cancel. SEND_ZC adds notification work and pinned
pages, so copying wins for small sends; its crossover must be measured.
SQPOLL trades a dedicated kernel thread for fewer submission syscalls.

`zig build later-evidence` is the public Zig-only runner. It creates its own
immutable before fixture below the clone’s cache, compiles both variants in
ReleaseFast, runs five interleaved rounds, and prints raw JSON. It performs no
performance gate and never edits a rival or another worker’s checkout.
`zig build later-regressions` selects only the before test artifact so a known
broken example/smoke shutdown cannot hold the regression open. The immutable
before revisions are main and the first public LATER checkpoint `f110c794`.

Measurements are best-of-five, with raw rounds retained. Hosted VM CPU and
network noise prevents treating these numbers as portable guarantees. All
performance misses are reported; they are not silently accepted as wins.

## Hosted evidence so far

- Canonical FAST [37814002753](https://github.com/pedronaugusto/reactor/actions/runs/37814002753) passed for `95bb5a39a3e33f4b8335598a57e305c838760488`.
- Native FAST [37814086107](https://github.com/pedronaugusto/reactor/actions/runs/37814086107): Linux ownership/R1, macOS conformance/child, Windows conformance/V3/V6/V7/guard all passed; TSan and before harness failed and were corrected afterward.
- Native FAST [37815984146](https://github.com/pedronaugusto/reactor/actions/runs/37815984146): TSan and before harness passed, as did Linux R1 and Windows V3/V6/V7/conformance/guard. Linux ownership failed solely because the new adoption fixture supplied two buffers to three rings; corrected to four afterward.
- Before proof on exact main: rejected executor executes user code, cap-zero job never completes, Linux native open/stat increments inline counter four times, returned deep stack still contains byte 73, Linux interface bind panics in reverse name lookup. macOS native child wait increments the wait lane. Group-release and stop failures reproduce on the public first LATER checkpoint.
- Earlier canceled/failed run IDs are retained in the final handoff; they are not passing evidence.

Latest source validation and final raw measurements will be appended after
the corrected FAST run. No merge tier has been dispatched by this batch.

## Retained A/B checkpoint

Linux source: `0f6921c`, native FAST job [113444631168](https://github.com/pedronaugusto/reactor/actions/runs/37815984146/job/113444631168).
macOS: the same stable-engine implementation, with the subsequent Linux-only
message coalescing and extra tests; baseline is exact published main in both.
Raw rounds: [Linux](later-results/linux-0f6921c.jsonl),
[macOS](later-results/macos-stable-engines.jsonl).

| Workload | Linux before → after | macOS before → after |
| --- | --- | --- |
| spawn: concurrent + await, empty (ns/task) | 74.501 → 87.999 (+18.1%) | 99.471 → 113.729 (+14.3%) |
| spawn: group of 10k, concurrent + await (ns/task) | 179.737 → 195.176 (+8.6%) | 256.914 → 270.453 (+5.3%) |
| wake: ping-pong between two tasks (ns/wake) | 46.874 → 52.294 (+11.6%) | 62.710 → 66.044 (+5.3%) |
| loop: run(.nowait) with nothing ready (ns/run) | 11.610 → 12.725 (+9.6%) | 187.680 → 188.784 (+0.6%) |
| files: cached 4 KiB positional read (ns/read) | 551.808 → 551.341 (-0.1%) | 5425.577 → 5374.524 (-0.9%) |
| lanes: blocking, empty call on general (ns/call) | 17501.944 → 16451.387 (-6.0%) | 5671.842 → 5496.775 (-3.1%) |
| echo: 64 B round trips, 1 connection (msg/s) | 74302.375 → 73045.012 (-1.7%) | 61396.203 → 63060.833 (+2.7%) |
| echo: 64 B round trips, 32 connections (msg/s) | 82396.332 → 80324.084 (-2.5%) | 199379.746 → 200152.641 (+0.4%) |
| deadlines: 64 B round trips, reads under a deadline (msg/s) | 73667.743 → 71173.161 (-3.4%) | 63051.548 → 60499.914 (-4.0%) |
| waits: wait on pipes, round trip (ns/round) | 3033.903 → 3121.482 (+2.9%) | 16180.431 → 16391.252 (+1.3%) |
| waits: Wake signal and wait, round trip (ns/round) | 2577.236 → 2687.744 (+4.3%) | 16360.773 → 15796.460 (-3.4%) |
| timers: timer, arm (ns/timer) | 46.819 → 49.392 (+5.5%) | 29.181 → 29.965 (+2.7%) |
| timers: timer, cancel (ns/timer) | 16.834 → 17.339 (+3.0%) | 4.516 → 4.452 (-1.4%) |
| timers: 1 ms sleep overshoot p50 (us) | 9.610 → 9.731 (+1.3%) | 28.958 → 29.625 (+2.3%) |
| timers: 1 ms sleep overshoot p99 (us) | 10.922 → 11.383 (+4.2%) | 50.042 → 39.291 (-21.5%) |

The default-spawn regression remains material: Linux +18.1%, macOS +14.3%.
Wake cost rises Linux +11.6%, macOS +5.3%. These are raised to nav/R6 with
raw rounds, not claimed as performance wins. Timer cancellation has recovered
from the earlier large regression: Linux +3.0%, macOS −1.4% at this checkpoint.

Explicit class spawn is 92.711 / 92.461 / 90.935 ns for 64 KiB / 256 KiB /
1 MiB versus 84.239 ns for default options on Linux. Latency CPU spawn is
86.366 ns versus 86.820 ns normal; owned lane plus task is 14.532 µs versus
16.153 µs. Fairness is verified deterministically; timing is advisory.
MSG_RING cross-worker wake is 85.546 ns versus eventfd 66.089 ns (+29.4%)
at this checkpoint; the next source coalesces repeated outstanding messages.
SEND_ZC, linked deadlines, registered buffers, native open/stat, and SQPOLL
on/off rows are retained in the Linux JSON with five interleaved rounds.

## Remaining owner decisions and R6 handoff

V11 requires actual family suites, several of which hardwire `std.testing.io`
to Threaded. No other-package edits are authorized in this batch. Nav must
choose an isolated harness adaptation in this clone or separate adoption
batches before V11 can be claimed complete. Painting support and its synthetic
proof are not a substitute for those five measured suites.

Executor refusal currently returns an available resource error for fallible
calls. A void/narrow call, or refusal to schedule a cancellation job, cannot
represent that error and terminates. Nav must settle whether to keep that
contract or add a fallible offload API plus an injected-executor cancellation
capacity requirement. No inline fallback is used.

R6 continues on `later`, reads this evidence and raw rounds, settles pending
owner choices, performs its private rival pass and final architecture/README
review, then lands the combined branch under its own authorization. This
batch does not deploy R6 or update main. The book’s pending callback, fixed
files, binding and blockingHook rows lag existing published code; V11 and the
family adoptions remain pending.
