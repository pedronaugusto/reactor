# reactor design

reactor implements Zig's blocking-shaped `std.Io` on completion engines with
stackful tasks. A host may use the single-threaded `Loop`, the `Runtime` that
implements `std.Io`, or the any-Io extensions. Production code depends on std
and [aegis](https://github.com/pedronaugusto/aegis), the family's safety types.

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
| Inboxes and wake flags | Processor, written by any thread | On cache lines of their own, away from what the owner switches tasks with. |
| Task stack, saved context and cancel hook | Task | Stack remains until its result and asynchronous owners are gone. |
| Free stacks and size classes | Scheduler stack pools | Reserved at init; tagged atomic free lists prevent ABA. |
| Global inbox, idle and searching counts, steals | Scheduler | Written by many threads on cache lines of their own; the read-mostly fields stay off them. |
| Lane queues, launch workers, admission counts and executor capacity | Lanes | One guard each; queued jobs live in waiting task frames; executor relinquishes groups before return. |
| Futex waiters | Operations | One spin guard per bucket; hooks cannot outlive their frames. |
| Receive memory and registered buffers | Receiver pool | Unregister on every owning ring before releasing memory. |
| A receiver's kernel request and delivered buffers | Receiver | One guard; a buffer ring's publication has a guard of its own. |
| Resolver requests | Lookup | Bounded capacity includes detached requests until completion. |

The root task stays on the home thread. io_uring's submitter remains its loop
owner. Handoff is available only on readiness/IOCP processors whose kernel
queues can be driven by another thread. Foreign runtime tasks cannot enter a
local queue; ring messages are confined to the processors of one runtime.

## Scheduling

A task is found in this order: the LIFO slot (at most three times in a row),
the pinned and local queues, the global queue, the inbox, then half of another
processor's queue. Latency tasks (`concurrentWith`) run up to eight at a time
before queued normal work; a processor that has seen none takes the plain
path and never looks at priorities.

A task in the LIFO slot cannot be stolen, so spawning or waking one does not
wake an idle processor; only a task displaced into the queue does. A wake
sent to a sleeping processor reaches it at once: on io_uring as a ring
message submitted immediately (a source that never returns to its loop would
otherwise leave the target asleep with work waiting), elsewhere as the
backend's own wake.

Everything several threads write sits on lines of its own: the queues' heads,
tails and slots, a processor's inboxes and flags, the scheduler's counters.
On a two-thread runtime, a thief reading a queue that shared a line with a
field its owner wrote at every switch cost a spawn-and-await about 8%.

## Completion, cancellation and acquisition

Completion wins a cancellation race: completed bytes, sockets and process
results are preserved; a pending cancel is acknowledged at the next eligible
point. Timeouts cancel and drain every operation before returning storage to
the caller. SEND_ZC retains both primary and notification ownership, including
notification-first delivery and the ordinary-send retry. Registered files and
buffers are detached only after the kernel has relinquished their references.
A deadline is the wheel's timer and a cancel of the operation, except for
`connect` on io_uring, which links a kernel timeout: for every other operation
a linked timeout is two more entries and a kernel timer to save a cancel that
most operations never need.

Readiness records retain terminal read edges through the final bytes and EOF.
A close epoch invalidates that hint along with cached readiness and stream
kind before a descriptor number is reused.

A group's `await` returns only once every member has given its stack back.
Members count themselves in before they leave the group and out after the
release, so the group's lock is held for the unlink alone and the awaiter
waits outside it.

Initialization unwinds each acquisition with `errdefer`. Tables, stacks and
lane closure/scratch slots are reserved there. The caller must finish or
cancel its tasks before runtime teardown. Test-only allocation failures use
shakedown NoResize; tests poison released storage and force refused and delayed
completions. Native guards, cancellation and races need native evidence in
addition to cross compilation.

## Defaults and explicit costs

Task stacks reserve 1 MiB by default and have individual guards. Reservation
is address space; touching pages incurs resident cost. Additional classes are
reserved at init and an explicit request takes the smallest fitting available
class. `stats().parked_high_water` is the deepest park of any task, live or
ended; diagnostic painting (`measure_stacks`) adds the overall touched depth
and disables trimming. The default size changes only with suite measurements of both.

A task that parked deep and is parked shallower now keeps those pages until it
has been parked for a full second; then the loop that owns it gives them back.
Each loop has one init-reserved timer and a list of candidates; a candidate
pins its task there until resume, and resuming unlinks it before its stack can
run. Quick reuse never arms or cancels a timer. Cost: arming a candidate is
about 3% of a deep-park-and-resume.

Registered receive buffers, SQPOLL and zero-copy send are explicit options.
Zero-copy send is off by default: hosted loopback measurements found no
payload size where it paid. SQPOLL owns an extra kernel thread, and an unsupported explicit request
fails.

## Startup and executor capacity

`init` reserves storage and starts no threads. `start` creates the scheduler
workers and prepares the owned lane workers, with control capacity for
cancellation, before publishing the runtime as started: each lane's cap
running calls, one cancellation for each, and three more for child
termination and executor bookkeeping. A startup failure is returned to the
application and that runtime must be deinitialized. Fixed `std.Io` operations
require successful startup, checked in safe builds. With the default lanes on
a sixteen-core machine this is 132 parked threads and about a millisecond;
size the caps to the use.

Admission reserves execution and cancellation together. A queued call has its
own reservation; completing a call may serve the next queue member without
releasing the completed call's reservation. The reservation survives until
both its execution group and its individual cancellation group have retired.
Detached resolver requests retain their reservation and storage until reuse
or shutdown. Queue admission is bounded by the configured task and lookup
bounds. Owned executors use fixed closure and scratch pools and warmed
workers. Workers not yet needed park separately from the executor ready pool,
preserving warm-thread reuse for sequential calls. Admission activates a
prepared worker when concurrency requires it; submission waits for retiring
worker bookkeeping rather than creating a thread after startup.

An injected executor supplies an `Io` and declares capacity exclusive to the
runtime. Its guarantee covers submitted execution and cancellation groups,
including retirement after callbacks return. Admission charges two units per
call across all lanes, with two units kept for child termination. Termination
bypasses occupied ordinary wait slots; its reservation also survives
retirement. A capacity violation by the executor is a contract violation for a
fixed signature or cancellation, rather than an ordinary late refusal. Hosts
using a bounded executor must account for its retirement semantics when
declaring capacity.

Raw `blocking` and hook calls report `ConcurrencyUnavailable` at admission or
executor refusal, without running user code; a refused call never runs
inline. A fixed signature waits for admission capacity and keeps its
specified result type. The explicit `.none` profile borrows calls on the
caller's thread and counts them; it creates no lane threads. Outside callers
retain their stack through both executor groups. Foreign-runtime tasks resume
on their own scheduler.

## Suite measurements

Family-suite measurements belong to each package's move onto reactor. The
[isolated harness](../bench/v11/prepare.zig) keeps the seams already
investigated: cloak has no published TLS suite; airlock's raw close bypasses
fixed-file invalidation on Linux and its macOS write-call bound differs;
conduit uses a thread-spin mutex with a parked holder in its zero-worker
profile; relic has allocation, concurrency and transport questions; the
Windows uplink fixture crashes between tests and needs adoption-time
isolation.

## Safety types

Values that mean different things are different types, and data sits behind
the lock that guards it. aegis supplies them; nothing here costs more than the
hand-written form it replaced, and the hot paths were measured against the
code before.

- **Time.** The loop keeps one timeline, the awake clock. `clock.Awake` is a
  point on it in nanoseconds, `clock.Tick` the same point in the wheel's
  microseconds, `clock.Span` a length. They convert only through `clock`,
  which says how each rounds: a timer's tick rounds up, a clock reading's
  rounds down. A time from the caller (a deadline, `budget_time`, a stall
  threshold) saturates at the ends of the timeline instead of wrapping: a
  deadline 600 years away is a wait that never ends. `Wheel` takes and
  returns ticks; inside, a tick is a plain integer, since its placement is bit
  arithmetic on one kind of number. The kernel's own units (a timespec,
  whole milliseconds for `poll`, 100 ns on Windows) are cut in one place each.
