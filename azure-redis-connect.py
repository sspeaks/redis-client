#!/usr/bin/env python3
"""
Azure Redis Connection Script

This script wraps Azure CLI to list and connect to Azure Redis caches.
It supports Entra (Azure AD) authentication and can launch redis-client in various modes.

Usage:
    python3 azure-redis-connect.py [--subscription <subscription-id>] [--resource-group <rg-name>]
    
    If --subscription is not provided, the currently selected Azure subscription will be used.
"""

import argparse
import json
import subprocess
import sys
import os
import atexit
from typing import List, Dict, Optional

# Save terminal settings at startup
_original_terminal_settings = None
if sys.stdin.isatty():
    try:
        import termios
        _original_terminal_settings = termios.tcgetattr(sys.stdin.fileno())
    except (ImportError, termios.error):
        pass

def restore_terminal():
    """Restore terminal to original settings."""
    if _original_terminal_settings is not None:
        try:
            import termios
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, _original_terminal_settings)
        except:
            pass

# Register terminal restoration on exit
atexit.register(restore_terminal)


class AzureRedisConnector:
    """Handles Azure Redis cache discovery and connection."""

    def __init__(self, subscription: str, resource_group: Optional[str] = None, subscription_was_provided: bool = True):
        self.subscription = subscription
        self.resource_group = resource_group
        self.subscription_was_provided = subscription_was_provided

    def obfuscate_sensitive_data(self, text: str) -> str:
        """Obfuscate access keys and tokens in text for display."""
        if not text:
            return text
        # Look for patterns that might be access keys or tokens
        # Azure Redis access keys are typically 43 characters base64
        # Tokens can be much longer (JWT format)
        import re
        # Pattern for base64-like strings (likely access keys)
        text = re.sub(r'\b[A-Za-z0-9+/]{40,}={0,2}\b', '***REDACTED***', text)
        return text
    
    def run_az_command(self, command: List[str], obfuscate_output: bool = False) -> str:
        """Execute an Azure CLI command and return output."""
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=True
            )
            if obfuscate_output:
                return result.stdout  # Return raw output for parsing
            return result.stdout
        except subprocess.CalledProcessError as e:
            # Obfuscate sensitive data in error messages
            safe_stderr = self.obfuscate_sensitive_data(e.stderr) if e.stderr else ""
            print(f"Error executing Azure CLI command (code {e.returncode})", file=sys.stderr)
            if safe_stderr:
                print(f"Error output: {safe_stderr}", file=sys.stderr)
            sys.exit(1)

    def set_subscription(self):
        """Set the Azure subscription context."""
        # Only switch subscription if user explicitly provided one
        if self.subscription_was_provided:
            print(f"Setting subscription to: {self.subscription}")
            self.run_az_command(['az', 'account', 'set', '--subscription', self.subscription])
        # If using default subscription, no need to switch

    def list_redis_caches(self) -> List[Dict]:
        """List all Redis caches in the subscription (optionally filtered by resource group)."""
        print("Fetching Redis caches from Azure...")
        
        caches = []
        
        # 1. Fetch Standard Redis Caches
        try:
            if self.resource_group:
                command = [
                    'az', 'redis', 'list',
                    '--resource-group', self.resource_group,
                    '--output', 'json'
                ]
            else:
                command = ['az', 'redis', 'list', '--output', 'json']
            
            output = self.run_az_command(command)
            standard_caches = json.loads(output)
            
            # Enrich with type
            for cache in standard_caches:
                cache['cache_type'] = 'Standard'
                # Ensure shard count is correct for standard
                if 'shardCount' not in cache and cache.get('sku', {}).get('capacity', 0) > 0:
                     # For standard, it's not always obvious, but usually just 0 if not premium clustered
                     pass
            
            caches.extend(standard_caches)
            
        except Exception as e:
            print(f"Warning: Failed to list Standard Redis caches: {e}", file=sys.stderr)

        # 2. Fetch Azure Managed Redis (Enterprise) Caches
        try:
            # Check if redisenterprise extension is available or command works
            if self.resource_group:
                command = [
                    'az', 'redisenterprise', 'list',
                    '--resource-group', self.resource_group,
                    '--output', 'json'
                ]
            else:
                command = ['az', 'redisenterprise', 'list', '--output', 'json']
            
            output = self.run_az_command(command)
            enterprise_caches = json.loads(output)
            
            # Enrich with type and normalize fields
            for cache in enterprise_caches:
                cache['cache_type'] = 'Enterprise'
                # Enterprise list returns 'hostName', but ports are in databases.
                # We'll set a placeholder or default.
                if 'sslPort' not in cache:
                    cache['sslPort'] = 10000  # distinct default
                
                # Normalize shard count if available (Enterprise might not show it in list easily)
                pass 
                
            caches.extend(enterprise_caches)

        except Exception as e:
             # Just ignore if extension not installed or command fails
             pass

        if not caches:
            print("No Redis caches found.", file=sys.stderr)
            sys.exit(1)
        
        return caches

    def display_caches(self, caches: List[Dict]) -> int:
        """Display available caches and return user's selection."""
        print("\nAvailable Redis Caches:")
        print()
        
        # Table header
        header = f"{'#':<4} {'Name':<30} {'Type':<12} {'Resource Group':<25} {'Location':<15} {'SKU':<12} {'SSL Port':<10}"
        print(header)
        print("-" * len(header))
        
        # Table rows
        for idx, cache in enumerate(caches, 1):
            name = cache.get('name', 'Unknown')
            cache_type = cache.get('cache_type', 'Standard')
            resource_group = cache.get('resourceGroup', 'Unknown')
            location = cache.get('location', 'Unknown')
            
            # SKU handling might differ
            sku_info = cache.get('sku', {})
            if isinstance(sku_info, dict):
                sku = sku_info.get('name', 'Unknown')
            else:
                sku = str(sku_info)
                
            ssl_port = cache.get('sslPort', 'N/A')
            
            # Truncate long names if necessary
            name_display = name[:28] + '..' if len(name) > 30 else name
            rg_display = resource_group[:23] + '..' if len(resource_group) > 25 else resource_group
            
            row = f"{idx:<4} {name_display:<30} {cache_type:<12} {rg_display:<25} {location:<15} {sku:<12} {ssl_port:<10}"
            print(row)
        
        print()
        
        while True:
            try:
                sys.stdout.flush()  # Ensure prompt is displayed
                selection = input(f"Select a cache (1-{len(caches)}): ")
                # Clean the input thoroughly
                selection = selection.replace('\r', '').replace('\n', '').strip()
                if not selection:
                    continue
                idx = int(selection)
                if 1 <= idx <= len(caches):
                    return idx - 1
                else:
                    print(f"Please enter a number between 1 and {len(caches)}")
            except (ValueError, KeyboardInterrupt):
                print("\nExiting.")
                sys.exit(0)

    def select_mode(self) -> tuple:
        """Prompt user to select connection mode.
        
        Returns:
            tuple: (mode, tunnel_type)
            mode is one of: 'fill', 'cli', 'tunn'
            tunnel_type is one of: 'smart', 'pinned', None
        """
        print("\nSelect mode:")
        print("1. Fill mode - Fill cache with random data")
        print("2. CLI mode - Interactive Redis command-line interface")
        print("3. Tunnel mode - Start TLS tunnel proxy")
        
        mode = None
        tunnel_type = None

        while True:
            try:
                sys.stdout.flush()  # Ensure prompt is displayed
                selection = input("\nSelect mode (1-3): ")
                # Clean the input thoroughly
                selection = selection.replace('\r', '').replace('\n', '').strip()
                if not selection:
                    continue
                if selection == '1':
                    mode = 'fill'
                    break
                elif selection == '2':
                    mode = 'cli'
                    break
                elif selection == '3':
                    mode = 'tunn'
                    break
                else:
                    print("Please enter 1, 2, or 3")
            except KeyboardInterrupt:
                print("\n\nInterrupted by user. Exiting.")
                sys.exit(0)
            except ValueError:
                print("Invalid input. Please enter 1, 2, or 3")
        
        # If tunnel mode, ask for tunnel type (smart vs pinned)
        if mode == 'tunn':
            print("\nSelect tunnel type:")
            print("1. Smart Proxy - Intelligent routing for Cluster (handles MOVED/ASK)")
            print("2. Pinned Proxy - Direct connection to specific node/shard")
            
            while True:
                try:
                    sys.stdout.flush()
                    tsel = input("\nSelect tunnel type (1-2): ").replace('\r', '').replace('\n', '').strip()
                    if not tsel:
                        continue
                    
                    if tsel == '1':
                        tunnel_type = 'smart'
                        break
                    elif tsel == '2':
                        tunnel_type = 'pinned'
                        break
                    else:
                        print("Please enter 1 or 2")
                except KeyboardInterrupt:
                    print("\n\nInterrupted by user. Exiting.")
                    sys.exit(0)
            
        return mode, tunnel_type

    def get_enterprise_database(self, cache: Dict) -> Optional[Dict]:
        """Fetch the first database for an Enterprise cache."""
        name = cache.get('name')
        resource_group = cache.get('resourceGroup')
        
        print(f"Fetching database details for Enterprise cache {name}...")
        try:
            output = self.run_az_command([
                'az', 'redisenterprise', 'database', 'list',
                '--cluster-name', name,
                '--resource-group', resource_group,
                '--output', 'json'
            ])
            dbs = json.loads(output)
            if dbs and len(dbs) > 0:
                # Return the first database
                return dbs[0]
            return None
        except Exception as e:
            print(f"Error fetching enterprise databases: {e}", file=sys.stderr)
            return None

    def check_entra_auth(self, cache: Dict) -> bool:
        """Check if the cache uses Entra (Azure AD) authentication only.
        
        Returns True if Entra-only authentication is required, False if access keys work.
        """
        name = cache.get('name')
        resource_group = cache.get('resourceGroup')
        cache_type = cache.get('cache_type', 'Standard')
        
        if cache_type == 'Enterprise':
            # For Enterprise, Entra is supported, but checking policy assignments is different/preview.
            # Simple heuristic: try to get keys. If we can't get keys, assume Entra.
            # (Fetching keys happens later anyway, but we check here to decide auth flow)
            if self.get_access_key(cache):
                return False
            return True

        # Strategy: Check if access policy assignments exist
        # The presence of access policy assignments indicates Entra authentication is configured
        
        print(f"\nChecking authentication method for {name}...")
        
        try:
            # Check if access policy assignments exist (indicates Entra auth)
            policy_output = self.run_az_command([
                'az', 'redis', 'access-policy-assignment', 'list',
                '--name', name,
                '--resource-group', resource_group,
                '--output', 'json'
            ])
            policies = json.loads(policy_output)
            
            # If access policy assignments exist, Entra authentication is configured
            if policies and len(policies) > 0:
                print(f"✓ Found {len(policies)} access policy assignment(s)")
                print(f"  Entra (Azure AD) authentication required")
                return True
            else:
                # No access policy assignments - using access key authentication
                print(f"✓ No access policy assignments found")
                print(f"  Access key authentication available")
                return False
                
        except subprocess.CalledProcessError as e:
            # If the command fails, it might be an older cache or permission issue
            # Try to check for access keys as fallback
            print(f"  Cannot check access policy assignments (command failed with code {e.returncode})")
            print(f"  Attempting fallback to access key check...")
            
            try:
                # Fallback: try to retrieve access keys
                keys_output = self.run_az_command([
                    'az', 'redis', 'list-keys',
                    '--name', name,
                    '--resource-group', resource_group,
                    '--output', 'json'
                ], obfuscate_output=True)
                keys = json.loads(keys_output)
                primary_key = keys.get('primaryKey')
                
                # If keys exist and are non-empty, assume access key auth is available
                # NOTE: This is a fallback and may not be 100% reliable
                if primary_key and len(primary_key) > 0:
                    print(f"✓ Access keys retrieved successfully")
                    print(f"  Access key authentication appears to be available")
                    return False
                else:
                    print(f"✓ Access keys are empty/null")
                    print(f"  Entra (Azure AD) authentication likely required")
                    return True
                    
            except subprocess.CalledProcessError:
                # Both methods failed - default to Entra auth
                print(f"✓ Cannot determine auth method - defaulting to Entra authentication")
                return True
        except json.JSONDecodeError as e:
            print(f"Warning: Could not parse policy response: {e}")
            print(f"  Assuming Entra authentication is required")
            return True
        except Exception as e:
            print(f"Warning: Unexpected error checking auth method: {e}")
            print(f"  Assuming Entra authentication is required")
            return True

    def extract_oid_from_token(self, token: str) -> Optional[str]:
        """Extract the 'oid' (Object ID) claim from a JWT access token.
        
        JWT tokens have three base64-encoded parts separated by dots.
        The middle part contains the claims payload including 'oid'.
        """
        import base64
        
        try:
            # JWT format: header.payload.signature
            parts = token.split('.')
            if len(parts) != 3:
                return None
            
            # Decode the payload (second part)
            # JWT uses base64url encoding, need to add padding
            payload_b64 = parts[1]
            # Add padding if needed (base64 requires length to be multiple of 4)
            padding = 4 - len(payload_b64) % 4
            if padding != 4:
                payload_b64 += '=' * padding
            
            # Replace URL-safe characters with standard base64 characters
            payload_b64 = payload_b64.replace('-', '+').replace('_', '/')
            
            payload_bytes = base64.b64decode(payload_b64)
            payload = json.loads(payload_bytes.decode('utf-8'))
            
            return payload.get('oid')
        except Exception:
            return None

    def get_entra_token(self, hostname: str) -> tuple:
        """Get an Entra (Azure AD) access token for Redis using Azure CLI.
        
        Returns:
            tuple: (access_token, object_id) where object_id is the OID of the authenticated user
        """
        print("\nObtaining Entra access token...")
        
        # Use Azure CLI to get the access token for Redis
        # The resource/scope for Azure Redis is: https://redis.azure.com
        try:
            token_output = self.run_az_command([
                'az', 'account', 'get-access-token',
                '--resource', 'https://redis.azure.com',
                '--output', 'json'
            ], obfuscate_output=True)
            token_data = json.loads(token_output)
            token = token_data.get('accessToken')
            
            if not token:
                print("Error: Could not obtain access token", file=sys.stderr)
                sys.exit(1)
            
            # Extract the Object ID directly from the JWT token
            # This avoids conditional access issues with 'az ad signed-in-user show'
            object_id = self.extract_oid_from_token(token)
            
            if object_id:
                print("✓ Successfully obtained access token (token hidden for security)")
                print(f"✓ User Object ID: {object_id}")
                return token, object_id
            else:
                print("✓ Successfully obtained access token (token hidden for security)")
                print("Warning: Could not extract Object ID from token")
                print("Note: For Entra authentication, you may need to manually configure the username")
                return token, None
                
        except Exception as e:
            safe_error = self.obfuscate_sensitive_data(str(e))
            print(f"Error obtaining access token: {safe_error}", file=sys.stderr)
            sys.exit(1)

    def get_access_key(self, cache: Dict) -> Optional[str]:
        """Get the primary access key for the cache."""
        name = cache.get('name')
        resource_group = cache.get('resourceGroup')
        cache_type = cache.get('cache_type', 'Standard')
        
        try:
            if cache_type == 'Enterprise':
                # For Enterprise, we need to get keys from the database
                # We assume the database info is already attached or we use 'default'
                # If cache has 'database_name' set, use it, otherwise assume 'default'
                db_name = cache.get('database_name', 'default')
                
                keys_output = self.run_az_command([
                    'az', 'redisenterprise', 'database', 'list-keys',
                    '--cluster-name', name,
                    '--resource-group', resource_group,
                    '--database-name', db_name,
                    '--output', 'json'
                ], obfuscate_output=True)
                keys = json.loads(keys_output)
                return keys.get('primaryKey')
            else:
                keys_output = self.run_az_command([
                    'az', 'redis', 'list-keys',
                    '--name', name,
                    '--resource-group', resource_group,
                    '--output', 'json'
                ], obfuscate_output=True)
                keys = json.loads(keys_output)
                return keys.get('primaryKey')
        except Exception as e:
            # print(f"Debug: failed to get key: {e}")
            return None

    def launch_redis_client(self, cache: Dict, mode: str, tunnel_type: Optional[str] = None):
        """Launch the redis-client with appropriate parameters."""
        name = cache.get('name')
        cache_type = cache.get('cache_type', 'Standard')
        
        # Resolve Enterprise details if needed
        if cache_type == 'Enterprise':
            db_info = self.get_enterprise_database(cache)
            if db_info:
                cache['sslPort'] = db_info.get('port', 10000)
                cache['database_name'] = db_info.get('name', 'default')
                print(f"✓ Resolved Enterprise database '{cache['database_name']}' on port {cache['sslPort']}")
            else:
                print("Warning: Could not resolve Enterprise database details", file=sys.stderr)

        hostname = cache.get('hostName')
        ssl_port = cache.get('sslPort', 6380)
        
        print(f"\nConnecting to {name} ({hostname}:{ssl_port})...")
        
        # Check authentication method
        is_entra = self.check_entra_auth(cache)
        
        # Build command
        command = ['redis-client', mode, '-h', hostname, '-p', str(ssl_port), '-t']
        
        # Add tunnel mode type if specified
        if mode == 'tunn' and tunnel_type:
            command.extend(['--tunnel-mode', tunnel_type])
            print(f"✓ Using {tunnel_type} tunnel mode")

        # Check for cluster mode
        shard_count = cache.get('shardCount')
        if shard_count and int(shard_count) > 0:
            command.append('-c')
            print(f"✓ Detected cluster with {shard_count} shards - enabling cluster mode")
        
        if is_entra:
            # Get Entra token and user Object ID
            token, object_id = self.get_entra_token(hostname)
            if object_id:
                # Pass the Object ID as username for Entra authentication
                command.extend(['-u', object_id, '-a', token])
                print(f"\n✓ Using Entra authentication with Object ID: {object_id}")
                print(f"  (Access token hidden for security)")
            else:
                # Fallback if we couldn't get the Object ID
                command.extend(['-a', token])
                print(f"\n✓ Using Entra authentication (username will default to 'default')")
                print(f"  (Access token hidden for security)")
                print(f"⚠ Warning: Could not retrieve Object ID; authentication may fail")
        else:
            # Get access key
            access_key = self.get_access_key(cache)
            if access_key:
                command.extend(['-a', access_key])
                print(f"\n✓ Using access key authentication")
                print(f"  (Access key hidden for security)")
            else:
                print("Warning: No authentication credentials available")
        
        # Add mode-specific options
        if mode == 'fill':
            # For fill mode, ask for data size
            while True:
                try:
                    sys.stdout.flush()  # Ensure prompt is displayed
                    data_gb = input("\nEnter data size in GB (e.g., 5): ")
                    # Clean the input thoroughly
                    data_gb = data_gb.replace('\r', '').replace('\n', '').strip()
                    if not data_gb:
                        continue
                    data_gb = int(data_gb)
                    if data_gb > 0:
                        command.extend(['-d', str(data_gb)])
                        
                        # Ask if they want to flush first
                        sys.stdout.flush()  # Ensure prompt is displayed
                        flush = input("Flush the cache before filling? (y/n): ")
                        flush = flush.replace('\r', '').replace('\n', '').strip().lower()
                        if flush == 'y':
                            command.append('-f')
                        
                        # Add optimized parameters for cluster fills
                        # These values were determined through extensive performance testing
                        # and provide ~9.4 Gbps throughput with optimal GC settings
                        if shard_count and int(shard_count) > 0:
                            # Cluster mode: use optimized settings
                            print("\n✓ Using optimized cluster fill parameters:")
                            print("  - 8 parallel processes (-P 8)")
                            print("  - 6 threads per process (-n 6)")
                            print("  - Key size: 512 bytes")
                            print("  - Value size: 262,144 bytes (256 KB)")
                            print("  - Pipeline: 8,192 commands/batch")
                            command.extend([
                                '-P', '8',              # 8 parallel processes
                                '-n', '6',              # 6 threads per process
                                '--key-size', '512',
                                '--value-size', '262144',
                                '--pipeline', '8192'
                            ])
                        else:
                            # Non-cluster mode: use lighter settings
                            print("\n✓ Using optimized standalone fill parameters:")
                            print("  - Key size: 512 bytes")
                            print("  - Value size: 262,144 bytes (256 KB)")
                            print("  - Pipeline: 8,192 commands/batch")
                            command.extend([
                                '--key-size', '512',
                                '--value-size', '262144',
                                '--pipeline', '8192'
                            ])
                        
                        break
                    else:
                        print("Please enter a positive number")
                except KeyboardInterrupt:
                    print("\n\nInterrupted by user. Exiting.")
                    sys.exit(0)
                except ValueError:
                    print("Invalid input. Please enter a valid number.")
        
        print(f"\nLaunching redis-client with command:")
        # Create a safe version of the command for display
        safe_command = []
        skip_next = False
        for i, arg in enumerate(command):
            if skip_next:
                safe_command.append('***REDACTED***')
                skip_next = False
            elif arg in ['-a', '--password']:
                safe_command.append(arg)
                skip_next = True
            else:
                safe_command.append(arg)
        print(f"  {' '.join(safe_command)}")
        print("\n" + "=" * 80)
        
        # Execute the redis-client
        try:
            subprocess.run(command, check=True)
        except subprocess.CalledProcessError as e:
            safe_error = self.obfuscate_sensitive_data(str(e))
            print(f"\nError running redis-client: {safe_error}", file=sys.stderr)
            restore_terminal()
            sys.exit(1)
        except KeyboardInterrupt:
            print("\n\nInterrupted by user.")
            restore_terminal()
            sys.exit(0)
        finally:
            # Always restore terminal settings after redis-client exits
            restore_terminal()

    def run(self):
        """Main execution flow."""
        # Set subscription
        self.set_subscription()
        
        # List caches
        caches = self.list_redis_caches()
        
        # Display and select cache
        selected_idx = self.display_caches(caches)
        selected_cache = caches[selected_idx]
        
        # Select mode
        mode, tunnel_type = self.select_mode()
        
        # Launch redis-client
        self.launch_redis_client(selected_cache, mode, tunnel_type)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Azure Redis Connection Script - List and connect to Azure Redis caches'
    )
    parser.add_argument(
        '--subscription', '-s',
        help='Azure subscription ID or name (defaults to currently selected subscription)'
    )
    parser.add_argument(
        '--resource-group', '-g',
        help='Optional: Resource group name to filter caches'
    )
    
    args = parser.parse_args()
    
    # Check if Azure CLI is available
    try:
        subprocess.run(['az', '--version'], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: Azure CLI (az) is not installed or not in PATH", file=sys.stderr)
        print("Install Azure CLI from: https://docs.microsoft.com/cli/azure/install-azure-cli", file=sys.stderr)
        sys.exit(1)
    
    # Check if user is logged in to Azure CLI
    try:
        subprocess.run(['az', 'account', 'show'], capture_output=True, check=True)
    except subprocess.CalledProcessError:
        print("Error: Not logged in to Azure CLI", file=sys.stderr)
        print("Please run: az login", file=sys.stderr)
        sys.exit(1)
    
    # Get subscription - use provided one or default to current
    subscription = args.subscription
    subscription_was_provided = args.subscription is not None
    if not subscription:
        try:
            result = subprocess.run(
                ['az', 'account', 'show', '--query', 'name', '-o', 'tsv'],
                capture_output=True,
                text=True,
                check=True
            )
            subscription = result.stdout.strip()
            print(f"Using currently selected subscription: {subscription}")
        except subprocess.CalledProcessError:
            print("Error: Could not determine current subscription", file=sys.stderr)
            print("Please specify a subscription with --subscription or select one with 'az account set'", file=sys.stderr)
            sys.exit(1)
    
    # Create connector and run
    connector = AzureRedisConnector(subscription, args.resource_group, subscription_was_provided)
    connector.run()


if __name__ == '__main__':
    main()
