# Experimental game-audit stack

This subtree contains the multiplayer anti-cheat and auditable-asset prototype.
It is intentionally outside converge's stable CRDT package namespace.

`src/bft/` remains the reusable Byzantine-aware adapter around converge events.
`src/audit/` provides the reusable checkpoint policy, commitment projection,
head classifier, authenticated delivery/quorum, runtime bridge, Merkle tree,
and authenticated map. The packages here are one
opinionated game application of those contracts:

```text
src/audit/{policy, commitment, head, merkle, authmap, layered,
           runtime, delivery_auth, quorum, runtime/bridge}
              │
              ▼
policy / audit / checkpoint / attestation / witness_manifest / wire / crypto / worker
              │
              ├──── open_world / central_replay / pvp_session
              ▼
replay
              │
              ▼
inventory / market
```

`attestation` adapts the application-neutral `audit/quorum` collector to game
replay and checkpoint finality. Roster selection, referee identity, manifest
binding, and the meaning of an approval remain game policy.

The `replay` package includes the one-dimensional telegraphed dungeon,
multi-attack encounter, and two-team public-state PvP epoch kernels. The PvP
kernel resolves simultaneous movement, range attacks, HP, and team score
independently of transcript delivery order. A finalized encounter mints an opaque,
checkpoint-bound replay match consumed by `attestation`; callers cannot inject
a raw replay-success Boolean. Adversarial sessions can instead commit an
independent referee, witness roster, and `n > 3f` fault policy into the session
manifest; `n - f` domain-separated replay signatures mint a checkpoint-bound
certificate. `pvp_session` requires an exact PvP replay/checkpoint/referee match
before exposing the honest-witness signing path and collector. These APIs are
experimental and may change as projectile travel and visibility rules,
overlapping mechanics, persistence, and production cryptography are added.

The `open_world` package adds a selective-replay gate for irregular encounters.
An audit plan commits the game manifest, sample rate, hidden seed, and a
canonical registration-observer roster/fault policy. A plan-bound `n - f`
observer quorum can certify one exact `(plan, slot, encounter digest)` without
claiming that it replayed the game. The public signing path reserves one digest
before signing: exact retries sign the same statement and a second digest for
the same plan/slot is refused without changing its root. A later
authority checkpoint seals the eligible encounter digests under a Merkle root
before the seed is revealed. Leaves bind registration slots to encounter
digests, an authenticated map binds slot membership, and the close manifest
commits the exact count. Opaque evidence is issued for a signed slot beyond
that count, a different included digest at the same slot, or a valid
authenticated-map proof that the in-range slot is absent. Invalid, missing, or
ambiguous proofs cannot accuse the seal. The same conflict can be opened from
an observer certificate even if the authority withheld its encounter
checkpoint. Unsampled ordinary outcomes may finalize from a
matching replay-witness certificate; samples, challenges, sparse economic
results, and high-value outcomes require the checkpoint-bound central replay
capability. Open-world replay bundle v2 also requires an independently signed
transparency checkpoint to include the exact audit digest and its audit-to-seal
link under world/epoch-specific authenticated-map keys. See
`docs/open-world-audit-ja.md` for the threat model and gameplay
constraints.

`OpenWorldObserverSigningStore` is the persistence boundary. Its in-memory
adapter tests sequential compare-and-set behavior; a production adapter must
atomically and durably reserve a slot before returning success. Restoring a
ledger can require an exact trusted `(observer, key, root, size)` anchor, which
rejects empty or foreign snapshots. A domain-separated authority checkpoint
can publish a key-unique authenticated map of these anchors; exact membership
opens an opaque capability consumed by ledger restore. A concrete
head tracker advances only through the exact next parent and creates opaque
evidence when same-epoch or wrong-parent authority-signed forks meet. A concrete
ordered gap response is planned without mutation and committed only when every
head is valid. `wire` adds versioned canonical CBOR, allocation preflight, and
receiver budgets. `crypto` connects the unaudited `experimental_crypto`
SHA-256/Ed25519 implementation for known-vector integration and realistic cost
measurement; it is not a production-security claim. A concrete
crash-safe/concurrent store, production socket/gossip transport, audited crypto
backend, and durable head-history transaction remain integration work.
`worker` exposes the narrow JS/wasm-gc bridge used by
`examples/cf-game-audit`: benchmark fixture generation, full envelope opening,
the proved classifiers, and real-crypto PvE/PvP/open-world bundle replay. `central_replay`
decodes a bounded versioned bundle, authenticates every signed event through
the BFT adapter, reconstructs the complete transcript, and only reports success
after the game checkpoint's manifest/event/public-state roots match; PvP also
requires a replay-bound `n-f` witness certificate. Current-owner listing uses a
separate bounded bundle containing an authority checkpoint, committed game
manifest, witness roster/attestations, and one authenticated inventory proof.
The central verifier binds that proof back to its verified creation receipt.
The Cloudflare adapter stores replay bundles separately from Queue messages and
now tests a SQLite head/history transaction, restart recovery, all three Queue
replay modes, and monotonic per-asset inventory heads. A head update requires
the exact parent, an increasing epoch, and owner/version consistency;
observer signing-store durability, transparency-head remote witness quorum,
multi-asset atomic inventory heads, ancestry revocation, and production
cryptography remain open.

Run the isolated checks with:

```sh
just test-game-pkg replay
just prove-game-audit
just prove-audit-core
just test-audit
moon test src/audit/merkle
moon test src/audit/authmap
just bench-game-pkg replay
just test-game-pkg open_world
just bench-game-pkg open_world
just test-game-pkg wire
just test-game-pkg crypto
just bench-game-pkg wire
just bench-game-pkg crypto
just test-game-pkg worker
moon test src/x/game_audit/central_replay
just test-cf-game-audit
```
