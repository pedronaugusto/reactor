# reactor

reactor is an evented `std.Io` for Zig: every slot of the interface on the
kernel's own completion queue, with stackful tasks on a work-stealing
scheduler, and the loop under it usable alone. A program swaps `Io.Threaded`
for `reactor.Runtime` and changes nothing else. A host that owns its loop (a
frame loop, a job system) drives it without giving up a thread.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/reactor`, then obtain the `reactor` module
through `b.dependency` and add it to your executable's imports. reactor depends
on std and [aegis](https://github.com/pedronaugusto/aegis), which depends on
std alone and is fetched with it.

## Usage

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const reactor = @import("reactor");

var runtime: reactor.Runtime = undefined;
runtime.init(gpa, .{}) catch |err| switch (err) {
    // No evented backend on this system yet.
    error.BackendUnavailable => return,
    else => |e| return e,
};
defer runtime.deinit();
try runtime.start();
const io = runtime.io();

// Plain std.Io code: a thousand tasks, each a stack of its own, none a
// thread.
var total: std.atomic.Value(u64) = .init(0);
var group: std.Io.Group = .init;
for (0..1000) |i| group.async(io, work, .{ io, i, &total });
try group.await(io);
std.debug.assert(total.load(.monotonic) == 1000 * 999 / 2);
```
<!-- END GENERATED -->

## Design

`Runtime.init` starts no threads. Call fallible `Runtime.start` before using
its `std.Io`; safe builds check this precondition. Startup creates the
scheduler workers and prepares the owned offload lanes: for each lane its cap
of running calls, one cancellation for each and three more, parked until a
call needs them (132 threads with the defaults on sixteen cores). A failed
startup is returned and the runtime must be deinitialized. With `workers = 0`
and `offload = .none` the runtime has no thread of its own.

`Loop` owns one completion engine and its timers. `Runtime` owns the scheduler,
stacks and offload lanes. Extensions take a plain `std.Io`, leaving protocol
and application policy with the caller. The checked production layers and
state owners are documented in [the design](docs/design.md).

A task may move to another thread at any `Io` call: with workers, the idle one
takes what waits behind a busy one. A thread-local's address is the thread's,
so a task does not keep one across such a call, and an optimizing compiler
may keep one for it (on aarch64 the address is a register read, which LLVM
merges across the call): read a thread-local through a call that is not
inlined, as std's `Thread.getCurrentId` is read in reactor's own tests.

### Task and kernel options

Reserve stack classes in `Runtime.Options.stack_classes`, whose counts come
out of `max_tasks`. `concurrentWith(io, options, f, args)` chooses a reserved
`stack_size` and a `priority` (`normal` or `latency`). Latency work receives
up to eight turns before queued normal work, on CPU and blocking lanes.
Byte counts in the options are aegis `units.Bytes`, written
`.stack_size = .literal("256KiB")`; a size or count too large to map or
allocate is refused with an error.

`net.Receiver.Pool.Options.registered` registers the pool on each native
ring for fixed file reads and writes. Keep the pool alive until its operations
finish; `deinit` unregisters it on the ring owners before freeing memory.
`zero_copy_min` explicitly enables SEND_ZC above a contiguous-send size.
The default disables it: the hosted loopback measurements found it slower
at every tested size. `sqpoll` explicitly requests a kernel polling thread;
an unsupported request returns an error. Both options are Linux-specific.

`workers` defaults to the logical CPUs less one, which work that computes
needs, and on macOS to a quarter of them, at least one. Tasks that do little
but wake one another, such as a client and a server in one runtime trading
small messages, run faster on fewer threads: each exchange then crosses
threads that sleep, and macOS's loopback costs the kernel more per message
the more threads are in it (on 16 CPUs, 32 connections of 64-byte round trips
ran 155k a second on 15 workers and 225k on 4). On Linux's io_uring such a
benchmark scaled to 4 workers and held there. A host whose tasks are mostly
arithmetic on macOS sets `workers` to the CPUs it has.

