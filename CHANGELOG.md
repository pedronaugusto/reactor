# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.2] - 2026-10-24

### Fixed

- `net.connectUnix` on Windows over an `Io` other than a runtime connects through Winsock (`socket` and `connect`, the path as given), as Git for Windows does, where 0.8.1 drove AFD as std 0.17 does and the system refused it: the unnamed bind before the connect failed with `INVALID_PARAMETER` once a listener was at the path, so a connect to a live daemon was `Unexpected`. Nothing listening is `ConnectionRefused` (Winsock's answer for a missing file too), a directory missing on the way `FileNotFound`. The test listens through Winsock on Windows, as Git for Windows' daemons do, writes through std's stream and reads it at the listener.

## [0.8.1] - 2026-10-22

### Added

- `net.connectUnix`: a Unix stream socket connected on any `Io`, its errors std's names everywhere. On Windows over an `Io` other than a runtime it connects by AFD through `operate`, where std 0.17's `Io.Threaded` answers `Unexpected` for a refused connect (no listener at the path) and a missing path: here they are `ConnectionRefused` and `FileNotFound`, as a runtime's IOCP backend has them.

## [0.8.0] - 2026-10-21

### Breaking

- `net.message.receive` takes `Receive` options in place of its timeout: `.timeout`, and `.rekey`, a `Wake` the owner of a kernel record layer signals once new keys are installed. Where Linux's kTLS stops its receive path after a TLS 1.3 KeyUpdate (`KeyExpired`, Linux 6.14 and later), a receive given one waits for it beside the socket and reads on under the next keys; a stopped socket polls as not readable though records wait behind it, so one that polls readable has ended or failed, and the receive answers `KeyExpired` for its owner. Without one, `KeyExpired` is answered at once, as before. Tests seal TLS 1.3 records as a peer would and let the kernel open them (`ktls`, Linux 7.0).

### Added

- A runtime's `netWriteFile` (std's `Writer.sendFile` on a stream): the kernel's `sendfile` on Linux and Darwin, where std 0.17's `Io.Threaded` answers `Unimplemented` and the writer copied through memory. Each send waits for the socket to be writable through the task's loop and asks for at most a quarter of its send buffer, so a call is seldom cut short; a socket in blocking mode (a runtime's, on Linux) is sent to in a blocking bracket or on a lane. What the writer and the reader hold goes first as a write. Darwin sends from a positional reader only; a reader or a file the kernel cannot send from answers `Unimplemented`, and the writer copies. Under Linux's kernel record layer (kTLS) the kernel seals what it sends (cloak's C9): a test sends a file through a socket whose write direction is the kernel's and opens the records it sent (`ktls`, Linux 7.0).

### Changed

- Development: the lint gates glint's A005 as well (the aegis pack's five rules at gate).
- Development: the differential properties in `later_test` run their oracle on `Case.io()`, an `Io` of each fuzzer input's own (shakedown 0.4.13 for development).

## [0.7.1] - 2026-10-20

### Added

- `net.message.send` and `net.message.receive`: a stream socket's data with its control data, on any `Io` (POSIX), each a call that never waits in the kernel and a wait for the socket's readiness through `wait` between them. The kernel's answers keep their names (`BadMessage` for `EBADMSG`, `KeyExpired` for `EKEYEXPIRED`, `InputOutput` for `EIO`, `MessageTooBig`), where std's stream read and write fold them into `Unexpected`: Linux's kernel record layer (kTLS) says with them that a record failed to open, that its receive path waits for new keys, and that the next record is not data and the read gave no control room to name its type. For cloak's kernel record layer (its C9).

### Changed

- Development: the tests read the calling thread through one helper that is never inlined (`src/testing/thread.zig`). std keeps the id in a thread-local on Linux, and an optimized test that read it before and after an `Io` call that moved its task could get the thread it left on aarch64: a check that the root came back home would pass whatever happened.

## [0.7.0] - 2026-10-18

### Breaking

