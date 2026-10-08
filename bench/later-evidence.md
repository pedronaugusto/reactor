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
| Zero-copy send (L5) | Ordinary send | Probed contiguous SEND_ZC; primary and notification ownership independent, notification-first handling, cancellation drain, ordinary-send fallback for unsupported requests. Native byte validation before buffer poisoning; invalid SEND_ZC flags force native EINVAL and verify the ordinary-SEND retry while the same frame stays retained. Opt-in `zero_copy_min`; default disabled by measurements. |
| SQPOLL (L6) | No option | Explicit setup, optional CPU affinity, idle wake handling, no backend downgrade. Idle NOP and published fixed-file close-reference fence checks. |
| Fixed files (R1) | `backend/uring/Files.zig`; `files_test.zig` covers rewriting unsubmitted references. Regular files only; sockets/pipes excluded. | Preserved; SQPOLL consumption fence added before unregister. Existing cross-ring close proof retained in `uring_ext_test.zig`. |
| Cross-ring messages (R1) | Eventfd wakes | MSG_RING target CQ wake; target deferred task work entered before inspection; eventfd fallback on unavailable/failed messaging. Repeated wakes coalesce until target consumption; a deliberately invalid native message request verifies the source-CQE eventfd fallback. Shutdown keeps direct eventfd wakes because stop joins without another source poll. |
| Linked timeouts (R1) | Wheel cancellation | IO_LINK plus absolute LINK_TIMEOUT, reserved two-entry submission, primary/timer lifetime drain, timeout mapping and batch retry. All generated completion permutations plus native blocked TCP read and retry. |
| Native open/stat (R1) | File worker/lane routes | Linux OPENAT/STATX, exact std flags/errors and lock behavior; native path bypasses inline general lane. Differential file content, size, resize, missing/exclusive errors and fault injection. Windows metadata remains on its designed file worker/lane route. |
| Native process waits (R1) | Linux pidfd; Windows wait-completion packets in `runtime/io_ops.zig`/`iocp_test.zig` | Linux WAITID where probed, pidfd fallback preserved; BSD/macOS process-watch wait before reaping. Zero wait-lane counters; historical Windows process tests preserved and rerun. |
| Idle trimming (R1) | Pool trimming function existed, unused by scheduler | Off-stack trimming below saved live SP; ended-task discard, retained diagnostic watermarks, opt-in overall painting. Linux discarded-page regression; deep/shallow parked byte preservation. Windows discard is disabled because the platform implementation is a no-op. |
| Lane backpressure (R1) | Queue already bounded by task frames; existing 1050-call/cap-one proof. Executor rejection ran inline; cap zero queued forever. | Explicit rejection completes without invoking user code; cap-zero refuses immediately. Failing-before regressions. No queue-full inline fallback. Narrow/void rejection contract remains an owner decision below. |
| Fault seam (R1) | PRNG fake scheduling, no injectable submit errors | One shared shakedown Source, fallible custom submit seam, failure sweep and ownership counters; FaultIo error/short/cancellation sweeps over native file operations. |
| Threaded differential (R1) | Individual conformance examples | 64 generated file sequences and 32 generated stream/EOF/batch-retry/futex-cancel sequences; semantic results compared with Threaded. Linux exercises io_uring and epoll; other native OSes use their backend. Windows Threaded has no network-batch implementation: shared stream/EOF/futex results are compared through operate, while reactor still asserts generated native batch timeout/retry on Windows. |
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

Measurements are best-of-five (minimum latency, maximum throughput), with raw rounds retained. Hosted VM CPU and
network noise prevents treating these numbers as portable guarantees. All
performance misses are reported; they are not silently accepted as wins.

## Hosted evidence so far

