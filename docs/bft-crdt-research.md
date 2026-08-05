# BFT-CRDT Research Summary

ゲーム検証を含む全体像は
[CRDT 接続型リアルタイムゲーム検証: 研究とアーキテクチャ](./research-and-architecture-ja.md)
を参照。この文書は BFT-CRDT adapter 層に限定する。

## Overview

This document summarizes the research on making CRDTs Byzantine Fault Tolerant (BFT), based on Kleppmann's "Making CRDTs Byzantine Fault Tolerant" (PaPoC 2022) and related work.

## Key Papers

1. **[Kleppmann, "Making CRDTs Byzantine Fault Tolerant" (PaPoC 2022)](https://martin.kleppmann.com/papers/bft-crdt-papoc22.pdf)**
   - Hash graph approach: each operation references hashes of causal dependencies
   - Enables detection of equivocation (same peer sending conflicting operations)
   - Preserves CRDT convergence guarantees even with Byzantine peers

2. **[Kleppmann and Howard, "Byzantine Eventual Consistency and the Fundamental Limits of Peer-to-Peer Databases" (2020)](https://arxiv.org/abs/2012.00472)**
   - Defines Byzantine Eventual Consistency and Byzantine causal broadcast
   - Clarifies which application classes can tolerate arbitrary Byzantine nodes
   - Does not imply that arbitrary game rules are valid or fair

3. **[Shapiro et al., "Conflict-Free Replicated Data Types" (2011)](https://inria.hal.science/inria-00609399/document)**
   - Foundation of CRDT theory (CmRDTs and CvRDTs)
   - The operation-based path assumes reliable causal delivery; the standard
     model does not provide Byzantine fault tolerance

4. **[Chai and Zhao, "Byzantine Fault Tolerance for Services with Commutative Operations" (2014)](https://doi.org/10.1109/SCC.2014.37)**
   - Avoids total ordering on every commutative operation
   - Uses on-demand or periodic Byzantine agreement for synchronization
   - Uses a replicated-service model different from converge's player/authority topology

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
BFT-CRDT:      SignedEvent { session, digest: Hash(session, event), signature, deps: [Hash] }
```

### Verification Flow

On receiving a `SignedEvent`:

1. **Session binding** — Reject an event signed for another session
2. **Hash integrity** — Recompute the session-bound hash from event content + dependency hashes; reject if mismatch
3. **Roster binding** — Require the event's peer id to map to the supplied public key in the trusted session manifest
4. **Signature verification** — Verify the signature with that roster-bound key
5. **Dependency binding** — Require every declared `EventId` to match its authenticated dependency digest
6. **Equivocation detection** — Same (peer, counter) with different digest = Byzantine fault, including while the first event is buffered
7. **Causal delivery** — Buffer events whose dependencies haven't been received yet

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
- **Swappable interface**: The same traits can use SHA-256 + Ed25519; the
  current experimental adapter is for interoperability and measurement, not a
  production-security claim

### Key Types

| Type | Purpose |
|------|---------|
| `Digest` | Content-addressed hash of an event |
| `Signature` | Cryptographic signature over a digest |
| `PublicKey` | Peer's public key for signature verification |
| `SignedEvent` | Event + digest + signature + dependency hashes |
| `AuthenticatedEvent` | Private-field capability minted only after the full adapter pipeline accepts |
| `BFTAlert` | Report of detected Byzantine behavior |
| `DeliveryResult` | Accepted / Buffered / Rejected(alert) |

### Threat Model

| Attack | Detection |
|--------|-----------|
| Content tampering | Hash mismatch on recomputation |
| Signature forgery | Signature verification failure |
| Equivocation | Same (peer, counter) with different digest |
| Unknown or impersonated peer | Trusted roster lookup and peer-to-key equality |
| Dependency ID/hash substitution | Authenticated pair plus accepted digest-to-`EventId` lookup |
| Cross-session replay | Session id is included in `event-v2` digest and checked before delivery |
| Missing dependencies | Causal delivery buffer; absence alone is not cheat evidence |

## Current contract boundary

The adapter now enforces the flow above, using a length-prefixed `event-v2`
serialization. Dependency pairs are sorted as pairs, so harmless network
reordering keeps the same digest without allowing an ID to be paired with a
different dependency hash. A buffered event reserves `(peer, counter)`, making
equivocation detectable before causal delivery. `Accepted` and buffered flushes
return `AuthenticatedEvent`, whose private fields prevent callers from turning
raw or rejected events into trusted inventory sources.

`AuthenticatedEvent` is intentionally not sufficient for an asset mutation.
The downstream experimental `src/x/game_audit/replay/` package passes it through
a sealed replay kernel and emits `ReplayedAssetEffect`; inventory and marketplace
APIs require that stronger capability. The reference authority-effect kernel
derives its manifest from its version tag and configured effect-author key.

The game-specific kernels additionally bind telegraphs, player inputs,
authority receipts, and verified checkpoint roots before deriving survivor
loot. The multi-attack encounter also commits its full attack plan and
replay-derived public state. This does not change the BFT adapter's
responsibility: the adapter proves message authenticity and causal consistency,
while the game kernel proves application semantics.

`register_peer` is a trusted setup operation, not a network protocol. The game
session must populate it from an authenticated manifest before accepting remote
traffic; rebinding an existing peer is rejected. `BFTAdapter` internals are not
public so consumers cannot mutate the roster or digest indices directly.

The included `FnvHasher`, `MockSigner`, and `MockVerifier` are deterministic
test doubles. They do **not** provide collision resistance or unforgeability.
Production deployment still requires a cryptographic hash, real signatures,
secure key distribution, globally unique session ids bound to the exact
manifest version, complete boss/PvP game-mode replay, and resource limits for
buffered dependencies.
