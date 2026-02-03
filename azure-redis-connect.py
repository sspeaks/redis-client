#!/usr/bin/env python3
"""
Azure Redis Connection Script

This script wraps Azure CLI to list and connect to Azure Redis caches.
It supports Entra (Azure AD) authentication and can launch redis-client in various modes.

Usage:
    python3 azure-redis-connect.py --subscription <subscription-id> [--resource-group <rg-name>]
"""

import argparse
import json
import subprocess
import sys
import os
from typing import List, Dict, Optional


class AzureRedisConnector:
    """Handles Azure Redis cache discovery and connection."""

    def __init__(self, subscription: str, resource_group: Optional[str] = None):
        self.subscription = subscription
        self.resource_group = resource_group

    def run_az_command(self, command: List[str]) -> str:
        """Execute an Azure CLI command and return output."""
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=True
            )
            return result.stdout
        except subprocess.CalledProcessError as e:
            print(f"Error executing Azure CLI command: {e}", file=sys.stderr)
            print(f"Error output: {e.stderr}", file=sys.stderr)
            sys.exit(1)

    def set_subscription(self):
        """Set the Azure subscription context."""
        print(f"Setting subscription to: {self.subscription}")
        self.run_az_command(['az', 'account', 'set', '--subscription', self.subscription])

    def list_redis_caches(self) -> List[Dict]:
        """List all Redis caches in the subscription (optionally filtered by resource group)."""
        print("Fetching Redis caches from Azure...")
        
        if self.resource_group:
            command = [
                'az', 'redis', 'list',
                '--resource-group', self.resource_group,
                '--output', 'json'
            ]
        else:
            command = ['az', 'redis', 'list', '--output', 'json']
        
        output = self.run_az_command(command)
        caches = json.loads(output)
        
        if not caches:
            print("No Redis caches found.", file=sys.stderr)
            sys.exit(1)
        
        return caches

    def display_caches(self, caches: List[Dict]) -> int:
        """Display available caches and return user's selection."""
        print("\nAvailable Redis Caches:")
        print("-" * 80)
        
        for idx, cache in enumerate(caches, 1):
            name = cache.get('name', 'Unknown')
            resource_group = cache.get('resourceGroup', 'Unknown')
            location = cache.get('location', 'Unknown')
            sku = cache.get('sku', {}).get('name', 'Unknown')
            hostname = cache.get('hostName', 'Unknown')
            ssl_port = cache.get('sslPort', 6380)
            enable_non_ssl = cache.get('enableNonSslPort', False)
            
            print(f"{idx}. {name}")
            print(f"   Resource Group: {resource_group}")
            print(f"   Location: {location}")
            print(f"   SKU: {sku}")
            print(f"   Hostname: {hostname}")
            print(f"   SSL Port: {ssl_port}")
            print(f"   Non-SSL Enabled: {enable_non_ssl}")
            print("-" * 80)
        
        while True:
            try:
                selection = input(f"\nSelect a cache (1-{len(caches)}): ").strip()
                idx = int(selection)
                if 1 <= idx <= len(caches):
                    return idx - 1
                else:
                    print(f"Please enter a number between 1 and {len(caches)}")
            except (ValueError, KeyboardInterrupt):
                print("\nExiting.")
                sys.exit(0)

    def select_mode(self) -> str:
        """Prompt user to select connection mode."""
        print("\nSelect mode:")
        print("1. Fill mode - Fill cache with random data")
        print("2. CLI mode - Interactive Redis command-line interface")
        print("3. Tunnel mode - Start TLS tunnel proxy")
        
        while True:
            try:
                selection = input("\nSelect mode (1-3): ").strip()
                if selection == '1':
                    return 'fill'
                elif selection == '2':
                    return 'cli'
                elif selection == '3':
                    return 'tunn'
                else:
                    print("Please enter 1, 2, or 3")
            except KeyboardInterrupt:
                print("\n\nInterrupted by user. Exiting.")
                sys.exit(0)
            except ValueError:
                print("Invalid input. Please enter 1, 2, or 3")

    def check_entra_auth(self, cache: Dict) -> bool:
        """Check if the cache uses Entra (Azure AD) authentication only."""
        # Check for Entra auth by looking at the Redis access keys
        # If access keys are disabled, it's Entra-only
        name = cache.get('name')
        resource_group = cache.get('resourceGroup')
        
        print(f"\nChecking authentication method for {name}...")
        
        try:
            # Try to get access keys
            keys_output = self.run_az_command([
                'az', 'redis', 'list-keys',
                '--name', name,
                '--resource-group', resource_group,
                '--output', 'json'
            ])
            keys = json.loads(keys_output)
            
            # If primary key is None or empty, it's likely Entra-only
            if not keys.get('primaryKey'):
                print(f"✓ Cache uses Entra (Azure AD) authentication only")
                return True
            else:
                print(f"✓ Cache uses access key authentication")
                return False
        except subprocess.CalledProcessError as e:
            print(f"Warning: Could not retrieve access keys (exit code {e.returncode})")
            print(f"Assuming Entra authentication is required")
            return True
        except json.JSONDecodeError as e:
            print(f"Warning: Could not parse access keys response: {e}")
            print(f"Assuming Entra authentication is required")
            return True
        except Exception as e:
            print(f"Warning: Unexpected error checking auth method: {e}")
            print(f"Assuming Entra authentication is required")
            return True

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
            ])
            token_data = json.loads(token_output)
            token = token_data.get('accessToken')
            
            if not token:
                print("Error: Could not obtain access token", file=sys.stderr)
                sys.exit(1)
            
            # Get the signed-in user's Object ID
            # This is required for Entra authentication with Redis
            try:
                user_output = self.run_az_command([
                    'az', 'ad', 'signed-in-user', 'show',
                    '--query', 'id',
                    '--output', 'tsv'
                ])
                object_id = user_output.strip()
                print("✓ Successfully obtained access token")
                print(f"✓ User Object ID: {object_id}")
                return token, object_id
            except Exception as e:
                print(f"Warning: Could not retrieve user Object ID: {e}")
                print("Note: For Entra authentication, you may need to manually configure the username")
                return token, None
                
        except Exception as e:
            print(f"Error obtaining access token: {e}", file=sys.stderr)
            sys.exit(1)

    def get_access_key(self, cache: Dict) -> Optional[str]:
        """Get the primary access key for the cache."""
        name = cache.get('name')
        resource_group = cache.get('resourceGroup')
        
        try:
            keys_output = self.run_az_command([
                'az', 'redis', 'list-keys',
                '--name', name,
                '--resource-group', resource_group,
                '--output', 'json'
            ])
            keys = json.loads(keys_output)
            return keys.get('primaryKey')
        except Exception:
            return None

    def launch_redis_client(self, cache: Dict, mode: str):
        """Launch the redis-client with appropriate parameters."""
        hostname = cache.get('hostName')
        ssl_port = cache.get('sslPort', 6380)
        name = cache.get('name')
        
        print(f"\nConnecting to {name} ({hostname})...")
        
        # Check authentication method
        is_entra = self.check_entra_auth(cache)
        
        # Build command
        command = ['redis-client', mode, '-h', hostname, '-t']
        
        if is_entra:
            # Get Entra token and user Object ID
            token, object_id = self.get_entra_token(hostname)
            if object_id:
                # Pass the Object ID as username for Entra authentication
                command.extend(['-u', object_id, '-a', token])
                print(f"\n✓ Using Entra authentication with Object ID: {object_id}")
            else:
                # Fallback if we couldn't get the Object ID
                command.extend(['-a', token])
                print(f"\n✓ Using Entra authentication (username will default to 'default')")
                print(f"⚠ Warning: Could not retrieve Object ID; authentication may fail")
        else:
            # Get access key
            access_key = self.get_access_key(cache)
            if access_key:
                command.extend(['-a', access_key])
                print(f"\n✓ Using access key authentication")
            else:
                print("Warning: No authentication credentials available")
        
        # Add mode-specific options
        if mode == 'fill':
            # For fill mode, ask for data size
            while True:
                try:
                    data_gb = input("\nEnter data size in GB (e.g., 5): ").strip()
                    data_gb = int(data_gb)
                    if data_gb > 0:
                        command.extend(['-d', str(data_gb)])
                        
                        # Ask if they want to flush first
                        flush = input("Flush the cache before filling? (y/n): ").strip().lower()
                        if flush == 'y':
                            command.append('-f')
                        break
                    else:
                        print("Please enter a positive number")
                except KeyboardInterrupt:
                    print("\n\nInterrupted by user. Exiting.")
                    sys.exit(0)
                except ValueError:
                    print("Invalid input. Please enter a valid number.")
        
        print(f"\nLaunching redis-client with command:")
        print(f"  {' '.join(command)}")
        print("\n" + "=" * 80)
        
        # Execute the redis-client
        try:
            subprocess.run(command, check=True)
        except subprocess.CalledProcessError as e:
            print(f"\nError running redis-client: {e}", file=sys.stderr)
            sys.exit(1)
        except KeyboardInterrupt:
            print("\n\nInterrupted by user.")
            sys.exit(0)

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
        mode = self.select_mode()
        
        # Launch redis-client
        self.launch_redis_client(selected_cache, mode)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Azure Redis Connection Script - List and connect to Azure Redis caches'
    )
    parser.add_argument(
        '--subscription', '-s',
        required=True,
        help='Azure subscription ID or name'
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
    
    # Create connector and run
    connector = AzureRedisConnector(args.subscription, args.resource_group)
    connector.run()


if __name__ == '__main__':
    main()
