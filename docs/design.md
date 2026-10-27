# reactor design

reactor implements Zig's blocking-shaped `std.Io` on completion engines with
stackful tasks. A host may use the single-threaded `Loop`, the `Runtime` that
implements `std.Io`, or the any-Io extensions. Production code depends on std,
[aegis](https://github.com/pedronaugusto/aegis), the family's safety types, and
[shuttle](https://github.com/pedronaugusto/shuttle), whose contexts, stacks and
handoff a task runs on.

## Layers and state owners

The production graph is enforced by [ci/layers.zig](../ci/layers.zig), lowest
first: system calls; time and lanes; backends; loop; scheduler;
operations; runtime; extensions; root facade. Test sources belong to no
production layer. Each backend imports the common interface, never another
backend. The fake backend and virtual clock are test support.

| State | Owner | Lifetime and thread rule |
| --- | --- | --- |
| Backend, descriptor registrations, wheel and heaps | Loop | One submitting processor; teardown drains kernel ownership. |
| Run queues, LIFO slot and current task | Processor | Exactly one thread owns it; lending and handoff order owner and monitor (below). |
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

## Lending and handoff

There a worker lends its processor whenever its task leaves the runtime: for
the task's own code, from each return out of a call to the next call in, and
for a blocking call. A thread says where it is in its seat's stage, written
by it alone; the monitor says what it did with the processor in the
processor's lease. On the way in a thread stores its stage and then reads
the lease; the monitor claims the lease and then reads the stage; all four
sequentially consistent, so of the two at least one sees the other: the
monitor backs off, or the thread waits until the monitor's look is over.
The way in and out costs two stores and a load, no read-modify-write. Every
runtime's slots take the calling thread's processor back on the way in,
whichever runtime lent it (a task of one runtime may call another's); in a
process where no runtime lends, that is one load of a process-wide count.

The monitor reads a processor's lease word before its owner, and the owner
is stored before the word when a thread takes the processor over, so a
claim made on the word read fails once the processor changed hands. A
lending that lasts `handoff_after`, seen in two samples, hands the
processor to a spare thread when it has work only its owner can do: tasks
queued there, operations and timers in its loop, the home thread asking for
it. A thread giving the home processor back waits out a look of the
monitor's, as one coming back in does. A spare holding the home processor
keeps a ready root aside until the home thread asks, so the processor is
never left with no thread while the home thread runs a task of its own.
The monitor stops before any processor's thread may end: it reads their
seats. A thread that lost its
processor keeps running its task's own code, the processor's record of it
another thread's by then, so a task finds its way back through its thread's
seat: at its next call it leaves the thread, which waits as a spare, and
goes where a woken task goes (its own processor under `per_core` or when
pinned, else the global queue); the root waits for the home processor to be
given back. Cancellation of a long loop stays cooperative: a task that never
calls in is never stopped.

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
point. A cancel from another thread reaches the processor holding the wait as a
message in the wait's own record, in the waiting task's frame; the task does
not leave the wait until the processor has served the message, so a message
never names a record that has been released. Timeouts cancel and drain every operation before returning storage to
the caller. SEND_ZC retains both primary and notification ownership, including
notification-first delivery and the ordinary-send retry. Registered files and
buffers are detached only after the kernel has relinquished their references.
A ring holds as fixed files only the files the runtime opened and has not
closed (`Kept`): a slot is the file it was made with, and only the runtime
sees both ends of its own files' lives. A descriptor opened or closed outside
the `Io` is used by its number, so a slot never outlives its descriptor and
serves a later file of that number (reactor 0.8.6; airlock's raw close of its
temps made a later write land in an earlier file). A bare `Loop` holds those
its caller records in `Options.kept`.
A deadline is the wheel's timer and a cancel of the operation, except for
`connect` on io_uring, which links a kernel timeout: for every other operation
a linked timeout is two more entries and a kernel timer to save a cancel that
most operations never need.

Sockets are called with `MSG_DONTWAIT`, which a send on Darwin ignores while the socket is in blocking mode: there the backend puts a socket in non-blocking mode before it writes to it (`socket.send_honors_dontwait`), where elsewhere every socket keeps the mode it was opened in.

Readiness records retain terminal read edges through the final bytes and EOF.
A close epoch invalidates that hint along with cached readiness and stream
kind before a descriptor number is reused.

A group's `await` returns only once every member has given its stack back.
Members count themselves in before they leave the group and out after the
release, so the awaiter waits for the stacks outside the group's lock. std
reads the group's `token` without the runtime, and `Group.await` and `cancel`
return at once when it is null, after which the owner may reuse or free the
group. So the token holds a `held` bit from the first member on, beside the
member count, the lock bit and the cancel bit, and only the runtime's own
await or cancel clears it, after that wait. A member is counted in and out
with one atomic add each, without the lock and without touching another
member's record: a spawner and the members finishing on other processors
share no critical section (a 10k-member group with workers took 25% longer
when every member linked itself into a list under the lock). The lock guards
the group's `state` alone: the list of members a cancel must reach, those
that have entered a cancelable wait, each listed at its first; a member not
listed takes the group's cancel at its next cancelation point, and one
started after it is born canceled. While the group is awaited, `state` holds
the awaiter, which holds the list for it.

Initialization unwinds each acquisition with `errdefer`. Tables, stacks and
lane closure/scratch slots are reserved there. The caller must finish or
cancel its tasks before runtime teardown. Test-only allocation failures use
shakedown NoResize; tests poison released storage and force refused and delayed
completions. Native guards, cancellation and races need native evidence in
addition to cross compilation.

## Defaults and explicit costs

Task stacks reserve 1 MiB by default and have individual guards. Reservation
is address space; touching pages incurs resident cost. Every class is reserved
at init, in one no-access mapping (shuttle's pool), and an explicit request
takes the smallest fitting available class. A stack is made usable, committed
as touched and guarded, the first time a task takes it, and kept so for reuse;
should the system refuse that mid-run (strict overcommit, the map count, the
Windows commit limit), the spawn returns `ConcurrencyUnavailable`, std's name
for resource exhaustion, and `async` runs the function inline as std's does. `stats().parked_high_water` is the deepest park of any task, live or
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

## Extensions on another Io

An extension keeps its promise on every `Io`: natively on a runtime, and on
any other through the slots that `Io` has. Where std's own slot breaks the
promise on a platform, the extension makes the call itself through
`Io.operate`, so no caller catches std's gap.

| Extension | std's gap | What the extension does |
| --- | --- | --- |
| `net.connectUnix` | `Io.Threaded`'s Windows unix connect (Zig 0.17) drives AFD itself, and the system refuses it: the AF_UNIX endpoint will not open in a process that has not used AF_UNIX through Winsock, its unnamed bind fails once a listener is at the path (`INVALID_PARAMETER`), and every status but resources is `Unexpected`. | On Windows over any `Io` but a runtime, it connects through Winsock (`sys/unix_windows.zig`: `socket` and `connect` with the path as given), as Git for Windows and every Winsock program do; Winsock is started once for the process and left running. `WSAECONNREFUSED` (nothing listening, or no socket at the path) is `ConnectionRefused`, `WSAENETDOWN` (a directory missing on the way) `FileNotFound`. The handle is a socket std's streams read, write and close. A runtime, and every other system, connects by `UnixAddress.connect`. |

## Named pipes

A named pipe is Windows' door to a local daemon, as a Unix socket is
elsewhere, and the same handle model carries it: `net.connectPipe` and
`net.listenPipe` open every handle for overlapped calls and hand it over
as an `Io.File` with `nonblocking` set, so a runtime finishes its reads,
writes and the listen (`FSCTL_PIPE_LISTEN`, a device control the port
already takes) on its port, and std waits on them itself. Nothing is
added to a backend. A connect to a busy pipe tries again after a short
cancelable sleep until its timeout, as Go's winio does: the free instance
it waits for is made by the server's next accept, which no event names.
A listener keeps one instance waiting and makes the next as each client
is accepted, so a client between accepts finds one; it takes its
security descriptor from the caller and has no default, since a pipe is
a door into the server, and refuses clients of other machines.

A pipe's deadlines are kept where each operation carries its own, on a
runtime. Elsewhere `Deadlines.add` refuses a pipe's watch and its
operations run unbounded, said rather than guessed at: std's own wait on
an overlapped call ends only as the call does, and a cancel from outside
reaches it as a state it does not expect. `pipe.readPipeWithin` is the
bounded wait for bytes a connection's idle check needs, on a runtime;
elsewhere it says `unbounded`.

## Workers

A runtime started without `workers` runs the logical CPUs less one, and on Darwin a quarter of them. The kernel's loopback path there costs more per message with more threads in it (a thread for each socket plateaus at ~165k 64-byte round trips a second however many there are; system time per message on 15 workers was twice that on 4), so tasks that talk to each other through sockets run faster on a few workers, while arithmetic-only tasks scale to every CPU. The quarter is measured on one machine (Apple M3 Max, 16 CPUs): 2 to 4 workers were best for sockets, 15 for arithmetic.

## Startup and executor capacity

`init` reserves storage and starts no threads. What it guarantees is the
reservations and the caps: every task stack's address space and the
`max_tasks` bound, the lanes' closure and scratch pools, the loops' tables.
What is lazy is everything a program may never use: a task stack is made
usable when first taken, and a lane starts no thread until a call needs one.
`start` creates the scheduler workers (and the monitor) and publishes the
runtime as started; a startup failure is returned to the application and that
runtime must be deinitialized. Fixed `std.Io` operations require successful
startup, checked in safe builds. A program on the default options measured on
an Apple M3 Max: `init` 0.7 ms, `start` 0.04 ms, `stop` and `deinit` 0.1 ms,
11 MiB resident, where the stacks guarded at init and the warmed lane workers
took 7, 1.8 and 5 ms and 16 MiB. The rest of that resident memory is the
tables sized by `max_tasks` (the loops' operation tables, task records), about
half a KiB a task.

An owned lane grows before a call starts on it to two threads for each call
it runs (the call's own, and one a cancel of it runs on) and three more (two
for child termination, one for a thread still leaving), never past its cap's
`2 × cap + 3`, and never shrinks. A cancel and a control call therefore never
wait on a thread being made, and submission waits only for a leaving thread's
bookkeeping. Growth starts reserve jobs on the lane's executor until it has
made enough threads (std's makes one only when none is idle; a reserve job
that finds its thread new counts it); they hold their threads apart from the
executor's ready pool, and one is let go into it only when every thread there
is busy, so sequential calls reuse one warm thread, as they did when every
worker was started at `start`.
When a lane cannot grow (the system refuses a thread), the call queues behind
the calls the lane runs, which hold their threads; a lane running none refuses
it: a raw call returns `ConcurrencyUnavailable`, and a fixed signature, which
has no error for it, waits and tries again as it waits for admission.

Admission reserves execution and cancellation together. A queued call has its
own reservation; completing a call may serve the next queue member without
releasing the completed call's reservation. The reservation survives until
both its execution group and its individual cancellation group have retired.
Detached resolver requests retain their reservation and storage until reuse
or shutdown. Queue admission is bounded by the configured task and lookup
bounds. Owned executors use fixed closure and scratch pools and the threads
their lanes grew.

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
investigated: cloak has no published TLS suite; airlock's raw close bypassed
fixed-file invalidation on Linux (fixed in 0.8.6: such a file is never held)
and its macOS write-call bound differs;
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
- **Identity.** A stack is a `stacks.Number` among all of a runtime's, which
  shuttle's `Pool.number` gives; the records and trims beside the pool are
  indexed by it. A provided-buffer group is a
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
- **safe-type-internals**: an atomic cell that holds an `Awake`'s integer.
- **design**, no type fits:
  - A bit lock inside a word: a task's `cancel` word and a group's `token`,
    which std's `Io.Group` lays out.
  - Lock-free structures: the run queues, the inboxes, and the tagged free
    lists of lane closures and receive buffers (shuttle's pool keeps the
    stacks'). These are stacks of
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
