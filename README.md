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

## What it does

- **Every `std.Io` slot.** Sockets, files, timers, futexes, batches and
  cancellation run on io_uring (Linux) or IOCP over AFD (Windows); calls that can block for milliseconds (directory
  walks, `flock`, process waits) run off the workers on owned `Io.Threaded`
  lanes, so std's own code and std's own cancellation serve them; calls that
  never block run std's code on the worker.
- **std's cancellation exactly.** A cancel lands at the next cancelation point;
  an operation the kernel finished first keeps its result. `operateTimeout` and
  `Batch.awaitConcurrent` never return while the kernel still holds a buffer.
- **Work stealing**, or `per_core` shared nothing; the root never leaves the
  thread that built the runtime.
- **No allocation after `init`.** Stacks are reserved in slabs at `init`; lane
  closures come from a pool reserved there.
- **`Loop`**: one thread's completion engine with no threads of its own, driven
  by `run(.nowait)`, `run(.once)` or `run(.until)`, completions by callback or
  `reap`; on Windows it can share the host's completion port.

## Scope

Linux (io_uring 5.19+) and Windows 8+ (IOCP; sleeps precise to about half a
millisecond from Windows 10 1803, the system tick before). On other systems
`init` returns `BackendUnavailable`.
