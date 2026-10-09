# reactor design

reactor implements Zig's blocking-shaped `std.Io` on completion engines with
stackful tasks. A host may use the single-threaded `Loop`, the `Runtime` that
implements `std.Io`, or the any-Io extensions. Production depends only on std.
The combined LATER/R6 phase remains work in progress.

## Layers and state owners

The production graph is enforced by [ci/layers.zig](../ci/layers.zig), lowest
first: system calls; fibers, time and lanes; backends; loop; scheduler;
operations; runtime; extensions; root facade. Test sources belong to no
production layer. Each backend imports the common interface, never another
backend. The fake backend and virtual clock are test support.

| State | Owner | Lifetime and thread rule |
| --- | --- | --- |
| Backend, descriptor registrations, wheel and heaps | Loop | One submitting processor; teardown drains kernel ownership. |
| Run queues, LIFO slot and current task | Processor | Exactly one thread owns it; handoff uses release/acquire. |
| Task stack, saved context and cancel hook | Task | Stack remains until its result and asynchronous owners are gone. |
| Free stacks and size classes | Scheduler stack pools | Reserved at init; tagged atomic free lists prevent ABA. |
| Global inbox, worker placement and shutdown | Scheduler | Cross-thread publication; independent runtime identity checked. |
| Lane queues and call/cancel groups | Lanes | Queued jobs live in waiting task frames; executor relinquishes groups before return. |
| Futex waiters | Operations | One lock per bucket; hooks cannot outlive their frames. |
| Receive memory and registered buffers | Receiver pool | Unregister on every owning ring before releasing memory. |
| Resolver requests | Lookup | Bounded capacity includes detached requests until completion. |

The root task stays on the home thread. io_uring's submitter remains its loop
owner. Handoff is available only on readiness/IOCP processors whose kernel
queues can be driven by another thread. Foreign runtime tasks cannot enter a
local queue; ring messages require a shared scheduler lifetime.

## Completion, cancellation and acquisition

Completion wins a cancellation race: completed bytes, sockets and process
results are preserved; a pending cancel is acknowledged at the next eligible
point. Timeouts cancel and drain every operation before returning storage to
the caller. SEND_ZC retains both primary and notification ownership, including
notification-first delivery and the ordinary-send retry. Registered files and
buffers are detached only after the kernel has relinquished their references.

Readiness records retain terminal read edges through the final bytes and EOF.
A close epoch invalidates that hint along with cached readiness and stream
kind before a descriptor number is reused.

Initialization unwinds each acquisition with `errdefer`. Tables, stacks and
lane closure/scratch slots are reserved there. The caller must finish or
cancel its tasks before runtime teardown. Test-only allocation failures use
shakedown NoResize; tests poison released storage and force refused and delayed
completions. Native guards, cancellation and races require native evidence in
addition to cross compilation.

## Defaults and explicit costs

Task stacks reserve 1 MiB by default and have individual guards. Reservation
is address space; touching pages incurs resident cost. Additional classes are
reserved at init and an explicit request takes the smallest fitting available
class. Latency work has a bounded burst of eight before normal queued work.
Diagnostic painting measures overall touched depth and disables trimming;
parked depth is retained independently. Suite measurements must establish
both watermarks before changing the default.

Registered receive buffers, SQPOLL and zero-copy send are explicit options.
Zero-copy send remains disabled by default: retained measurements found no
payload size where it justified enabling the default. SQPOLL owns an extra
kernel thread and makes an unsupported explicit request fail. No feature cost
or unavailable capability is counted as target success.

## Final review and open work

Rival speed and size targets remain reporting obligations. The owner restored
the rule that regressions against reactor's previous main must be fixed before
landing; correctness and green CI remain required. Missing rival targets remain
open in the mission. Shared-machine timing uses paired, interleaved ratios
with spread. Native x86 rows stay open until hardware is available.

Unused pages are discarded only after a task has been parked for a full
second. Each owning loop has one init-reserved timer and a list of idle
candidates. A candidate pins the task there until resume; resumption unlinks
it before its stack can run or be released. The timer may outlast its last
candidate and is canceled before loop teardown. Quick reuse does not repeatedly
arm and cancel timers. Ended
stacks remain warm in the free pool, avoiding repeated discard/refault on
immediate reuse. Retained free-stack pages are a resource cost until reuse or
runtime teardown. Diagnostic painting still disables trimming.

The one-worker group-spawn observation remains +37.9%. The ownership follow-up
adds scheduler identity checks so independent runtimes cannot run one
another's tasks or retain one another's ring storage. That safety is retained;
newer noisy samples do not establish recovery. Default spawn, wakes and linked
timeout throughput also retain measured misses. Opt-in feature costs and
missing workloads remain explicit in the private measurement rows.

Raw offload refusal is fallible for every result shape, including void, under
db221e5. No refused call runs inline. The remaining fixed std.Io signatures
and injected cancellation capacity are described in the executor review below.

V11 completion moves to each package's own move onto reactor. The
[isolated harness](../bench/v11/prepare.zig) keeps the initial immutable
measurements and uncovered seams: cloak has no published TLS suite; airlock's
raw close bypasses fixed-file invalidation on Linux and its macOS write-call
bound differs; conduit uses a thread-spin mutex with a parked holder in its
zero-worker profile; relic has allocation/concurrency and transport questions;
the Windows uplink fixture crashes between tests and needs adoption-time
isolation. None is converted into a completed-suite watermark or hidden by a
consumer edit. Default stack size and zero-copy defaults remain unchanged.

The combined LATER/R6 phase is work in progress until its correctness review
and exact final-head FAST and MERGE tiers pass and main is fast-forwarded.

## Executor capacity

`init` reserves storage and starts no threads. `start` prepares the owned lane
workers, including control capacity for cancellation, before publishing the
runtime as started. A startup failure is returned to the application; that
runtime must be deinitialized. Fixed `std.Io` operations require successful
startup, checked in safe builds.

Admission reserves execution and cancellation together. A queued call has its
own reservation; completing a call may serve the next queue member without
releasing the completed call's reservation. The reservation survives until
both its execution group and its individual cancellation group have retired.
Detached resolver requests retain their reservation and storage until reuse
or shutdown. Queue admission is bounded by the configured task and lookup
bounds. Owned executors use fixed closure and scratch pools, and warmed
workers; submission waits for retiring worker bookkeeping rather than
creating a thread after startup.

An injected executor supplies an `Io` and declares capacity exclusive to the
runtime. Its guarantee covers submitted execution and cancellation groups,
including retirement after callbacks return. Admission charges two units
per call across all lanes, with two units kept for child termination. Termination bypasses occupied ordinary wait slots; its reservation also survives retirement. A capacity violation by the executor is a contract
violation for a fixed signature or cancellation, rather than an ordinary
late refusal. Hosts using a bounded executor must account for its retirement
semantics when declaring capacity.

Raw `blocking` and hook calls report `ConcurrencyUnavailable` at admission
or executor refusal, without running user code. A fixed signature waits for
admission capacity and retains its specified result type. The explicit
`.none` profile borrows calls on the caller's thread and counts them; it
creates no lane threads. Outside callers retain their stack through both
executor groups. Foreign-runtime tasks resume on their own scheduler.
