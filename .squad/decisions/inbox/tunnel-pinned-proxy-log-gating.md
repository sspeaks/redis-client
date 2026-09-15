# Tunnel decision: gate pinned proxy traffic logging behind an explicit flag

- **Context:** Issue #79 identified per-request pinned-proxy logging and `hFlush stdout` calls as hot-path overhead that serialized forwarding threads and rendered payload previews on every request.
- **Decision:** Keep pinned proxy lifecycle/error logging on by default, but gate request/response payload previews behind the new `--verbose-pinned-proxy-traffic` CLI flag. The default pinned path emits no per-request traffic logs and no per-request explicit stdout flushes.
- **Consequence:** Day-to-day pinned proxy runs stay observable through listener startup, accepted connections, forwarding completion, and error summaries, while deep payload tracing remains available as an opt-in debugging mode.
