# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Init-reserved per-task stack classes and `concurrentWith` options for stack size and latency priority. CPU and lane queues give normal work a turn after eight latency jobs.
- Optional sparse registered buffer pools for fixed file reads/writes; io_uring SEND_ZC for contiguous sends and explicit SQPOLL configuration.
- Native Linux OPENAT, STATX, WAITID and linked deadlines, ring-message wakes, and BSD process-watch waits.
- Shrinkable test-driver choices, submission fault injection, native lifetime regressions and portable guard-page death tests.

### Changed

- Opt-in overall touched-stack profiling and retained parked high-water statistics; diagnostic painting is disabled when timing.
- Lane executor rejection no longer runs blocking work on the submitting scheduler worker. Disabled lanes reject rather than queue forever.
- Deep ended or shallow parked stacks discard unused pages on systems that support it.
- SQ/CQ pressure releases kernel ownership while keeping user callbacks and batch list mutations queued for `run`; SQPOLL file close waits for published file references before unregistering.


- Buffer-pool registration follows the ring owner as soon as runtime startup begins, avoiding a race with worker adoption.
- Native receiver completions count as loop progress, so a waiting processor runs the task they woke before sleeping again.

- `Loop.reap` releases an operation for reuse; wheel timers and kernel requests share their internal storage, reducing operation size and timer cancellation cost.

- Processors publish idleness before checking remote work, so lane completions cannot miss their wake; global completions also wake an embedded host and make `Runtime.nextTimeout` return zero.

- Accept-ahead requests keep at most eight accepted or pending sockets per listener; burst connections stay in the kernel backlog. `Loop.UringFeatures.accept_ahead` controls this optimization.
- DNS and Receiver keep their deadlines over `Io` implementations without concurrent network batches; canceled fallback operations drain before returning their borrowed buffers.

### Added

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

[Unreleased]: https://github.com/pedronaugusto/reactor/commits/main
