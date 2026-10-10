# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- Byte counts in the options are aegis `units.Bytes`: `Runtime.Options.stack_size`, `zero_copy_min` (here and in `Loop.Options`), each `stack_classes` entry's `size`, `TaskOptions.stack_size`, an owned lane's `scratch_bytes` and `net.Receiver.Pool.Options.buffer_len`. Write `.stack_size = .fromRaw(256 << 10)`.
- reactor depends on aegis, which depends on std alone. A project that builds the `reactor` module fetches it too.
- `Runtime.start` creates the scheduler workers and prepares the owned offload lanes; fixed-signature `std.Io` operations require a successful start, checked in safe builds. A failed start must be deinitialized.
- An injected offload executor declares exclusive capacity with its `Io`: `.{ .injected = .{ .io = host_io, .capacity = n } }`. Admission reserves execution and cancellation together and keeps the reservation until both have retired.
- `blocking` adds `Canceled` and `ConcurrencyUnavailable` to every function result, void included, and `blockingHook.call` returns that error union. A refused call never runs inline.

### Added

- `Waitable.priority`: a descriptor's `POLLPRI` condition, such as urgent data on a stream socket or a change to a `cgroup.events` file. A task waits for it on the loop under io_uring and epoll, and on the `wait` lane under kqueue; Darwin's `poll` cannot report it and Windows has no such event, so a wait there is `Unsupported`.
- `Process.ended`: whether the process has ended, asked without waiting or reaping.
- `net.Deadlines.tighten`: deadlines shorter than the shortest `init` was told of shorten the watching task's tick at once, even while it waits out a longer one. `net.literal` and `net.max_addresses`: a host that is an address, and the most addresses `net.resolve` keeps.
- `concurrentWith(io, .{ .stack_size, .priority }, f, args)` over init-reserved stack classes (`Options.stack_classes`) and a `latency` priority; latency work gets up to eight turns before queued normal work, on the scheduler and on the lanes.
- Sparse registered buffer pools for fixed file reads and writes, io_uring SEND_ZC above `zero_copy_min`, and an explicit `sqpoll`; all off by default.
- Native Linux OPENAT, STATX and WAITID, a kernel-linked deadline for `connect`, ring-message wakes between a runtime's processors, and BSD process-watch waits.
- `stats().parked_high_water`, the deepest park of any task live or ended, and `measure_stacks` with `stats().stack_high_water`.
- Shrinkable test-driver choices, submission fault injection, native lifetime regressions and portable guard-page death tests.
- `Runtime`: a complete `std.Io` on io_uring, with stackful tasks, work stealing or `per_core`, a home thread the root never leaves, a zero-thread profile driven by `run`, and four lanes (`sync`, `lookup`, `wait`, `general`) of owned `Io.Threaded` for calls that can block.
- `Loop`: one thread's completion engine with a timing wheel, completions by callback or `reap`, and `run(.nowait/.once/.within/.until)`.
- epoll and kqueue backends: calls made at once and on readiness, descriptors registered once, `real` and `boot` timers on kernel timers; `.auto` falls back to epoll where io_uring is unavailable. `Loop.start` takes an operation's result at once when it needs no wait; `Loop.closing` announces a close made elsewhere.
- The monitor (`Options.monitor`, `spares`, `handoff_after`, `report_after`): a worker stuck in a blocking file call hands its processor to a spare thread; stalls are counted in `stats`.
- IOCP backend (Windows): socket calls as AFD's own requests through a completion port, the port skipped for calls that complete at once; pipes and device control overlapped; child waits and `real` timers through wait completion packets; sleeps on a high-resolution waitable timer; `Loop.Options.port` and `Loop.complete` to share a host's port.
- Tasks on Windows: a switch that keeps the thread information block's stack bounds, and stacks that grow by guard page.
- `wait`, `waitAny`, `Wake`, `Process`, `Job`, `blocking`, `Signals` and `net` (`connect`, `resolve`, `abort`, `Deadlines`, `Receiver`) over any `Io`, native on a runtime, and `fallbacks()`.
- Bounded detached libc lookups, an evented DNS stub with EDNS0, truncation retries, CNAME resolution and destination ordering, and overlapped Windows lookups.
- Local address and interface selection in `net.connect`.
- Bounded io_uring accept-ahead queues, sparse registered regular files, and pooled multishot receives where supported.
- Native request escapes through `kernel.submit` and `kernel.overlapped`, and `blockingHook` for raw library flush calls.
- Atomic task summaries in `dump`, a worker crash summary, and ThreadSanitizer fiber annotations.
- Bounded Windows Job notification storage on runtime completion ports; detach removes the association.
- On Linux a runtime's `childWait` waits on the child's pidfd in the task's own loop.

