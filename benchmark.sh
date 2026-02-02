#!/usr/bin/env nix-shell
#!nix-shell -i bash -p docker-compose redis

# Redis Client Performance Benchmark Script
# This script measures cache fill performance before/after optimizations

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}
TEST_SIZE_GB=${TEST_SIZE_GB:-5}
OLD_COMMIT="3176667"  # Commit before optimizations
NEW_COMMIT="07af19a"  # Latest commit with optimizations

print_header "Redis Client Performance Benchmark"

# Check prerequisites
print_info "Checking prerequisites..."

if ! command -v nix &> /dev/null; then
    print_error "nix not found. Please install Nix package manager."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    print_warning "docker not found. Assuming Redis is already running on $REDIS_HOST:$REDIS_PORT"
else
    # Check if Redis is running
    if ! docker ps | grep -q redis; then
        print_info "Starting Redis server via Docker..."
        docker compose up -d redis
        sleep 3
    else
        print_info "Redis server already running"
    fi
fi

# Test Redis connectivity
print_info "Testing Redis connectivity at $REDIS_HOST:$REDIS_PORT..."
if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping 2>&1 | grep -q "PONG"; then
    print_info "Redis connection successful"
else
    print_error "Cannot connect to Redis at $REDIS_HOST:$REDIS_PORT"
    print_error "Please ensure Redis is running: docker compose up -d redis"
    exit 1
fi

# Function to build at a specific commit
build_at_commit() {
    local commit=$1
    local label=$2
    
    print_info "Checking out commit $commit ($label)..."
    git checkout "$commit" --quiet
    
    print_info "Building $label version (this may take a few minutes)..."
    if nix build > /tmp/build_${label}.log 2>&1; then
        print_info "Build successful for $label"
        return 0
    else
        print_error "Build failed for $label. Check /tmp/build_${label}.log"
        return 1
    fi
}

# Function to run benchmark
run_benchmark() {
    local label=$1
    local output_file=$2
    
    print_info "Running benchmark for $label (${TEST_SIZE_GB}GB)..."
    
    # Flush Redis before test using redis-cli
    print_info "Flushing Redis..."
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" flushall > /dev/null 2>&1
    
    # Run the fill command and capture timing
    local start_time=$(date +%s.%N)
    
    if nix run . -- fill -h "$REDIS_HOST" -d "$TEST_SIZE_GB" -f > "$output_file" 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc)
        
        # Extract keys written from output
        local keys_written=$(grep "Wrote.*keys" "$output_file" | grep -oP '\d+(?= keys)' || echo "0")
        
        echo "$duration" > /tmp/time_${label}.txt
        echo "$keys_written" > /tmp/keys_${label}.txt
        
        print_info "$label completed in ${duration}s, wrote $keys_written keys"
        return 0
    else
        print_error "$label benchmark failed. Check $output_file"
        return 1
    fi
}

# Save current branch/commit
ORIGINAL_COMMIT=$(git rev-parse HEAD)
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)

print_info "Current commit: $ORIGINAL_COMMIT"
print_info "Current branch: $ORIGINAL_BRANCH"

# Create temporary directory for results
RESULTS_DIR="/tmp/redis_benchmark_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

print_header "Phase 1: Baseline (Before Optimizations)"

if build_at_commit "$OLD_COMMIT" "baseline"; then
    if run_benchmark "baseline" "$RESULTS_DIR/baseline_output.txt"; then
        BASELINE_TIME=$(cat /tmp/time_baseline.txt)
        BASELINE_KEYS=$(cat /tmp/keys_baseline.txt)
    else
        print_error "Baseline benchmark failed"
        git checkout "$ORIGINAL_COMMIT" --quiet
        exit 1
    fi
else
    print_error "Failed to build baseline version"
    git checkout "$ORIGINAL_COMMIT" --quiet
    exit 1
fi

print_header "Phase 2: Optimized (After Optimizations)"

if build_at_commit "$NEW_COMMIT" "optimized"; then
    if run_benchmark "optimized" "$RESULTS_DIR/optimized_output.txt"; then
        OPTIMIZED_TIME=$(cat /tmp/time_optimized.txt)
        OPTIMIZED_KEYS=$(cat /tmp/keys_optimized.txt)
    else
        print_error "Optimized benchmark failed"
        git checkout "$ORIGINAL_COMMIT" --quiet
        exit 1
    fi
else
    print_error "Failed to build optimized version"
    git checkout "$ORIGINAL_COMMIT" --quiet
    exit 1
fi

# Restore original commit
print_info "Restoring original commit..."
git checkout "$ORIGINAL_COMMIT" --quiet

print_header "Benchmark Results"

echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Test Size: ${TEST_SIZE_GB}GB"
echo "  Redis Host: ${REDIS_HOST}:${REDIS_PORT}"
echo ""

echo -e "${BLUE}Baseline (Before Optimizations):${NC}"
echo "  Time: ${BASELINE_TIME}s"
echo "  Keys Written: ${BASELINE_KEYS}"
echo "  Throughput: $(echo "scale=2; $BASELINE_KEYS / $BASELINE_TIME" | bc) keys/sec"
echo ""

echo -e "${BLUE}Optimized (After Optimizations):${NC}"
echo "  Time: ${OPTIMIZED_TIME}s"
echo "  Keys Written: ${OPTIMIZED_KEYS}"
echo "  Throughput: $(echo "scale=2; $OPTIMIZED_KEYS / $OPTIMIZED_TIME" | bc) keys/sec"
echo ""

# Calculate improvement
IMPROVEMENT=$(echo "scale=2; ($BASELINE_TIME - $OPTIMIZED_TIME) / $BASELINE_TIME * 100" | bc)
SPEEDUP=$(echo "scale=2; $BASELINE_TIME / $OPTIMIZED_TIME" | bc)

echo -e "${GREEN}Performance Improvement:${NC}"
echo "  Time Reduction: ${IMPROVEMENT}%"
echo "  Speedup: ${SPEEDUP}x"
echo ""

if (( $(echo "$IMPROVEMENT >= 50" | bc -l) )); then
    print_info "✓ Performance improvement of ${IMPROVEMENT}% meets the 50-70% target!"
elif (( $(echo "$IMPROVEMENT >= 30" | bc -l) )); then
    print_warning "Performance improvement of ${IMPROVEMENT}% is below target but still significant"
else
    print_warning "Performance improvement of ${IMPROVEMENT}% is lower than expected"
fi

echo ""
echo "Detailed logs saved to: $RESULTS_DIR"
echo "  - baseline_output.txt"
echo "  - optimized_output.txt"
echo ""

# Cleanup
rm -f /tmp/time_*.txt /tmp/keys_*.txt

print_header "Benchmark Complete"