- **Guards.** A lock beside its data is a `BlockingGuarded` (`Guarded`, the
  spin form, for a few stores that never park): the lane queue, launch workers
  and admission counts, the global inject queue, the spare-thread pool, a
  receiver's mailbox and a buffer ring's publication, `net.Deadlines`' watch
  list, a Windows job's notification mailbox, and a futex bucket's waiters. A
  parked task keeps its bucket's guard until it is off its stack; the
  scheduler releases it there.
- **Limits.** Executor capacity is a `Budget`: two units per admitted call,
  held by the call as a reservation from `admit` to `retire`, so a limit that
  would wrap refuses instead. The spare pool's processors and threads are
  `Buffer`s that cannot grow, and a Windows job's messages a `Ring` of 32.
- **Identity.** A stack is a `Stacks.Stack` among all of a runtime's;
  `Pool.Slot` is its place in one size class. `Stacks.locate` turns one into
  the other and nothing else does. A provided-buffer group is a
  `BufferRing.Id` with `BufferRing.Entries` buffers.
- **Bytes.** Stack sizes, `zero_copy_min`, a lane's scratch and a receiver
  pool's buffer length are `units.Bytes` in the options. Sizes and counts that
  come from the caller are multiplied and rounded with checks at the point
  they become a mapping or an allocation: past the address space they are
  refused (`SystemResources`, `OutOfMemory`, `TooManyTasks`), as are a worker
  count that would wrap the processor count.

### Raw sites kept

A plain integer or hand-written lock stays where one of these holds, and says
which beside the code (`glint-ignore: A004 -- <reason>: docs/design.md#safety-types`):

- **c-os-boundary**: the raw call itself: a `timespec`, `poll`'s i32 of
  milliseconds, an epoll or kevent field, a ring's index mask, a buffer group
  in the kernel's registration, an absolute deadline on the `real` or `boot`
  clock handed to a kernel timer, Windows' 100 ns, and the completion key a
  job notification carries (which holds the record's generation).
- **measured-boundary**: the wheel's placement, validated where a tick enters.
- **safe-type-internals**: `Stacks.locate` and the code that builds a stack
  number from a slot, an atomic cell that holds an `Awake`'s integer.
- **design**, no type fits:
  - A bit lock inside a word: a task's `cancel` word and a group's `state`,
    which std's `Io.Group` lays out.
  - Lock-free structures: the run queues, the inboxes, and the tagged free
    lists of stacks, lane closures and receive buffers. These are stacks of
    indices with a tag against ABA, not generation-checked slot maps, and no
    pool sits between the kernel and a lease.
  - The standard-error mutex, held across `lockStderr` and `unlockStderr`, two
    calls of std's vtable, and recursive by holder.
  - `Signals`' table, which the handlers read without a lock.

### Lock order

Each lock is taken by itself, except these nestings, always in this order: a
lane's queue before its launch workers, a receiver's mailbox before its buffer
ring's publication, and a task's cancel bit before a futex bucket (a cancel
hook runs under the bit and unlinks the waiter from its bucket). Every lock
here is taken uncancelable, since a cancel must not leave one half held, and
aegis's ordered guards only take a lock that may return `Canceled`; the order
is kept by this list and the tests rather than a checked rank.
