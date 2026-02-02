#!/bin/bash
set -e

# Target Buffer Size: 16 MB 
# (Larger than the 12MB requested by the app, and larger than the 8MB app chunks)
OPTIMIZED_SIZE=16777216 

echo "[-] Reading current Kernel Buffer limits..."
ORIGINAL_WMEM=$(sysctl -n net.core.wmem_max)
ORIGINAL_RMEM=$(sysctl -n net.core.rmem_max)

echo "    Current wmem_max: $ORIGINAL_WMEM"
echo "    Current rmem_max: $ORIGINAL_RMEM"

# Function to restore limits (runs on exit, error, or Ctrl+C)
restore_limits() {
    echo ""
    echo "[-] Restoring original Kernel Buffer limits..."
    # We use || true to prevent script failure if restoration fails mostly purely for clean exit codes
    sudo sysctl -w net.core.wmem_max=$ORIGINAL_WMEM > /dev/null || true
    sudo sysctl -w net.core.rmem_max=$ORIGINAL_RMEM > /dev/null || true
    echo "    Done."
}

# Trap signals to ensure cleanup happens
trap restore_limits EXIT INT TERM

echo "[-] Setting temporary optimized limits (sudo required)..."
sudo sysctl -w net.core.wmem_max=$OPTIMIZED_SIZE
sudo sysctl -w net.core.rmem_max=$OPTIMIZED_SIZE

echo "[-] Running redis-client with arguments: $@"
echo "---------------------------------------------------"

# Execute the client, passing all arguments from the script to the binary
redis-client "$@"