### Fixed

- On io_uring a stream read fills every buffer it is given, as on the other backends and `Io.Threaded`: a socket read with more than one buffer is a `recvmsg` and a file read a `readv`. It used to read the first buffer alone, so a stream reader asked for a slice smaller than its own buffer read a slice at a time (64 MiB through 4 KiB slices: 16.4 ms, now 5.2 ms; `Io.Threaded` 4.6 ms, in the lima VM).
- On Darwin a stream write larger than the room in the send buffer no longer holds the loop's thread until the peer has read. Darwin's `send` ignores `MSG_DONTWAIT` on a socket in blocking mode (its receives honor it), so a task writing 64 MiB blocked its thread, and with the reader on that thread's own queue (`workers = 0`, or a reader left in the LIFO slot) the program never finished. A readiness backend there puts a socket in non-blocking mode before its first write, and a socket reactor connects stays in it, as an accepted one already was.
- A wait on a descriptor that is not open is ready, as `poll` says for a closed one, on every backend and under `Io.Threaded`; a number below zero used to panic the kqueue backend, fail the epoll backend with `Unexpected`, complete io_uring's with `Unexpected` and never end a thread's wait. The operation that follows reports the error. The kqueue and epoll pollers answer `Unpollable` to a number no descriptor has.
- On Darwin a `Process` opened for a child that is ending, which `kqueue` refuses for up to a few milliseconds while `waitid` still says it runs, watches `SIGCHLD` on a kqueue and asks again at each, instead of asking every 5 ms.
- A cancel sent from another thread to a task parked on a different processor no longer names a task that has ended: the request now lives in the wait's own record, and the task does not leave the wait until the processor has served it. Before, a task whose operation completed as its cancel was queued could be released first, and the processor read the released record (a crash in safe builds, a lost or misdirected cancel otherwise).
- A deadline past the end of the awake timeline (584 years) armed on the loop no longer panics in safe builds or wraps in fast ones; it saturates, and the wait never ends. A `Loop.nextTimeout` or kernel wait to it is long, not negative.
- A task count within 63 of 2^32 no longer wraps the slab count, a stack size past the address space or a stride that does not fit is refused with `SystemResources` instead of overflowing, and a worker count of 65,535 no longer wraps the processor count; `Runtime.init` returns `SystemResources`.
- Raw offloads and blocking hooks called from outside reactor tasks honor lane refusal and run accepted work on the lane; foreign-runtime callers resume on their own scheduler.
- Failed IP and Unix connects invalidate cached readiness before closing an unpublished socket.
- Readiness backends retain terminal read events through final bytes and EOF instead of parking after a short final read.
- Child wait and kill close their POSIX pipes through the runtime, invalidating cached readiness registrations before descriptor reuse.
- A group's `await` returns only after every member has given its stack back, without members holding the group's lock for the release.
- Foreign spawning and wakes retain the destination scheduler; ring messages never cross runtimes.
- A ring-message wake is submitted at once, so a task that spawns in a loop or computes cannot leave a sleeping worker asleep with work queued for it.

### Changed

