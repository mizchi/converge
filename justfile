# crdt_db justfile

# Check types
check:
  moon check

# Check all targets
check-all:
  moon check --target all

# Run all tests
test:
  moon test

# Run tests with verbose output
test-v:
  moon test -v

# Update snapshot tests
test-update:
  moon test -u

# Run tests for a specific package
test-pkg pkg:
  moon test src/{{pkg}}

# Format code
fmt:
  moon fmt

# Generate type info
info:
  moon info

# Build WASM-GC
build:
  moon build --target wasm-gc

# Run all benchmarks
bench:
  moon bench

# Run benchmarks for a specific package
bench-pkg pkg:
  moon bench -p mizchi/crdt_db/{{pkg}}

# Pre-release checks
pre-release: fmt info check test build
