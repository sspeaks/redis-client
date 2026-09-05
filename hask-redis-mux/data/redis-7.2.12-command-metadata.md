# Redis command metadata provenance

The smart-proxy key extraction table in
`Database.Redis.Cluster.Commands` is derived from Redis OSS command JSON at
commit **9913c926510755fa0d241658f550338a02258edb** (the immutable Redis
7.2.12 release commit). It intentionally contains the command forms required
by issue #92 rather than an unsafe, incomplete "first argument is a key"
fallback. Unknown forms are rejected locally.

Run `scripts/audit-redis-command-metadata.sh` when changing the table. The
audit resolves the release reference and fetches command JSON only by the
recorded commit SHA; it fails if the SHA is not the current immutable release
commit or a representative JSON source cannot be retrieved.