- On Darwin a look at descriptors that waits for nothing (the first and last look of a `wait` off a runtime, a blocking pipe's readiness on kqueue) asks `select` instead of `poll`, which waits off the CPU for ~6 us when nothing is ready even with no timeout (`select` answers in ~0.2 us). A `poll` remains for priority interests, descriptors past 1023 and one that is not open. lookout's wake on a runtime (kqueue) went from 37 us to ~20; the kernel's own floor for that wake is ~11 us.
- On kqueue a `wait` registers its descriptor anew instead of asking `poll(2)` whether it is ready first: re-registering has the kernel report a ready descriptor at the next wait, at no call of its own, where Darwin's `poll` waits off the CPU for ~8 us even with no timeout. Two tasks handing a turn through pipes or `Wake`s went from 17 us a round to 1.7 on macOS; pooled receives (`net.Receiver`) from 57k to 119k round trips a second.
- `wait` and `waitAny` on an `Io` that is not a runtime (`Io.Threaded`) wait through that `Io`'s concurrent batch, one `poll` it can interrupt for a cancel, instead of in 5 ms slices: a wait blocked for 2 s woke ~340 times and now wakes once. Slices remain for members that are not descriptors (priority events, a process with no watch descriptor, Windows objects) and for an `Io` without concurrent batches.
- A processor whose queue holds one task no longer keeps it from an idle processor when tasks that cannot leave (the root, a task holding a deadline) also wait there. A root writing to a task that read ran with it on one thread, turn about: 1 GiB over loopback in 64 KiB writes went from 7.6 to 9.0 GiB/s on io_uring (lima VM, three workers; `Io.Threaded` 10.9) and from 6.6 to 7.5 on kqueue.
- On io_uring a socket write is tried as a call first, as the readiness backends do, and goes to the ring only when the send buffer is full (not under SQPOLL, nor where a zero-copy send applies). 64 MiB between two tasks over loopback: 6.0 ms, now 5.0 ms (`Io.Threaded` 4.8 ms).
- A processor between tasks with one task to run next no longer wakes an idle one for it: the processor woken could only take that task away. On io_uring one connection's 64-byte round trips went from 184k to 262k a second, reads under deadlines from 193k to 250k, pooled receives from 172k to 247k (lima VM, seven workers).
- Time, identity and lock state use aegis types: the loop's timeline is `clock.Awake`, `Tick` and `Span`; a stack's number and its place in a size class are distinct; every lock sits beside the data it guards (`BlockingGuarded`, and `Guarded` for futex buckets); lane admission holds its executor capacity as a `Budget` reservation. A timer armed on the awake clock reads the clock once less.
- A task in the LIFO slot no longer wakes an idle processor: it cannot be stolen. Only a task displaced into the queue does.
- Only `connect` links a kernel timeout on io_uring; other deadlines arm the wheel and cancel, which costs nothing when the operation finishes first.
- Everything several threads write (queues' heads, tails and slots, a processor's inboxes and flags, the scheduler's counters) sits on cache lines of its own.
- Lane executor rejection no longer runs blocking work on the submitting scheduler worker; disabled lanes refuse rather than queue forever.
- A task that parked deep and is parked shallower keeps its pages until it has been parked for a full second, then its loop gives them back; one init-reserved timer per loop serves the candidates.
- SQ/CQ pressure releases kernel ownership while keeping user callbacks and batch list mutations queued for `run`; SQPOLL file close waits for published file references before unregistering.
- Native engines keep stable owned storage allocated at loop initialization.
- Linux interface binding uses the interface index directly.
- Buffer-pool registration follows the ring owner as soon as runtime startup begins, avoiding a race with worker adoption.
- Native receiver completions count as loop progress, so a waiting processor runs the task they woke before sleeping again.
- `Loop.reap` releases an operation for reuse; wheel timers and kernel requests share their internal storage, reducing operation size and timer cancellation cost.
- Processors publish idleness before checking remote work, so lane completions cannot miss their wake; global completions also wake an embedded host and make `Runtime.nextTimeout` return zero.
- Accept-ahead requests keep at most eight accepted or pending sockets per listener; burst connections stay in the kernel backlog. `Loop.UringFeatures.accept_ahead` controls this optimization.
- DNS and Receiver keep their deadlines over `Io` implementations without concurrent network batches; canceled fallback operations drain before returning their borrowed buffers.

[Unreleased]: https://github.com/pedronaugusto/reactor/commits/main
