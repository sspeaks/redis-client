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
        # Only switch subscription if user explicitly provided one
        if self.subscription_was_provided:
            print(f"Setting subscription to: {self.subscription}")
            self.run_az_command(['az', 'account', 'set', '--subscription', self.subscription])
        # If using default subscription, no need to switch

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
        print()
        
        # Table header
        header = f"{'#':<4} {'Name':<30} {'Resource Group':<25} {'Location':<15} {'SKU':<12} {'SSL Port':<10}"
        print(header)
        print("-" * len(header))
        
        # Table rows
        for idx, cache in enumerate(caches, 1):
            name = cache.get('name', 'Unknown')
            resource_group = cache.get('resourceGroup', 'Unknown')
            location = cache.get('location', 'Unknown')
            sku = cache.get('sku', {}).get('name', 'Unknown')
            ssl_port = cache.get('sslPort', 6380)
            
            # Truncate long names if necessary
            name_display = name[:28] + '..' if len(name) > 30 else name
            rg_display = resource_group[:23] + '..' if len(resource_group) > 25 else resource_group
            
            row = f"{idx:<4} {name_display:<30} {rg_display:<25} {location:<15} {sku:<12} {ssl_port:<10}"
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

    def select_mode(self) -> str:
        """Prompt user to select connection mode."""
        print("\nSelect mode:")
        print("1. Fill mode - Fill cache with random data")
        print("2. CLI mode - Interactive Redis command-line interface")
        print("3. Tunnel mode - Start TLS tunnel proxy")
        
        while True:
            try:
                sys.stdout.flush()  # Ensure prompt is displayed
                selection = input("\nSelect mode (1-3): ")
                # Clean the input thoroughly
                selection = selection.replace('\r', '').replace('\n', '').strip()
                if not selection:
                    continue
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
        # Azure Redis has a 'disableAccessKeyAuthentication' property
        # When true, only Entra (Azure AD) authentication is allowed
        name = cache.get('name')
        
        # First check if the property is already in the cache object
        if 'disableAccessKeyAuthentication' in cache:
            entra_only = cache.get('disableAccessKeyAuthentication', False)
            if entra_only:
                print(f"✓ Cache {name} uses Entra (Azure AD) authentication only")
            else:
                print(f"✓ Cache {name} uses access key authentication")
            return entra_only
        
        # If not available, fetch detailed cache information
        resource_group = cache.get('resourceGroup')
        print(f"\nChecking authentication method for {name}...")
        
        try:
            # Get detailed cache information
            show_output = self.run_az_command([
                'az', 'redis', 'show',
                '--name', name,
                '--resource-group', resource_group,
                '--output', 'json'
            ])
            cache_details = json.loads(show_output)
            
            # Check if access key authentication is disabled
            entra_only = cache_details.get('disableAccessKeyAuthentication', False)
            
            if entra_only:
                print(f"✓ Cache uses Entra (Azure AD) authentication only")
            else:
                print(f"✓ Cache uses access key authentication")
            
            return entra_only
        except subprocess.CalledProcessError as e:
            print(f"Warning: Could not retrieve cache details (exit code {e.returncode})")
            print(f"Will attempt both authentication methods")
            return False
        except json.JSONDecodeError as e:
            print(f"Warning: Could not parse cache details: {e}")
            print(f"Will attempt both authentication methods")
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