- Canonical FAST [37814002753](https://github.com/pedronaugusto/reactor/actions/runs/37814002753) passed for `95bb5a39a3e33f4b8335598a57e305c838760488`.
- Native FAST [37814086107](https://github.com/pedronaugusto/reactor/actions/runs/37814086107): Linux ownership/R1, macOS conformance/child, Windows conformance/V3/V6/V7/guard all passed; TSan and before harness failed and were corrected afterward.
- Native FAST [37815984146](https://github.com/pedronaugusto/reactor/actions/runs/37815984146): TSan and before harness passed, as did Linux R1 and Windows V3/V6/V7/conformance/guard. Linux ownership failed solely because the new adoption fixture supplied two buffers to three rings; corrected to four afterward.
- Before proof on exact main: rejected executor executes user code, cap-zero job never completes, Linux native open/stat increments inline counter four times, returned deep stack still contains byte 73, Linux interface bind panics in reverse name lookup. macOS native child wait increments the wait lane. Group-release and stop failures reproduce on the public first LATER checkpoint.
- Earlier canceled/failed run IDs are retained in the final handoff; they are not passing evidence.

Implementation checkpoint: `342c93dc982430e0b92aab740ce097990b4dc85e`.
Only test fixtures, benchmark tooling, evidence and test-dependency pins changed
after the measured production checkpoint `a55c5ec`. Final native validation is
recorded below; completion is still withheld for the remaining owner choices
and measured performance misses. No merge tier has been dispatched by this batch.

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

## Exact-main proof and final validation

The exact-main audit is supported by the historical native three-OS run above
and these tests in that revision:

- [Fixed files](https://github.com/pedronaugusto/reactor/blob/46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4/src/files_test.zig#L26): “removing a fixed file preserves requests not submitted yet”; cross-ring close in [uring_ext_test](https://github.com/pedronaugusto/reactor/blob/46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4/src/uring_ext_test.zig#L178).
- [Lane queue bound](https://github.com/pedronaugusto/reactor/blob/46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4/src/runtime_test.zig#L295): 1050 calls at cap one, zero inline calls. The rejection and cap-zero failures are separate remaining debts fixed here.
- [Linux pidfd](https://github.com/pedronaugusto/reactor/blob/46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4/src/uring_ext_test.zig#L94); [Windows process packets, precise timer and stack walk](https://github.com/pedronaugusto/reactor/blob/46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4/src/iocp_test.zig#L269).
- [Local endpoint binding](https://github.com/pedronaugusto/reactor/blob/46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4/src/net_test.zig#L320), and [blockingHook's sync lane](https://github.com/pedronaugusto/reactor/blob/46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4/src/ext_test.zig#L313).
- [Callback API and delivery](https://github.com/pedronaugusto/reactor/blob/46f6da8cba6b20ac3bc8e4cd6cba1d35861f19e4/src/Loop.zig#L71) were present. The new eight-resubmission proof preserves those entry points.

Canonical FAST [37819406203](https://github.com/pedronaugusto/reactor/actions/runs/37819406203)
passed for `e149af05359610d553ccca6b97bb1ceaea97818f`.
Canonical FAST [37820861453](https://github.com/pedronaugusto/reactor/actions/runs/37820861453)
passed for `f3746155caa42ee89c19ddf55e4eb1d5c5f62e82`.
Native FAST [37818638570](https://github.com/pedronaugusto/reactor/actions/runs/37818638570)
passed Linux ownership, R1, conformance TSan, before regressions and A/B;
macOS ownership/R1/conformance; Windows V3/V6/V7/conformance/guard. Its Windows
ownership job exposed Threaded's unsupported network batch and cleanup panic.
Native FAST [37819626000](https://github.com/pedronaugusto/reactor/actions/runs/37819626000)
passed the corrected native Windows ownership fixture and Linux TSan over
LATER ownership, R1 and latency-priority tests.

Native FAST [37820981004](https://github.com/pedronaugusto/reactor/actions/runs/37820981004)
passed the added Linux process and deep-stack A/B rows. The process row includes
spawn plus exit-zero wait, so it does not isolate kernel wait cost. The stack
row uses two Event handshakes, verifies the actual live parked depth through
public `dump`, and prevents scalar replacement of the 192 KiB frame before
timing. No nanosecond timer can bypass either park.

Local targeted checks on Zig 0.17.0 include LATER ownership (latest seed
2275631589), generated streams (2174909599), class/engine allocation failure
sweeps with NoResize, group-release stress and native macOS child waits;
Linux/Windows cross-checks and lint passed. Hosted runners supply native Linux
and Windows evidence; no shared Lima VM was used.

Final pin audit: reactor main remains the requested `46f6da8`; preflight remains
newest green main `9af905ed85cab6dbb19d9431c65ee3f41fbaa74d`; shakedown advanced
to `9357a9ab398ac25fa8a408a71e77a124bc51d311` and is pinned here as a lazy
test-only dependency. Its intervening changes add the benchmark measuring
module and export the comparator artifact; Source/FaultIo contracts are unchanged.

Canonical FAST [37822544273](https://github.com/pedronaugusto/reactor/actions/runs/37822544273)
passed for the implementation checkpoint `342c93dc982430e0b92aab740ce097990b4dc85e`.
Native FAST [37822672404](https://github.com/pedronaugusto/reactor/actions/runs/37822672404)
passed all 17 jobs: three-OS LATER ownership/conformance, Linux R1 and
failing-before regressions, macOS native child wait, Windows V3/V6/V7/guard,
and Linux TSan over conformance, LATER ownership, R1 and latency queues.
The deliberately failed MSG_RING and invalid SEND_ZC requests are included
in both native Linux ownership and its sanitizer run. No native capability
was substituted by a portable compile check. The earlier A/B capability row
reports fixed files, MSG_RING, linked timeout, WAITID, SEND_ZC and registered
buffers available on the Linux runner; explicit SQPOLL A/B also succeeded.

The [retained run manifest](later-results/native-fast-342c93d.json) records
source and baseline SHAs, job IDs and all conclusions. The native scratch
snapshot differs from the public implementation checkpoint only in its
FAST-only workflow; that temporary remote branch is deleted after collecting
its evidence. Documentation/manifest commits after the checkpoint do not
change production, test or benchmark code.

## Latest measured costs and feature A/B

Raw Linux five-round interleaved measurements:
[production checkpoint a55c5ec](later-results/linux-a55c5ec.jsonl),
[additional cost rows](later-results/linux-costs-f374615.jsonl).
Raw macOS [additional cost rows](later-results/macos-costs-e149af0.jsonl).
The earlier macOS production rows above are still applicable: subsequent
production changes only concern the Linux ring.

| Linux row | Before/off → after/on, best of five | Assessment |
| --- | --- | --- |
| Default empty spawn + await | 108.740 → 133.751 ns | +23.0%; raised to nav/R6 |
| Group of 10k | 264.834 → 291.502 ns/task | +10.1%; raised |
| Task ping-pong | 64.820 → 70.334 ns/wake | +8.5%; raised |
| Empty loop run | 19.738 → 19.254 ns | −2.5% |
| Default → explicit 64 KiB | 134.228 → 136.265 ns/task | +1.5% |
| Default → explicit 256 KiB | 134.573 → 136.770 ns/task | +1.6% |
| Default → explicit 1 MiB | 134.649 → 135.357 ns/task | +0.5% |
| Normal → latency task | 133.825 → 128.763 ns/task | −3.8%; fairness is the deterministic guarantee |
| Normal → latency owned lane | 21.736 → 21.265 µs/call | −2.2%; advisory |
| Ordinary → fixed file | 1011.732 → 1011.743 ns/read | No measured gain |
| Eventfd → coalesced MSG_RING | 87.355 → 85.637 ns/wake | −2.0% in this run; do not compare absolute costs across different runners |
| Wheel → linked deadline | 56027.827 → 53575.735 msg/s | −4.4% throughput; raised |
| Lane → native open/stat/close | 53.716 → 28.157 µs/call | −47.6% |
| Ordinary → registered buffer | 1010.597 → 1010.477 ns/read | No material measured gain |
| Ordinary → SQPOLL | 1009.921 → 1016.307 ns/read | +0.6%; explicit opt-in, no gain claimed |
| Process spawn + exit-zero wait | 766.675 → 754.258 µs/call | −1.6%; includes process startup |
| Forced deep/shallow park + reuse | 0.854 → 80.158 µs/call | +79.305 µs, 93.9×; raised |

| SEND_ZC payload | Copy → zero-copy throughput (MiB/s) | Change |
| --- | --- | --- |
| 512 B | 43.787 → 36.060 | −17.6% |
| 4 KiB | 340.565 → 284.549 | −16.4% |
| 16 KiB | 1275.353 → 976.403 | −23.4% |
| 64 KiB | 2227.969 → 1689.655 | −24.2% |
| 1 MiB | 2619.377 → 1986.498 | −24.2% |

SEND_ZC stays disabled by default. macOS process spawn plus wait is 2.048 →
2.021 ms (−1.3%). Its validated deep/shallow reuse row is 0.481 → 6.996 µs
(+6.515 µs, 14.5×). Immediate reclaim/refault of a repeatedly reused deep frame
has a substantial cost on both systems. Idle/reuse policy needs performance
work before a completion claim; the Linux page-discard and native live-byte
proofs establish safety, not an acceptable throughput tradeoff. This miss is
explicitly raised under the owner's measured-miss reporting instruction.

The old 0f6921c explicit-class control aggregated fifteen default rounds;
the new labels pair each size with its own five-round control. Hosted VM noise
and a different CPU explain changing absolute numbers; no cross-host ratio is
claimed. Non-runtime verification additions (faults, shrinking, deaths and
SEH) have no production hot path of their own. Binding preserves its default
path; the existing echo/deadline rows measure the affected dial/IO route.

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

R6 continues on `later`, reads this evidence and raw rounds, resolves the
measured spawn/deadline/trimming misses and pending owner choices, performs its private rival pass and final architecture/README
review, then lands the combined branch under its own authorization. This
batch does not deploy R6 or update main. The book’s pending callback, fixed
files, binding and blockingHook rows lag existing published code; V11 and the
family adoptions remain pending.

## Run history that is not passing evidence

Canceled/superseded FAST: 37807395527, 37808721071, 37808725848,
37811164017, 37812840859, 37817961997 and 37818455942. Invalid/cold-bootstrap or failing
FAST checkpoints: 37811082833, 37811712188, 37812871921, 37814086107,
37815925494 and 37815984146. Some targeted jobs in failed runs
passed; only the explicitly named jobs above are cited as evidence.
37808725848 used a reusable workflow which ignored the intended native
matrix and is not Windows/native-A/B proof. Checkpoint 71633b9 contained a missing
opaque pointer conversion in the pressure hook, caught by the local cross-check;
a55c5ec appends its correction and 37817961997 was superseded.
No pushed history was rewritten.

The before harness proves group release and shutdown against f110c794, where
this batch exposed them. A separate exact-main macOS group stress did not
reproduce the release assertion; it is not claimed as failing-before proof.
The mutable-engine copies were exposed by the later Debug layout under TSan;
the fixed pointer storage passed conformance and expanded sanitizer checks.
