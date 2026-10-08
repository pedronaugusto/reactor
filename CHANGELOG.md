# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
