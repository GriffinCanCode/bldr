#!/bin/bash
# Run all microbenchmarks for Builder critical paths
#
# Usage:
#   ./run-microbenchmarks.sh           # Run all benchmarks
#   ./run-microbenchmarks.sh graph     # Run only graph benchmarks
#   ./run-microbenchmarks.sh hashing   # Run only hashing benchmarks
#   ./run-microbenchmarks.sh profile   # Run profiler on examples

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║       BUILDER MICROBENCHMARK SUITE                             ║"
echo "║    Testing critical paths: graph, hashing, serialization      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Function to run a benchmark
run_benchmark() {
    local name=$1
    local file=$2
    
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Running: ${name}${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    if dub run --single "$file"; then
        echo -e "\n${GREEN}✓ ${name} completed successfully${NC}"
    else
        echo -e "\n${RED}✗ ${name} failed${NC}"
        return 1
    fi
}

# Parse command line arguments
TARGET=${1:-all}

case $TARGET in
    graph)
        run_benchmark "Graph Operations Microbenchmarks" "graph_bench.d"
        ;;
    hashing)
        run_benchmark "Hashing Microbenchmarks" "hashing_bench.d"
        ;;
    serialization|serial)
        run_benchmark "Serialization Benchmarks" "serialization_bench.d"
        ;;
    workstealing|ws)
        run_benchmark "Work-Stealing Benchmarks" "work_stealing_bench.d"
        ;;
    chunking|chunk)
        run_benchmark "Content Chunking Benchmarks" "chunking_bench.d"
        ;;
    profile|profiler)
        run_benchmark "Build Profiler" "profiler.d"
        ;;
    realworld|real)
        run_benchmark "Real-World Benchmarks" "realworld.d"
        ;;
    all)
        echo "Running all microbenchmarks..."
        echo ""
        
        FAILED=0
        
        run_benchmark "Graph Operations" "graph_bench.d" || FAILED=$((FAILED + 1))
        run_benchmark "Hashing Performance" "hashing_bench.d" || FAILED=$((FAILED + 1))
        run_benchmark "Serialization" "serialization_bench.d" || FAILED=$((FAILED + 1))
        run_benchmark "Work-Stealing" "work_stealing_bench.d" || FAILED=$((FAILED + 1))
        run_benchmark "Content Chunking" "chunking_bench.d" || FAILED=$((FAILED + 1))
        
        echo -e "\n${BLUE}"
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║                    BENCHMARK SUMMARY                           ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        
        if [ $FAILED -eq 0 ]; then
            echo -e "${GREEN}✓ All benchmarks completed successfully!${NC}"
        else
            echo -e "${RED}✗ ${FAILED} benchmark(s) failed${NC}"
            exit 1
        fi
        ;;
    help|--help|-h)
        echo "Usage: $0 [target]"
        echo ""
        echo "Targets:"
        echo "  all            Run all microbenchmarks (default)"
        echo "  graph          Graph operations (node creation, topo sort, etc.)"
        echo "  hashing        Hashing performance (Blake3, tiered, two-tier)"
        echo "  serialization  Serialization benchmarks (SIMD vs JSON)"
        echo "  workstealing   Work-stealing deque benchmarks"
        echo "  chunking       Content chunking benchmarks"
        echo "  profile        Run build profiler on example projects"
        echo "  realworld      Real-world project benchmarks"
        echo "  help           Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0                # Run all benchmarks"
        echo "  $0 graph          # Run only graph benchmarks"
        echo "  $0 profile        # Profile example projects"
        ;;
    *)
        echo -e "${RED}Unknown target: $TARGET${NC}"
        echo "Run '$0 help' for usage information"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}Done!${NC}"

