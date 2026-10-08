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

## Remaining review gates

The existing immediate deep-stack discard policy differs from the intended
one-second idle policy and has a measured reuse penalty. R6 must resolve the
performance and idle-memory tradeoff with live-byte and lifecycle proofs.
Default spawn, one-worker group spawn, wakes and linked deadlines also retain
measured misses; the complete manual workload/target pass is still pending.

Injected executor refusal returns a representable resource error for fallible
calls. A narrow/void call or refused cancellation job currently terminates.
The owner decision on a fallible raw-offload API and guaranteed cancellation
capacity remains pending; [the minimal alternative](executor-decision.md)
explains the remaining std.Io seam and required ownership accounting. This
document does not accept the current behavior as the finished design. Refusal never runs a call inline.

The published cloak source currently has no TLS engine suite. Its package
floor cannot establish V11 TLS depth. Actual suites and partial observations
are recorded by [the isolated harness](../bench/v11/README.md), without editing
or adopting a consumer. No completion claim is made before all required
measurements, native correctness, performance targets and final CI pass.

Actual airlock trials also expose a Linux raw-descriptor seam: its raw close
bypasses reactor's fixed-file cache removal. Its macOS write-call bound differs
under this Io. These actual-suite failures remain explicit consumer contract
or adoption questions; no library source, expectation or default is changed
by the instrumentation to hide them.

The actual conduit zero-worker suite can spin in a thread mutex while its
holder is suspended in an Io wait. A thread yield cannot schedule a different
fiber on that same thread. The required consumer profile or cooperative-lock
seam remains an owner decision; instrumentation does not alter that lock or
silently select a different profile.
