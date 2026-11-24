# Bound multiplexer admission

The multiplexer defaults to at most 4,096 outstanding commands (queued plus in flight), drains at most 512 per write, and the client-created slot pools retain at most 256 idle response slots. The bounds trade low single-digit throughput for limited memory: in the recorded overload benchmark, peak stalled-server residency fell from 93.0 MiB to 60.0 MiB.

Submitters blocked on admission wait in an `MVar`-protected FIFO queue rather than an STM `retry`, because a shared `TVar` woke every blocked submitter on each release.