- `Loop.Op` holds its `kind`, `result`, `state` and linked deadline in `backend`, the operation's backend half (`backend/op.zig`'s `Op`), which is all a backend sees of it; `callback` and `user_data` stay beside it. An operation is `.{ .backend = .{ .kind = ... }, .callback = ... }` and its result `o.backend.result`. The backends take that half by its type where they took any operation (`anytype`), so what they read of an operation is checked against one declaration; what each backend keeps in an operation is a type of its own below that declaration (io_uring's and IOCP's request memory, the readiness backends' `Waiter`), and the casts that recovered an operation's type from a sink are gone.

## [0.6.1] - 2026-10-17

### Changed

- On Darwin a pipe or a socket in blocking mode is written up to the room kqueue counts for it (`EVFILT_WRITE`'s `data`), in one call, where each readiness moved at most 512 bytes (`PIPE_BUF`); a write that knows no room yet asks kqueue at once, and one that finds the room taken waits for the reader. parley's stdio `tools/list` of 100 tools went from 1.96 to 0.61 ms (M3). A terminal is still written 512 bytes at a time: its count is no room a write keeps within.
- A wake that a poll outside `run` took (making room in kqueue's changelist, or asking a write's room) makes the next poll return at once, where the wait could go on.

## [0.6.0] - 2026-10-17

### Breaking

- `kernel.overlapped`'s `start` takes a `kernel.Completion` (the `Event` and the APC context to pass the NT call) where it took the APC context alone, so the call can signal an event off a runtime.

### Added

- `kernel.overlapped` works on any `Io`: off a runtime the call signals an event of its own, waited on the calling thread, and a call that the timeout or a cancel ends but that completed first is handed back completed, with what it read.
- `kernel.Overlapped`: one NT overlapped call held across waits, on any `Io`: with an event of its own, a `wait` member (`.overlapped`) beside descriptors, objects and a `Wake`; or `signaling` a `Wake`'s event, so that any number of calls are one member, the `Wake`, and `ended` says which ended. Nothing is canceled at a wait's timeout; `cancel` asks the call to end, and `take` hands back what it ended with, the bytes of one that completed first included.
- `wait_max`, the most members one `waitAny` takes.
- `Wake.wait`: a wait on one `Wake`, which ends at its signal, the timeout or a cancel and has nothing to be unsupported.

### Changed

- A wait reports a `Process` once `waitpid` can reap it: on Darwin and the BSDs a kqueue posts `NOTE_EXIT` a moment before that, and the wait goes on for the `SIGCHLD` that follows (`ended` says the same).
- `Process.open` on a child with no descriptor to spare (`EMFILE`, `ENFILE`, `ENOMEM`) makes a watch that asks `waitid` between slices, as on a system with no descriptor for it; `SystemResources` is now only for a process that is not a child.
- A wait whose loop has no room for it waits on the `wait` lane, and a `poll` with no memory for one slice counts as a slice with nothing ready, where both answered `Unexpected`.

## [0.5.0] - 2026-10-17

### Breaking

- `Runtime` status's lane `threads` counts the threads the lane's executor has made; it repeated `running`, as a `u16`, and is a `u32`.

### Changed

- Startup is lazy: `start` no longer warms the lane workers (`2 × cap + 3` threads a lane, about 120 on a Mac at the defaults), and the task stacks are no longer each guarded at `init` (shuttle 0.3's pool). A lane grows before a call starts on it to two threads for each call it runs and three more, up to its cap, and keeps them, those not yet needed held apart from its executor's ready pool so sequential calls still reuse one warm thread; a stack is made usable when a task first takes it, and kept. A program on the default options: `init` 0.7 ms where it was 7, `start` 0.04 ms where it was 1.8, `stop` and `deinit` 0.1 ms where they were 5, 11 MiB resident where it was 16 (Apple M3 Max); `init` 0.8 ms where it was 18, `start` 0.5 where it was 11, `stop` and `deinit` 0.4 where they were 12, 6.4 MiB where it was 36 (aarch64 Linux VM). parley's stdio server starts in 3.6 ms where it took 17, and rests at 10.5 MiB where it took 16 (Mac). A cancel and a control call still never wait on a thread being made.
- A stack the system refuses to make usable mid-run (strict overcommit, the map count, the Windows commit limit) refuses the spawn with `ConcurrencyUnavailable` and is tried again by a later one; `async` runs the function inline, as std's does. A lane that cannot make a thread queues the call behind the calls it runs, or, running none, refuses it: a raw call returns `ConcurrencyUnavailable`, and a fixed signature waits and tries again, as it waits for admission.
- Pins shuttle 0.3.0, and preflight 0.8.2 and shakedown 0.4.11 for development.

## [0.4.7] - 2026-10-17

### Changed

- The futex wait hands its bucket guard's release to the scheduler through aegis's `Guard.handOff()`, a transfer declared where it happens, and A003 (an owner's cleanup) gates in reactor's lint: glint 0.2.13 follows the lanes' launch guard and the spare threads' wait through their loops, where 0.2.12 left them undecided.
- Pins aegis 0.1.12.

## [0.4.6] - 2026-10-17

### Fixed

- A batch await that ends in an error (`Canceled`, `ConcurrencyUnavailable`) takes every operation the kernel still holds back to `submitted` before it returns, as a timeout already did. std's `operateTimeout` drops its batch with its frame on any error, so a canceled timed read stayed in the kernel and its completion later wrote into storage that was gone (`access of union field 'pending' while field 'unused' is active` in `ops/batch.zig`, on every canceled HTTP/2 request of uplink's client on macOS).

## [0.4.5] - 2026-10-15

### Changed

- `kernel.overlapped` keeps no copy of `context`: the NT call's start reads the parameter itself, through its address, for as long as the call runs.
- The aegis rules A001 (access without a live capability) and A002 (a duplicated owner) gate in reactor's lint, on preflight 0.6.2's glint, which decides the receivers inside reactor's generics. A003 stays reported: the futex wait hands its bucket guard to the park, which releases it once the task is parked, a transfer through an erased context that glint does not follow.

## [0.4.4] - 2026-10-14

### Fixed

- A task that moved to another thread at a switch kept the seat of the thread it left in optimized builds on aarch64: LLVM put the thread-local's address, computed in the caller, where `seatNow`'s result was used and merged it across the switch, so lane calls crashed in the switch and a task queued behind the root was never offered to an idle processor. The address passes through an assembly statement the compiler cannot see through. x86_64 reads it through %fs, a load the switch's memory clobber orders, and was not affected.

### Changed

- A task's code must not keep a thread-local's address across an `Io` call, which may move it to another thread (README): std's `Thread.getCurrentId` read before and after such a call is one such address, and the offer test now reads it through a call of its own.

## [0.4.3] - 2026-10-14

### Fixed

- On Windows a task's file call (an open, a stat, a rename, anything but reading or writing an open file) runs on the `general` lane's thread, where it ran std's code on the task's stack: std makes each path an NT path in buffers of 32 Ki UTF-16 units, and its frames outgrow a task's 1 MiB stack (an open by path takes 1.3 MiB in a Debug build, a rename 512 KiB in ReleaseSafe). uplink's file server overflowed its handler's stack on Windows.

## [0.4.2] - 2026-10-14

### Changed

- Pins aegis 0.1.6, shuttle 0.2.1.

## [0.4.1] - 2026-10-14

### Changed

- A group counts its members with one atomic add each way instead of linking each into a list under the group's lock, so a spawning task and members finishing on other processors no longer contend: a 10,000-member group with workers costs 18% less per task on macOS (536 → 440 ns, interleaved medians on a loaded M3 Max; 0.2.3 451) and 14% less on Linux io_uring (620 → 534 ns; epoll 646 → 501), level with no workers. A member is listed for the group's cancel only once it enters a cancelable wait; one that has not takes the cancel at its next cancelation point.

## [0.4.0] - 2026-10-13

### Breaking

- `blockingHook` and `BlockingHook` are gone; `syncLane(io, context, function, argument)` takes their place with the contract of airlock's `Blocking.run`, so `.blocking = .{ .run = reactor.syncLane }` runs airlock's device flushes on the `sync` lane. Its signature is fixed, so it waits for a lane slot as a `std.Io` slot does and never refuses; it returns `Canceled` only when the call never started, and a call that started finishes and succeeds.

### Changed

- A stall's log line and `Runtime.dump`'s stack depths are written in aegis's text forms (`held processor 0 for 13ms164us`, `parked_stack=48KiB`), which `parse` reads back. Pins aegis 0.1.5.
- airlock is a development dependency: a test runs its file and directory syncs through `syncLane` from a task and from the root, each on the `sync` lane.

### Fixed

- A task of one runtime that called another runtime's lanes (a std file call through the other's `Io`, `blocking`, `wait` in slices) was woken on the other runtime's scheduler: it went on there, a processor of a runtime it does not belong to. It is woken by its own.

## [0.3.1] - 2026-10-13

### Added

- A task that runs its own code past `handoff_after` (a computing loop) loses its processor to a spare thread, as a blocking call does, when tasks wait there or its loop has operations in flight, so they go on; the task rejoins a processor at its next call into the runtime, and the root takes the home processor back. Under `stealing` and `per_core` alike, on epoll, kqueue and IOCP with workers. No signals: the task itself is never interrupted. `Stats.handoffs` counts both kinds.

### Changed

- Every `std.Io` slot and extension call takes the calling thread's processor back from lending on the way in and lends it on the way out, where the monitor hands processors on: about 4 ns a call on an M3 under kqueue (a wake between two tasks 32 → 40 ns, a `concurrent` and `await` of an empty task 72 → 85 ns), 3 to 6 ns on Linux under epoll. In a process where no runtime lends (io_uring, no workers, no monitor) a call pays one load of a process-wide count and its bracket: on Linux under io_uring a wake 35 → 36 ns, a `concurrent` and `await` 64 → 70 ns.
- Handoff applies under `per_core` too: a task whose processor went to a spare comes back to that processor. A processor is handed on only when it has work only its owner can do.
- Runs on shuttle 0.2, whose context is what a switch saves and no more: a task's record keeps its stack's number and no copy of the stack, 192 bytes where it was 256 on aarch64 (shuttle's context 40 bytes, from 112). Pins shuttle 0.2.0 and, for development, shakedown 0.4.1.
- `spares` defaults to one per processor, so every processor can go to a spare while the thread that lent it still runs its task (was workers / 2).
- The release tier runs the hardened profile: the suite with safety on, a bounded fuzz campaign over the scheduler's properties, and the suite under ThreadSanitizer, through a new `unit` step that runs the suite alone.

### Fixed

- A lane call that ended looked at the queued call it had just started on the lane's executor, to see whether the executor refused it; started, that call could have ended and its frame been reused, and a stale "refused" passed its slot on twice, so the lane's count of running calls wrapped (an integer overflow under the hardened profile's ThreadSanitizer run). The lane now hands back only a call the executor refused, which nothing else touches.
- A group's last member touched the group after leaving its `token` null, which std's `Group.await` and `cancel` read without the runtime as a group that holds nothing: an owner that saw it null and reused the group at once (a `var group: Io.Group = .init` in a loop) or freed it raced the member's unlock. ThreadSanitizer found it; 0.2.3 had it too. The last member now marks the token ended, its last touch of the group, and only the runtime's await or cancel leaves it null; the group's lock lives in the token beside the first member.
- A group whose token reads null has every member's stack back. Through std's shortcut for an empty group, an await could return while a member was still giving its stack back, so a program that took the stacks again at once could be refused with `ConcurrencyUnavailable`; the token now goes null only after the runtime's await has waited for the stacks.

## [0.3.0] - 2026-10-13

### Breaking

- reactor depends on [shuttle](https://github.com/pedronaugusto/shuttle) at run time: a task is a shuttle context on a stack from shuttle's pool, and switches to its scheduler through shuttle's handoff. A project that depends on reactor fetches shuttle with it.

### Changed

- A task's switch is inline, where it was a call: a call and its return, to and from different contexts, cost the return predictor a miss each way. On an M3, a wake between two tasks takes 34 ns where it took 69, and a `concurrent` and `await` of an empty task 72 ns where it took 102 (Linux on the same machine: 36 and 66 ns, from 71 and 93). A group of 10,000 members costs more each, 211 ns where it took 177 (293 from 230 on Linux): more of each task's record and stack is touched where 10,000 are live.
- The stacks are shuttle's pool, each with its own guard below it; the context switch, the first frame, the Windows stack bounds and the ThreadSanitizer annotations are shuttle's. The default class stays kept for the tasks that ask no size (`Pool.takeExactly`), and a stack's number for the records and trims is `Pool.number`.
- Pins preflight 0.4.3 and aegis 0.1.3.

### Fixed

- The test that a scheduler property's failure shrinks and replays runs its property on seeded cases alone (`.fuzz = false`): built for the fuzzer, it ran the fuzzer's inputs instead and failed.

## [0.2.3] - 2026-10-12

### Changed

- The tests take shakedown as bay gives it, with no `.aegis = .consumer` or `useAegis` binding: bay gives a graph one aegis, so shakedown's is this package's.

## [0.2.2] - 2026-10-12

### Changed

- Pins aegis 0.1.1, preflight 0.3.4 and shakedown 0.2.6.

## [0.2.1] - 2026-10-12

### Fixed

- A context switch on x86_64 keeps what the code that switched holds in vector registers. The switch declared them clobbered only by their AVX-512 names, `zmm`, which the compiler does not take on a CPU without AVX-512, so it left `xmm6` to `xmm15`, which Windows has a callee keep, to whichever context ran next: values a task held in them across a switch came back overwritten, a slice's pointer among them, in optimized builds on Windows. The switch declares them as `xmm` and `ymm` too.

## [0.2.0] - 2026-10-12

### Breaking

- reactor is developed with [bay](https://github.com/pedronaugusto/bay): preflight and shakedown are dev dependencies, and the tests, example and benchmarks are the development build's (`bay test`, `bay bench`). What a project that depends on reactor builds is unchanged: the `reactor` module and its library.
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
- `Wake.handle` and `Wake.clear`: the kernel object a signal sets, and the way to clear it, for a program with a wait loop of its own. lookout hands the same descriptor to its own callers.
- `Signals.wake`: the wake a listener's deliveries set, to wait on beside other members of a `waitAny` set. When it reports, `next` with a zero timeout takes what was delivered. A program that waits on its input and on its resize signal together no longer needs a handler and a pipe of its own.

### Changed

- On Darwin a runtime started without `workers` starts a quarter of the logical CPUs (at least one) instead of all but one. Loopback traffic between tasks cost the kernel more per message the more threads were in it: 64-byte round trips on 32 connections reached 225k a second on 4 workers of 16 CPUs and 155k on 15, which is what `Io.Threaded` does on its own threads (149k); uplink's 16 tasks through one client 198k on 4 workers, 133k on 15 and 186k on `Io.Threaded`. A task set that is all arithmetic still scales to every CPU (4096 tasks of 50 us: 72k a second on 4 workers, 165k on 15): such a host sets `workers`. Elsewhere the default is as before.
- On io_uring a socket write of one piece tried at once is a `send` rather than a `sendmsg`: 32-connection round trips +6%, one connection +2% (lima VM).
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
- Pins aegis 0.1.0.

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
- On IOCP a worker's operation on a socket the root used first no longer waits for the root to come back to the runtime. A handle's completions arrive on one port for its life, and the home loop's port is served only while the root waits in the runtime: a thread reading a socket the root had accepted, while the root joined that thread, waited forever. With workers, the home loop binds its handles, and attaches jobs, to the first worker's port, which passes the root's own entries on.
- On Windows a UDP connect through a runtime succeeds. It set ephemeral port reuse on every socket, as std does, and AFD refuses that option on a datagram endpoint, so every UDP connect failed with `Unexpected`; it is set on stream sockets only.

[Unreleased]: https://github.com/pedronaugusto/reactor/commits/main
