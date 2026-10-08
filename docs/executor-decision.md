# Executor refusal

Owner decision db221e5 requires refusal errors for offloads, including void
functions, with no inline fallback. `blocking` now adds `Canceled` and
`ConcurrencyUnavailable` to every function result. `blockingHook.call` has
the same fallible surface. A rejected submission returns before user code
runs. Original user errors and successful results remain intact. A queued
void call can be canceled without running; accepted calls retain their storage
until all execution and cancellation owners let go. Hook adoption is a separate
consumer batch.

## Remaining std.Io seam

Zig's fixed `std.Io` signatures cannot be widened by an implementation.
In particular, `childKill` returns void and CPU-clock `sleep` returns only
`Canceled`. These operations can still reach an injected executor. There is
no caller error channel for its ordinary refusal. Termination is the existing
behavior and is not accepted as the completed contract.

Cancellation uses another job to invoke the accepted call's executor-specific
`Group.cancel`. That job must also be accepted. Returning early on refusal
would abandon live frames or an acquired result, and running it inline would
violate the offload requirement. The ordinary lane cap does not bound retiring
cancellation groups: a finished call can hand its slot to the next one while
its cancellation control job still runs.

The minimal alternatives are a separate guaranteed executor/capacity for fixed
void/narrow std.Io operations and cancellation, or routing refusing injected
executors only through the fallible raw surface. Either requires an explicit
injected-executor contract, reserved capacity covering live and retiring control
jobs, and no allocation or inline fallback after initialization. The owner
choice on this seam remains pending; this revision implements the fallible
raw part only.

Verification for the chosen remainder must force saturation, refusal and
completion/cancellation races while poisoning released contexts, on native
backends and under the thread sanitizer. Existing LATER/R1 lifetime and fault
regressions remain required.