`measure_stacks` enables diagnostic painting for overall touched depth.
`stats().parked_high_water` is retained across task release;
`stack_high_water` is available with painting enabled. Profiling commits and
scans stack memory, so leave it off when timing production workloads.
Family-suite V11 measurements belong to each package's adoption.

Architecture and ownership: [design](docs/design.md).
Benchmarks are code in `bench/`; measurements are maintained separately.

## API

### Runtime and loop

- **Every `std.Io` slot.** Sockets, files, timers, futexes, batches and
  cancellation run on io_uring, epoll, kqueue or IOCP over AFD; calls that can block
  for milliseconds (directory walks, `flock`, process waits) run off the
  workers on owned `Io.Threaded` lanes, so std's own code and std's own
  cancellation serve them; calls that never block run std's code on the
  worker.
- **A file sent to a socket** (`Writer.sendFile`, the `netWriteFile`
  slot) goes by the kernel's `sendfile` on Linux and Darwin, where
  `Io.Threaded` has none and a writer copies through memory: each send
  waits for the socket to be writable through the task's loop and asks
  for what its room takes. Under a kernel record layer (kTLS) the kernel
  seals what it sends. Darwin sends from a positional reader only; other
  systems copy.
- **epoll and kqueue** make a socket's call at once and wait for readiness
  only when it would block, with each descriptor registered once for its
  life. File calls run on the worker. A worker lends its processor while
  its task runs its own code or sits in a blocking call; should either last
  past `handoff_after` with tasks queued there or operations in its loop, a
  monitor thread hands the processor to a spare thread, so they go on, under
  `stealing` and `per_core` alike, and the task rejoins a processor at its
  next call into the runtime. No signals: a task is never preempted. A
  listening socket reactor accepts on is put in non-blocking mode.
- **std's cancellation exactly.** A cancel lands at the next cancelation point;
  an operation the kernel finished first keeps its result. `operateTimeout` and
  `Batch.awaitConcurrent` never return while the kernel still holds a buffer.
- **Work stealing**, or `per_core` shared nothing; the root never leaves the
  thread that built the runtime.
