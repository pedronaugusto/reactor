# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- `Runtime.start` creates the scheduler workers and prepares the owned offload lanes; fixed-signature `std.Io` operations require a successful start, checked in safe builds. A failed start must be deinitialized.
- An injected offload executor declares exclusive capacity with its `Io`: `.{ .injected = .{ .io = host_io, .capacity = n } }`. Admission reserves execution and cancellation together and keeps the reservation until both have retired.
- `blocking` adds `Canceled` and `ConcurrencyUnavailable` to every function result, void included, and `blockingHook.call` returns that error union. A refused call never runs inline.

### Added

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

- Raw offloads and blocking hooks called from outside reactor tasks honor lane refusal and run accepted work on the lane; foreign-runtime callers resume on their own scheduler.
- Failed IP and Unix connects invalidate cached readiness before closing an unpublished socket.
- Readiness backends retain terminal read events through final bytes and EOF instead of parking after a short final read.
- Child wait and kill close their POSIX pipes through the runtime, invalidating cached readiness registrations before descriptor reuse.
- A group's `await` returns only after every member has given its stack back, without members holding the group's lock for the release.
- Foreign spawning and wakes retain the destination scheduler; ring messages never cross runtimes.
- A ring-message wake is submitted at once, so a task that spawns in a loop or computes cannot leave a sleeping worker asleep with work queued for it.

### Changed

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
