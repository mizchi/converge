# BFT-CRDT Research Summary

## Overview

This document summarizes the research on making CRDTs Byzantine Fault Tolerant (BFT), based on Kleppmann's "Making CRDTs Byzantine Fault Tolerant" (PaPoC 2022) and related work.

## Key Papers

1. **Kleppmann, "Making CRDTs Byzantine Fault Tolerant" (PaPoC 2022)**
   - Hash graph approach: each operation references hashes of causal dependencies
   - Enables detection of equivocation (same peer sending conflicting operations)
   - Preserves CRDT convergence guarantees even with Byzantine peers

2. **Shapiro et al., "Conflict-Free Replicated Data Types" (2011)**
   - Foundation of CRDT theory (CmRDTs and CvRDTs)
   - Assumes reliable causal broadcast — no Byzantine fault tolerance

3. **Zhao et al., "BFT-CRDTs: Byzantine Fault Tolerant CRDTs" (2022)**
   - Extends Kleppmann's approach with concrete verification protocols

## Architecture

### Problem

Standard CRDTs assume honest peers. A malicious peer can:
- **Equivocate**: send different operations with the same sequence number to different peers
- **Forge history**: create operations with invalid causal dependencies
- **Tamper**: modify operations in transit

### Solution: Hash Graph

Replace EventId-based causal references with cryptographic hash references:

```
Standard CRDT:  Event { id: (peer, counter), deps: [EventId] }
BFT-CRDT:      SignedEvent { digest: Hash(event), signature: Sign(digest), deps: [Hash] }
```

### Verification Flow

On receiving a `SignedEvent`:

1. **Hash integrity** — Recompute hash from event content + dependency hashes; reject if mismatch
2. **Signature verification** — Verify signature matches author's public key
3. **Equivocation detection** — Same (peer, counter) with different digest = Byzantine fault
4. **Causal delivery** — Buffer events whose dependencies haven't been received yet

### Adapter Pattern

The BFT layer wraps existing CRDT logic without modifying it:

```
[Application]
     |
[CrdtDoc]        -- unchanged
     |
[BFTAdapter]     -- NEW: validates before passing to CrdtDoc
     |
[Transport]      -- unchanged
```

## Implementation Strategy for converge

### Design Decisions

- **Non-invasive**: New `src/bft/` package; no changes to existing types/graph/doc
- **Trait-based crypto**: `Hasher`, `Signer`, `Verifier` traits allow swapping implementations
- **Mock crypto for testing**: FNV-1a hash + HMAC-like mock signatures for deterministic tests
- **Production-ready interface**: Same traits can be implemented with SHA-256 + Ed25519

### Key Types

| Type | Purpose |
|------|---------|
| `Digest` | Content-addressed hash of an event |
| `Signature` | Cryptographic signature over a digest |
| `PublicKey` | Peer's public key for signature verification |
| `SignedEvent` | Event + digest + signature + dependency hashes |
| `BFTAlert` | Report of detected Byzantine behavior |
| `DeliveryResult` | Accepted / Buffered / Rejected(alert) |

### Threat Model

| Attack | Detection |
|--------|-----------|
| Content tampering | Hash mismatch on recomputation |
| Signature forgery | Signature verification failure |
| Equivocation | Same (peer, counter) with different digest |
| Missing dependencies | Causal delivery buffer |