- **No allocation after `init`.** Stacks are reserved in slabs at `init`, in
  [shuttle](https://github.com/pedronaugusto/shuttle)'s pool, each with its own
  guard; lane
  closures come from a pool reserved there.
- **`Loop`**: one thread's completion engine with no threads of its own, driven
  by `run(.nowait)`, `run(.once)` or `run(.until)`, completions by callback or
  `reap`; on Windows it can share the host’s completion port.
- **Offload lanes.** An owned lane is an `Io.Threaded` with fixed closure
  storage. An injected one is `.{ .injected = .{ .io = host_io, .capacity = n } }`:
  `n` is capacity reserved exclusively for reactor, including retiring execution
  and cancellation jobs, two units per admitted call and two kept for child
  termination. Raw offloads refuse at admission; fixed-signature operations
  wait for admission capacity and never run inline.
- **Embedding.** A host that owns its loop waits on `Runtime.backendHandle`
  for at most `nextTimeout` and calls `run(.nowait)`; work handed to the home
  thread from elsewhere (a lane call ending, a wake from a worker) makes the
  handle readable.

### Extensions

These take any `Io`. On a runtime's task they are native; on any other `Io`
(`Io.Threaded`, a wrapping layer) they take the best path its slots allow,
counted by `reactor.fallbacks()`.

- **`wait`, `waitAny`**: readiness of descriptors (readable, writable, or a
  `priority` condition such as urgent data or a `cgroup.events` change), a
  `Process` ending, a `Wake`, a Windows object, a held `kernel.Overlapped`
  call ending. On a runtime each member is an
  operation of the task's own loop, so the wait is a cancelation point and
  holds no thread; elsewhere the calling thread waits through that `Io`'s
  concurrent batch (on `Io.Threaded`, one `poll` a cancel interrupts), or in
  5 ms slices between cancel checks for members that are not descriptors and
  an `Io` without concurrent batches. A descriptor that is not open is ready: the call that follows
  reports it. `priority` is `Unsupported` on Darwin and Windows; a process,
  a `Wake` and a Windows object are waited on everywhere, and a loop with no
  room waits on the `wait` lane instead.
- **`Wake`**: a wake-up any thread (or a signal handler) can send;
  `Wake.wait` waits for it alone, ending only at the signal, the timeout or a
  cancel.
- **`Process`**: a child that a wait reports once `waitpid` can reap it,
  without reaping it; `ended` asks without waiting. With no descriptor to
  spare it asks `waitid` between slices. On Linux a runtime's `childWait` waits on the pidfd the same way.
- **`Job`** (Windows): a job object's messages.
- **`kernel.overlapped`** (Windows): one NT overlapped call, waited for; on a
  runtime its port hears of the end, elsewhere an event does. A call the
  timeout or a cancel ends that completed first is handed back completed.
  **`kernel.Overlapped`** holds one call across waits, as a `wait` member
  beside others or signaling a `Wake` that many calls share, so nothing is
  canceled at a timeout.
- **`blocking(io, lane, f, args)`**: a raw call that can take milliseconds,
  run on one of the runtime's lanes (`sync`, `lookup`, `wait`, `general`).
  Use `try`: even a void function returns `Canceled` or
  `ConcurrencyUnavailable` when it could not run. Refused work never runs
  inline.
- **`syncLane`**: the executor a library with its own syscalls takes for its
  raw blocking calls, such as airlock's `Blocking` for its device flushes
  (`.blocking = .{ .run = reactor.syncLane }`): the call on the `sync` lane,
  waiting for a slot as a `std.Io` slot does; `Canceled` only when it never
  started.
- **`Signals`**: signals and console control events, to several listeners.
- **`net`**: `connect` with a timeout, a bounded `resolve`, `abort`,
  per-operation `Deadlines`, a `Receiver` whose idle connections hold no
  buffer, and `message`: a stream socket's sends and receives with their
  control data (POSIX), the kernel's own answers kept as their own errors
  (`BadMessage`, `KeyExpired`, `InputOutput`), which std's error sets fold
  into `Unexpected`. A kernel record layer (Linux kTLS) takes a record's
  type as a control message and answers in those; the control data is the
  caller's to build and read.

## Scope

Linux (io_uring 5.19+, epoll where io_uring is older, missing or refused),
macOS and the BSDs (kqueue), and Windows 8+ (IOCP). On other systems `init` returns
`BackendUnavailable`. A descriptor a readiness backend has waited on must be
closed through the `Io` (or announced with `Loop.closing`).
The extensions also work over any `Io`. HTTP, TLS, durability policy, process
spawning policy and file-watch semantics belong to their libraries.

## Platforms

Native correctness evidence covers Linux, macOS and Windows. BSD targets are
cross-compiled; that does not establish native BSD correctness. Every task
stack has its own guard. On Apple silicon, touched stack storage is rounded
to 16 KiB pages; reserved address space is separate from resident memory.

## Built with

Production code depends on Zig std, aegis and
[shuttle](https://github.com/pedronaugusto/shuttle): a task is a shuttle context
on a stack from shuttle's pool, and a task's switch to its scheduler is
shuttle's handoff. reactor is developed with
[bay](https://github.com/pedronaugusto/bay): repository checks use preflight, and
properties, faults, virtual time and conformance use shakedown, both as dev
dependencies that a project depending on reactor never sees.

## Testing

Use `bay test -Dtest-filter=<name>` for a focused test, `bay lint`
for source and architecture checks, and `bay check` to compile tests,
examples and the own benchmarks. `bay bench` runs manual timings; CI
compiles them without timing. Native lifetime regressions live in
[src/later_test.zig](src/later_test.zig) and
[src/r1_regression_test.zig](src/r1_regression_test.zig).

V11 suite measurements belong to each package's move onto reactor. The
[isolated harness](bench/v11/prepare.zig) preserves the measurements and consumer
seams already investigated here. Stacks stay at 1 MiB until those suite and
guard measurements justify a different default.

## Licence

[MIT](LICENSE).
