# V11: actual suite stack measurements

Owner decision db221e5 moves V11 completion to each package's own adoption of
reactor. These fixtures preserve the earlier investigation; incomplete suites
and consumer seams are not successful measurements. This batch leaves the
1 MiB stack default unchanged.

`prepare.zig` clones an owned immutable consumer source fixture into a separate
adapted fixture. Zig token matching changes only `testing.io` and
`std.testing.io` selections in its `src/` files to the shared reactor Io.
Strings, comments, test bodies, expectations, production APIs and dependency
pins are preserved. Its build receives a dedicated runner and `v11` step;
existing native linking, SDKs, fixtures and dependencies remain in the build.
No consumer repository or active clone is written. The working root's original
source files supply actual source-boundary checks and runtime fixtures. Only
compiled source paths point at a separate adapted copy, preserving generated
native fixture paths relative to the working root. Scratch outputs live there;
the immutable source snapshot remains untouched. An obsolete lazy
planner-artifact lookup is replaced with its canonical script invocation only
in the build fixture, preserving dependency pins and test/SDK wiring.

`runner.zig` invokes the actual imported test functions, serially, inside
reactor tasks. A constant shakedown Layer forwards the suite's compile-time
Io aliases to the current runtime; its forwarding frames are included in the
diagnostic watermarks. Each test gets a fresh runtime at the unchanged 1 MiB stack
reservation, zero workers, owned offload, and stack painting enabled. Standard
Threaded test infrastructure remains for std helpers; native fuzz entry points,
allocator leak checks and error logs remain checks. Every test reports status,
parked high water and overall high water. Skips and failures are explicit. A per-test watchdog bounds an incomplete
fixture at 120 seconds; a watchdog exit supplies no completed-suite maximum.
Painting is diagnostic instrumentation, never performance evidence.

Build the adapter with `zig build-exe bench/v11/prepare.zig -OReleaseSafe`.
Invoke it with absolute reactor-root, immutable-source and new-fixture paths;
then use `zig build v11 -Doptimize=ReleaseSafe` inside the adapted fixture.
Focused `-Dtest-filter` slices are explicitly partial, not full-suite proof.
Raw outputs and source/test selections must accompany a maximum. A suite that
uses a simulated Io for a test still measures its actual test-body stack, but
zero parked depth is not evidence about an unexercised native path.

## Initial immutable sources

| Package | Published main snapshot |
| --- | --- |
| uplink | `869dd0c8bedee138538d0999d61680c5d71ce4be` |
| cloak | `c53aa6149fa09dc945bf55b6aabc322bdd06f7cc` |
| conduit | `81e3fcd45890b8420af49f21ad458df531cbbe32` |
| airlock | `112a6a233aa98ac831aa8b702ba0607587f367f4` |
| relic | `67077cb2293a8ce3489da007186bc2964e4ef3d9` |

cloak's published `src/root.zig` is an infrastructure-floor comment with no
TLS tests. A published TLS suite, or an owner-approved immutable review
snapshot, is required for its V11 row. No unfinished branch is silently pinned.
The default stack size remains unchanged until all five actual suites and
native deep-stack/guard measurements establish a justified default.
