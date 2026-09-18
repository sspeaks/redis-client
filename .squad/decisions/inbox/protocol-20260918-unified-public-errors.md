# Unified public Redis error propagation

- Public sequential, standalone, cluster, low-level command, and topology
  refresh runners return `Either RedisClientError`.
- `RedisClientError` is layered into server, conversion, protocol, transport,
  cluster, and lifecycle failures.
- Synchronous exception causes remain structured as `SomeException`, and retry
  and lifecycle failures retain nested `RedisClientError` causes.
- Every broad exception boundary rethrows asynchronous cancellation instead of
  converting it to `Left`.
- Redis error replies cannot decode successfully through `FromResp ()` or
  `FromResp RespData`.
- `ClusterError` is retained only as a deprecated migration alias.
