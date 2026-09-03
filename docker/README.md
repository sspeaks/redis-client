# Redis Test Stacks

The default standalone and cluster Compose stacks publish Redis client ports
only on `127.0.0.1`. Cluster-bus ports remain private to internal Docker
networks and are not published to the host. Containers that need Redis must
join the applicable Compose network rather than connect through a host LAN
address.

Render and verify these network policies without starting containers:

```sh
./scripts/test-compose-networking.sh
```

When the serialized Docker validation slot is available, verify that Redis is
reachable through loopback and the internal Compose network but not through a
non-loopback host address:

```sh
./scripts/test-redis-loopback-connectivity.sh
```

## Host-network compatibility stack

The legacy `docker/cluster-host` stack is not part of the default development
or test flow. It uses host networking only for explicit compatibility
investigations, and every Redis process in that stack binds to loopback.

Run it only on a trusted single-user machine after confirming ports
`7000-7004` and `17000-17004` are unused:

```sh
REDIS_CLIENT_ALLOW_HOST_NETWORK=1 ./docker/cluster-host/make_cluster.sh
```
