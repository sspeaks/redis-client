# Redis Cluster End-to-End Tests

This directory contains the end-to-end tests for Redis Cluster functionality.

## Running Cluster E2E Tests

### Prerequisites

1. Docker and docker-compose installed
2. redis-cli installed (for cluster creation)
3. Cabal build system

### Quick Start

Run the cluster E2E tests using the provided script:

```bash
./runClusterE2ETests.sh
```

Or using Make:

```bash
make test-cluster-e2e
```

### Manual Steps

If you want to run the tests manually:

1. Start the Redis cluster nodes:
```bash
cd docker-cluster
docker-compose up -d
```

2. Create the cluster:
```bash
cd docker-cluster
./make_cluster.sh
```

3. Build and run the tests:
```bash
cabal build ClusterEndToEnd
cabal run ClusterEndToEnd
```

4. Clean up:
```bash
cd docker-cluster
docker-compose down
```

### Using Make Targets

The Makefile provides convenient targets for cluster operations:

- `make redis-cluster-start` - Start cluster nodes and create cluster
- `make redis-cluster-stop` - Stop and remove cluster nodes
- `make test-cluster-e2e` - Run full cluster E2E test suite

## Test Coverage

The cluster E2E tests cover:

1. **Topology Discovery** - Connecting to cluster and discovering topology via CLUSTER SLOTS
2. **Command Routing** - Routing GET/SET commands to the correct nodes based on key slots
3. **Multi-key Operations** - Testing that multiple keys route to their respective nodes
4. **Hash Tags** - Verifying keys with hash tags route to the same slot
5. **Sequential Operations** - Testing INCR and other operations that modify values
6. **Cluster Commands** - Testing PING and CLUSTER SLOTS through the cluster client

## Cluster Configuration

The test cluster consists of 5 Redis nodes:
- Node 1: localhost:6379
- Node 2: localhost:6380
- Node 3: localhost:6381
- Node 4: localhost:6382
- Node 5: localhost:6383

The cluster is configured with:
- 3 master nodes
- 2 replica nodes
- 16384 slots distributed across masters
- No persistence (for faster test execution)

## Troubleshooting

### Cluster Creation Fails

If cluster creation fails, ensure:
- All ports (6379-6383) are available
- redis-cli is installed and in PATH
- Docker has network access

### Tests Fail to Connect

- Verify cluster is running: `cd docker-cluster && docker-compose ps`
- Check cluster status: `redis-cli -p 6379 cluster info`
- Ensure no firewall blocking localhost ports

### Clean State

If tests are behaving unexpectedly, fully reset:
```bash
cd docker-cluster
docker-compose down -v  # Remove volumes
docker-compose up -d
./make_cluster.sh
```
