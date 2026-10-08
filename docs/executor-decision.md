# Executor refusal: owner decision pending

The current implementation returns an available resource error when a call's
result can represent one. Refusal of a void/narrow call, or of a cancellation
job, terminates. This is the existing behavior, not an accepted final contract.

The minimal alternative has two parts:

1. Add a fallible raw-offload entry point. Its result adds `Canceled` and
   `ConcurrencyUnavailable` to the function's own error set (or wraps its
   ordinary result). A refused call returns before invoking user code. The
   existing void blocking hook cannot carry this error; a fallible hook would
   be a separate explicit surface, requiring a consumer adoption decision.
2. Give injected executors a separate, guaranteed cancellation submission
   capacity. Accepted calls retain their task/job storage until both execution
   and cancellation groups relinquish it. Reservations cover live jobs and
   retiring control groups; the ordinary lane cap alone is not a sufficient
   bound because a finished call can hand its slot to the next one while its
   cancellation still runs. Capacity is reserved at initialization, with no
   inline fallback and no allocation after it.

This does not widen std.Io's void/narrow vtable slots. An injected executor
used for those slots must additionally guarantee their acceptance within the
runtime's declared capacity, or the owner must explicitly retain termination
for that configuration. A fallible extension alone cannot solve that seam.

Before implementing this alternative, the owner must choose the public raw
call/hook surface, the injected acceptance contract and capacity accounting,
or explicitly retain the current resource-error/termination behavior. Tests
would force ordinary refusal, cancellation under a saturated executor, and
completion/cancellation races while poisoning released contexts. Nothing here
selects or implements a changed public contract.
