#!/bin/bash
# Quick Start Script for Azure Redis Connection
# 
# This script demonstrates the basic workflow of connecting to Azure Redis caches
# using the azure-redis-connect.py wrapper.

set -e

echo "=========================================="
echo "Azure Redis Connection - Quick Start"
echo "=========================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

# Check Azure CLI
if ! command -v az &> /dev/null; then
    echo "❌ Azure CLI is not installed"
    echo "   Install from: https://docs.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi
echo "✓ Azure CLI is installed"

# Check if logged in
if ! az account show &> /dev/null; then
    echo "❌ Not logged in to Azure CLI"
    echo "   Please run: az login"
    exit 1
fi
echo "✓ Logged in to Azure CLI"

# Check Python
if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 is not installed"
    exit 1
fi
echo "✓ Python 3 is installed"

# Check if redis-client is built
if ! [ -f "redis-client.cabal" ]; then
    echo "❌ Not in redis-client directory"
    echo "   Please cd to the redis-client directory"
    exit 1
fi
echo "✓ In redis-client directory"

echo ""
echo "All prerequisites met!"
echo ""

# Get subscription
echo "To list your Azure subscriptions, run:"
echo "  az account list --output table"
echo ""

current_sub=$(az account show --query name -o tsv 2>/dev/null || echo "")
if [ -n "$current_sub" ]; then
    echo "Current subscription: $current_sub"
    echo ""
    echo "Usage examples:"
    echo "  # Use current subscription"
    echo "  python3 azure-redis-connect.py --subscription \"$current_sub\""
    echo ""
    echo "  # Filter by resource group"
    echo "  python3 azure-redis-connect.py --subscription \"$current_sub\" --resource-group \"my-rg\""
else
    echo "Usage examples:"
    echo "  python3 azure-redis-connect.py --subscription \"My Subscription\""
    echo "  python3 azure-redis-connect.py --subscription \"12345678-1234-1234-1234-123456789012\""
    echo "  python3 azure-redis-connect.py -s \"My Subscription\" -g \"my-resource-group\""
fi

echo ""
echo "For detailed documentation, see AZURE_EXAMPLES.md"
echo "=========================================="
