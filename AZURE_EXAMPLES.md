# Azure Redis Connection Examples

This document provides examples of how to use the `azure-redis-connect.py` script to connect to Azure Redis caches.

## Prerequisites

1. **Azure CLI**: Must be installed and configured
   ```bash
   # Install Azure CLI (if not already installed)
   # See: https://docs.microsoft.com/cli/azure/install-azure-cli
   
   # Login to Azure
   az login
   ```

2. **Python 3**: Version 3.6 or later

3. **Redis Client**: The Haskell redis-client must be built
   ```bash
   cabal build
   ```

4. **Permissions**: You need appropriate Azure permissions to:
   - List Redis caches
   - Get Redis access keys
   - Get access tokens for Redis resources

## Basic Usage

### Connect to caches in the currently selected subscription

If you have a subscription already selected with `az account set`, you can run the script without specifying a subscription:

```bash
python3 azure-redis-connect.py
```

The script will automatically use your currently selected Azure subscription.

### Connect to a cache in a specific subscription

```bash
python3 azure-redis-connect.py --subscription "My Subscription Name"
```

or with subscription ID:

```bash
python3 azure-redis-connect.py --subscription "12345678-1234-1234-1234-123456789012"
```

### Filter by resource group

```bash
python3 azure-redis-connect.py --subscription "My Subscription" --resource-group "my-redis-rg"
```

Or with the currently selected subscription:

```bash
python3 azure-redis-connect.py --resource-group "my-redis-rg"
```

### Short flags

```bash
python3 azure-redis-connect.py -s "My Subscription" -g "my-redis-rg"
```

## Interactive Workflow

When you run the script, it will guide you through:

1. **List Caches**: Shows all available Redis caches with details
   ```
   Available Redis Caches:
   
   | # | Name           | Resource Group | Location | SKU      | Hostname                                      | SSL Port | Non-SSL |
   |---|----------------|----------------|----------|----------|-----------------------------------------------|----------|---------|
   | 1 | my-prod-cache  | production-rg  | eastus   | Premium  | my-prod-cache.redis.cache.windows.net        | 6380     | False   |
   | 2 | my-test-cache  | test-rg        | westus   | Standard | my-test-cache.redis.cache.windows.net        | 6380     | False   |
   | 3 | my-dev-cache   | dev-rg         | eastus2  | Basic    | my-dev-cache.redis.cache.windows.net         | 6380     | True    |
   ```

2. **Select Cache**: Choose a cache by entering its number
   ```
   Select a cache (1-3): 1
   ```

3. **Authentication**: The script automatically detects and handles:
   - **Entra (Azure AD) authentication**: Gets token via Azure CLI
   - **Access key authentication**: Retrieves primary access key

4. **Select Mode**: Choose how to use the cache
   ```
   Select mode:
   1. Fill mode - Fill cache with random data
   2. CLI mode - Interactive Redis command-line interface
   3. Tunnel mode - Start TLS tunnel proxy
   
   Select mode (1-3): 2
   ```

5. **Launch**: Connects to the cache with the redis-client

## Mode Examples

### Fill Mode

Fill mode is used to populate a Redis cache with random data for testing.

When you select fill mode, you'll be prompted for:
- **Data size**: How many GB of data to generate
- **Flush option**: Whether to clear the cache first

Example interaction:
```
Select mode (1-3): 1

Enter data size in GB (e.g., 5): 10
Flush the cache before filling? (y/n): y

Launching redis-client with command:
  redis-client fill -h my-cache.redis.cache.windows.net -t -a <token> -d 10 -f
```

### CLI Mode

CLI mode provides an interactive Redis command-line interface.

Example usage:
```
Select mode (1-3): 2

Launching redis-client with command:
  redis-client cli -h my-cache.redis.cache.windows.net -t -a <token>

Starting CLI mode
> PING
PONG
> SET mykey "Hello Azure Redis"
OK
> GET mykey
"Hello Azure Redis"
> exit
```

### Tunnel Mode

Tunnel mode starts a TLS tunnel proxy that listens on localhost and forwards traffic to the Azure Redis cache.

Example:
```
Select mode (1-3): 3

Launching redis-client with command:
  redis-client tunn -h my-cache.redis.cache.windows.net -t -a <token>

Starting tunnel mode
Tunnel listening on localhost:6379
```

Now you can connect to localhost:6379 with any Redis client.

## Authentication Details

### Entra (Azure AD) Authentication

When a cache uses Entra authentication (access keys disabled), the script:
1. Detects that access keys are not available
2. Uses `az account get-access-token --resource https://redis.azure.com` to obtain an OAuth token
3. Retrieves the Object ID (OID) of the signed-in user via `az ad signed-in-user show`
4. Passes both the Object ID (as username) and the token (as password) to redis-client

**Entra Authentication Requirements:**

For Entra authentication to work properly with Azure Cache for Redis, you need:
- **Username**: The Object ID (OID) of the Azure AD user, service principal, or managed identity
- **Password**: The access token obtained from Azure CLI

According to [Microsoft's documentation](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-azure-active-directory-for-authentication):
- The user must have appropriate RBAC roles on the Redis cache (e.g., "Redis Cache Contributor")
- Access keys must be disabled on the cache
- The cache must be configured to use Entra ID authentication
- **The username for authentication must be the Object ID**, not a friendly name

The script automatically retrieves the Object ID and passes it to redis-client using the `--username` (`-u`) parameter.

### Access Key Authentication

When a cache uses traditional access keys:
1. Retrieves the primary access key using `az redis list-keys`
2. Passes the key as the password to redis-client

## Troubleshooting

### "Not logged in to Azure CLI"

Run `az login` to authenticate with Azure.

### "No Redis caches found"

Verify:
- The subscription ID/name is correct
- The resource group (if specified) exists and contains Redis caches
- You have permissions to list Redis resources

### "Could not obtain access token"

Ensure:
- You're logged in to Azure CLI (`az login`)
- Your account has permissions to access the Redis resource
- The cache is configured correctly

### "Error running redis-client"

Verify:
- The redis-client is built: `cabal build`
- You're running the script from the redis-client directory
- Cabal is in your PATH

## Advanced Usage

### Using with different Azure environments

```bash
# Set the Azure cloud (if not using public cloud)
az cloud set --name AzureUSGovernment

# Then run the script
python3 azure-redis-connect.py -s "My Subscription"
```

### Batch operations

You can script the selection process (though interactive mode is recommended):

```bash
# This is more complex and would require modifying the script
# to accept additional flags like --cache-name and --mode
```

## Security Considerations

1. **Token lifetime**: Entra tokens obtained via Azure CLI typically have a lifetime of 1 hour (3600 seconds). If your session runs longer than this, the token will expire and you'll need to re-run the script to obtain a fresh token. For long-running operations like large fill jobs, monitor for authentication errors.

2. **Token storage**: The script does not persist tokens. They are only used for the current session.

3. **Access keys**: When using access key authentication, the keys are passed as command-line arguments (visible in process listings).

4. **Network security**: Always use TLS (`-t` flag) when connecting to Azure Redis caches.

## Performance Tips

For fill mode with large datasets:

```bash
# Use environment variables to tune performance
REDIS_CLIENT_FILL_CHUNK_KB=4096 python3 azure-redis-connect.py -s "My Subscription"
```

Then select fill mode and configure the data size.
