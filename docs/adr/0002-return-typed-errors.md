# Return typed errors from public runners

Public runners return `Either RedisClientError` rather than throwing. Redis error replies, protocol, transport, cluster and lifecycle failures share one error type, and `ClusterError` survives only as a migration alias.

Broad exception handlers must rethrow asynchronous exceptions: cancellation must never become a `Left` or an implicit reconnect.
