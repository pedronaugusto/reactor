# reactor

The combined LATER and R6 work on branch `later` is work in progress.
Performance targets, full family-suite stack measurements and the injected
executor contract remain open. This branch has not landed on main.

reactor is an evented `std.Io` for Zig: every slot of the interface on the
kernel's own completion queue, with stackful tasks on a work-stealing
scheduler, and the loop under it usable alone. A program swaps `Io.Threaded`
for `reactor.Runtime` and changes nothing else. A host that owns its loop (a
frame loop, a job system) drives it without giving up a thread.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/reactor`, then obtain the `reactor` module
through `b.dependency` and add it to your executable's imports. reactor depends
on nothing but std.

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

`Loop` owns one completion engine and its timers. `Runtime` owns the scheduler,
stacks and offload lanes. Extensions take a plain `std.Io`, leaving protocol
and application policy with the caller. The checked production layers and
state owners are documented in [the design](docs/design.md).

### Task and kernel options

Reserve stack classes in `Runtime.Options.stack_classes`, whose counts come
out of `max_tasks`. `concurrentWith(io, options, f, args)` chooses a reserved
`stack_size` and a `priority` (`normal` or `latency`). Latency work receives
up to eight turns before queued normal work, on CPU and blocking lanes.

`net.Receiver.Pool.Options.registered` registers the pool on each native
ring for fixed file reads and writes. Keep the pool alive until its operations
finish; `deinit` unregisters it on the ring owners before freeing memory.
`zero_copy_min` explicitly enables SEND_ZC above a contiguous-send size.
The default disables it: the hosted loopback measurements found it slower
at every tested size. `sqpoll` explicitly requests a kernel polling thread;
an unsupported request returns an error. Both options are Linux-specific.

`measure_stacks` enables diagnostic painting for overall touched depth.
`stats().parked_high_water` is retained across task release;
`stack_high_water` is available with painting enabled. Profiling commits and
scans stack memory, so leave it off when timing production workloads.
The required family-suite V11 measurements are still pending.

Detailed implementation and evidence: [LATER evidence](bench/later-evidence.md).

## API

### Runtime and loop

- **Every `std.Io` slot.** Sockets, files, timers, futexes, batches and
  cancellation run on io_uring, epoll, kqueue or IOCP over AFD; calls that can block
  for milliseconds (directory walks, `flock`, process waits) run off the
  workers on owned `Io.Threaded` lanes, so std's own code and std's own
  cancellation serve them; calls that never block run std's code on the
  worker.
- **epoll and kqueue** make a socket's call at once and wait for readiness
  only when it would block, with each descriptor registered once for its
  life. File calls run on the worker; should one block, a monitor thread
  hands the worker's processor to a spare thread, so the tasks queued there
  go on. A listening socket reactor accepts on is put in non-blocking mode.
- **std's cancellation exactly.** A cancel lands at the next cancelation point;
  an operation the kernel finished first keeps its result. `operateTimeout` and
  `Batch.awaitConcurrent` never return while the kernel still holds a buffer.
- **Work stealing**, or `per_core` shared nothing; the root never leaves the
  thread that built the runtime.
- **No allocation after `init`.** Stacks are reserved in slabs at `init`; lane
  closures come from a pool reserved there.
- **`Loop`**: one thread's completion engine with no threads of its own, driven
  by `run(.nowait)`, `run(.once)` or `run(.until)`, completions by callback or
  `reap`; on Windows it can share the host’s completion port.
- **Embedding.** A host that owns its loop waits on `Runtime.backendHandle`
  for at most `nextTimeout` and calls `run(.nowait)`; work handed to the home
  thread from elsewhere (a lane call ending, a wake from a worker) makes the
  handle readable.

### Extensions

These take any `Io`. On a runtime's task they are native; on any other `Io`
(`Io.Threaded`, a wrapping layer) they take the best path its slots allow,
counted by `reactor.fallbacks()`.

- **`wait`, `waitAny`**: readiness of descriptors, a `Process` ending, a
  `Wake`, a Windows object. On a runtime each member is an operation of the
  task's own loop, so the wait is a cancelation point and holds no thread;
  elsewhere the calling thread waits in 5 ms slices between cancel checks.
- **`Wake`**: a wake-up any thread (or a signal handler) can send.
- **`Process`**: a child that a wait reports once it has ended, without
  reaping it. On Linux a runtime's `childWait` waits on the pidfd the same way.
- **`Job`** (Windows): a job object's messages.
- **`blocking(io, lane, f, args)`**: a raw call that can take milliseconds,
  run on one of the runtime's lanes (`sync`, `lookup`, `wait`, `general`).
  Use `try`: even a void function returns `Canceled` or
  `ConcurrencyUnavailable` when it could not run. `blockingHook` has the same
  fallible contract. Refused work never runs inline.
- **`Signals`**: signals and console control events, to several listeners.
- **`net`**: `connect` with a timeout, a bounded `resolve`, `abort`,
  per-operation `Deadlines`, and a `Receiver` whose idle connections hold no
  buffer.

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

Production code depends only on Zig std. Repository checks use preflight;
properties, faults, virtual time and conformance use shakedown as a lazy
test-only dependency.

## Testing

Use `zig build test -Dtest-filter=<name>` for a focused test, `zig build lint`
for source and architecture checks, and `zig build check` to compile tests,
examples and the own benchmarks. `zig build bench` runs manual timings; CI
compiles them without timing. The [LATER evidence](bench/later-evidence.md)
retains native ownership and failing-before regression receipts.

V11 suite measurements belong to each package's move onto reactor. The
[isolated harness](bench/v11/README.md) preserves the measurements and consumer
seams already investigated here. Stacks stay at 1 MiB until those suite and
guard measurements justify a different default.

## Licence

[MIT](LICENSE).
