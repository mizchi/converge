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

# Run tests for an experimental game-audit package
test-game-pkg pkg:
  moon test src/x/game_audit/{{pkg}}

# Run the generalized checkpoint-audit contract tests
test-audit:
  moon test src/audit

# Run the watermark-driven layered checkpoint tests
test-audit-layered:
  moon test src/audit/layered

# Run the persistence/transport runtime contract tests
test-audit-runtime:
  moon test src/audit/runtime

# Prevent the reusable audit layer from depending on the game application
check-audit-boundary:
  #!/usr/bin/env sh
  set -eu
  if rg -n '"mizchi/converge/x/game_audit' src/audit --glob 'moon.pkg'; then
    echo 'src/audit must not depend on src/x/game_audit' >&2
    exit 1
  fi

# Format code
fmt:
  moon fmt

# Generate type info
info:
  moon info

# Prove every proof-enabled package explicitly. Whole-module `moon prove`
# currently asks WhyML to translate non-proof dependency types as well.
prove:
  nix develop path:. --command moon prove src/audit
  nix develop path:. --command moon prove src/audit/quorum/vote
  nix develop path:. --command moon prove src/x/game_audit/audit

# Prove the multiplayer audit policy only
prove-game-audit:
  nix develop path:. --command moon prove src/x/game_audit/audit

# Prove the generalized checkpoint-audit contracts only
prove-audit-core:
  nix develop path:. --command moon prove src/audit
  nix develop path:. --command moon prove src/audit/quorum/vote

# Backward-compatible alias
prove-audit: prove-game-audit

# Check the stable-network and crash/loss TLA+ models
tla-check:
  nix develop path:. --command tlc -cleanup -metadir target/tla/safety -workers auto -config formal/tla/CheckpointDeliverySafety.cfg formal/tla/CheckpointDelivery.tla
  nix develop path:. --command tlc -cleanup -metadir target/tla/liveness -workers auto -config formal/tla/CheckpointDeliveryLiveness.cfg formal/tla/CheckpointDelivery.tla
  nix develop path:. --command tlc -cleanup -metadir target/tla/witness-safety -workers auto -config formal/tla/WitnessQuorumSafety.cfg formal/tla/WitnessQuorum.tla
  nix develop path:. --command tlc -cleanup -metadir target/tla/witness-liveness -workers auto -config formal/tla/WitnessQuorumLiveness.cfg formal/tla/WitnessQuorum.tla

# Confirm that removing each load-bearing guard produces a TLC counterexample
tla-counterexamples:
  nix develop path:. --command sh formal/tla/check-counterexamples.sh

# Build WASM-GC
build:
  moon build --target wasm-gc

# Run all benchmarks
bench:
  moon bench

# Run benchmarks for a specific package
bench-pkg pkg:
  moon bench -p mizchi/converge/{{pkg}}

# Run benchmarks for an experimental game-audit package
bench-game-pkg pkg:
  moon bench -p mizchi/converge/x/game_audit/{{pkg}}

# Benchmark event -> micro -> macro checkpoint sealing
bench-audit-layered:
  moon bench -p mizchi/converge/audit/layered --release

# Run the Cloudflare workerd/Durable Object integration tests
test-cf-game-audit:
  pnpm --dir examples/cf-game-audit test

# Type-check the Cloudflare game-audit adapter
check-cf-game-audit:
  pnpm --dir examples/cf-game-audit typecheck

# Type-check the Node 24 player-local SQLite reference adapter
check-node-audit-runtime:
  pnpm --dir examples/node-audit-runtime typecheck

# Test player-local SQLite restart and transaction atomicity
test-node-audit-runtime:
  pnpm --dir examples/node-audit-runtime test

# Validate the deploy bundle without mutating Cloudflare
build-cf-game-audit:
  pnpm --dir examples/cf-game-audit deploy:dry

# Pre-release checks
pre-release: fmt info check check-audit-boundary test build prove tla-check tla-counterexamples check-node-audit-runtime test-node-audit-runtime check-cf-game-audit test-cf-game-audit build-cf-game-audit
