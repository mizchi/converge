# Multiplayer checkpoint audit prototype

Research rationale and the cross-layer architecture are summarized in
[`research-and-architecture-ja.md`](./research-and-architecture-ja.md). This
document is the implementation ledger and measurement record.

This prototype defines the acceptance boundary shared by cooperative, PvE, and
adversarial multiplayer modes. It deliberately does not treat CRDT convergence
as proof that a game transition is valid.

## Acceptance policy

Participant approvals are represented by a fixed-size Boolean vector derived
from the generic roster-bound collector in `src/audit/quorum/`, adapted to game
finality in `src/x/game_audit/attestation/`. Missing approvals are
`false`; a verified signed objection is carried separately as
`challenged=true` so that absence and accusation are not conflated. If one
participant signs both choices, its approval is revoked and the state becomes
an equivocation challenge regardless of delivery order.

| Evidence | Decision |
| --- | --- |
| No authority verdict, no quorum | `Pending` |
| No authority verdict, quorum | `Attested` |
| Challenge without a matching replay | `Challenged` |
| Authority accepts and quorum has no challenge | `Finalized` |
| Authority accepts and replay matches | `Finalized` |
| Referee accepts and an `n - f` replay-witness certificate matches | `Finalized` |
| Authority rejects | `Rejected` |
| Zero or out-of-range quorum threshold | Never creates quorum |

Only `Finalized` checkpoints can authorize marketplace items. A newly created
item must have a valid delta Merkle proof; a later listing must have a valid
current-inventory proof. Both paths fail when the checkpoint ancestry is known
to contain a rejection.

The executable marketplace path is capability-based:

```text
session-bound SignedEvent
  -> BFT validation
  -> AuthenticatedEvent capability
  -> sealed deterministic AssetReplayKernel
  -> ReplayedAssetEffect capability
  -> ItemReceipt[] / AssetTransfer[] exact-effect binding
  -> Merkle asset_delta_root
  -> deterministic inventory plan
  -> public_state_root
  -> authority-signed VerifiedCheckpoint over both roots
  -> participant evidence / matching replay / replay-witness certificate
  -> FinalizedCheckpoint capability
  -> atomic inventory commit
  -> current owner + membership + ancestry marketplace gate
```

An item receipt binds its asset id, recipient, item type, quantity, source event
digest, and output index. Merkle inclusion proves that the finalized authority
checkpoint committed to that receipt. It does not by itself prove that the
source game event was entitled to generate the item; deterministic replay must
establish that separate claim.

`ReceiptBatch` rejects duplicate asset ids and duplicate `(source_event,
output_index)` coordinates within one checkpoint. `InventoryIndex` additionally
rejects duplicate asset ids across its loaded checkpoint ancestry. It plans
creations and ownership transfers without mutating the committed state, then
atomically commits only when a `FinalizedCheckpoint` binds the expected session,
parent checkpoint, increasing epoch, delta root, and resulting state root.

Ownership transfer requires an existing asset, matching current owner and
version, a non-empty different recipient, and a `ReplayedAssetEffect`
capability whose session, source digest, typed effect, and kernel manifest all
match. The updated record retains its creation receipt digest and origin
coordinates while advancing the owner, version, and last-event digest.
Creation receipts use the same capability check before inventory planning, and
the direct marketplace path cannot bypass it.

`AuthenticatedEvent` proves that the event passed the BFT adapter's session,
hash, roster, signature, equivocation, and causal-dependency checks.
`ReplayEngine` then requires a valid typed effect, a non-empty derived kernel
manifest, the same session, and acceptance by a sealed `AssetReplayKernel`
before minting `ReplayedAssetEffect`. The reference `CanonicalAssetKernel`
accepts only an exact canonical payload signed by its configured effect-author
key. Its manifest is derived from the kernel version and author key instead of
being caller-selected.

That reference kernel is suitable for an authority-emitted effect stream such
as a 1:N MMORPG server. The compatibility game kernel replays one
checkpoint-bound telegraphed PvE attack. The newer encounter kernel commits a
complete non-overlapping attack plan in its manifest, carries integer position
and HP across attacks, and derives clear/failure plus a canonical public-state
root from the exact transcript. Only a matching authority checkpoint can turn
the candidate into `DungeonEncounterResolution`; only that capability can
construct `DungeonEncounterLootKernel` or the opaque `CheckpointReplayMatch`.
The attestation API accepts that checkpoint-bound capability (or no replay
evidence), not a caller-provided Boolean, and checks the exact checkpoint digest
and authority key before enabling the authority fallback.

For an adversarial N:N session, `ReplayWitnessCollector` uses a separate
`ReplayWitness` signature domain, so a general checkpoint approval cannot be
reused as a claim that its signer executed the replay. The session manifest
commits the game manifest digest, independent referee key, canonical witness
roster, and maximum Byzantine fault count `f`. A policy is valid only when
`n > 3f`; certification requires `n - f` clean replay approvals. Challenges and
equivocations do not count, but up to `f` faulty witnesses cannot veto a valid
certificate. The certificate is private-field and remains bound to both the
checkpoint digest and verified referee key.

This is a conditional Byzantine guarantee: it assumes at most `f` roster
members are faulty and honest witnesses sign `ReplayWitness` only after running
the committed deterministic kernel. It does not make hidden state public or
prove that a witness implementation is honest.

The current encounter remains deliberately one-dimensional. The base kernel covers
multiple attacks, player HP, death, clear, transcript-order independence, and
survivor loot. A phase-separated raid kernel additionally covers authenticated
player attacks, cooldown violations, boss HP, and deterministic boss clear. It
does not yet cover overlapping mechanics or hidden-state simulation. The associated game-design constraints
are documented in
[`telegraph-game-design-ja.md`](./telegraph-game-design-ja.md).

Timeout and missing approvals are not cheat evidence. They leave economic
results pending until the authority fallback resolves them.

### Irregular open-world encounters

`src/x/game_audit/open_world/` integrates the witness and central-replay
capabilities with a delayed probabilistic audit. The protocol deliberately
uses two authority-verified epoch checkpoints:

1. the plan commits the game manifest, sampling fraction, hidden seed, and a
   canonical registration-observer roster/fault-policy manifest;
2. encounter checkpoints branch from the exact plan digest;
3. `n - f` observers can sign the exact `(plan, slot, encounter digest)`
   registration independently of replay correctness;
4. each encounter checkpoint epoch is its registration slot, and the close
   manifest commits the exact registered count;
5. the close checkpoint commits both a Merkle root of tagged `(slot, digest)`
   leaves and an authenticated-map root of `slot -> digest` registrations;
6. the seed is revealed only after those roots are fixed.

`RevealedOpenWorldAuditEpoch` is private-field. It is issued only when the plan
and close checkpoint have the same authority, session, derived seal manifest,
consecutive epochs, and exact parent relation, and the seed opens the plan
commitment. The encounter gate then verifies the tagged encounter digest's
Merkle inclusion, proof index, and proof count before deriving its deterministic
sample decision.

The proof-checked routing policy sends samples, signed challenges, all
`HighValue` outcomes, and unwitnessed `Durable`/`Tradable` outcomes to central
replay. An unsampled and unchallenged matching witness certificate can finalize
ordinary outcomes without central replay. An unwitnessed `Ephemeral` outcome is
only provisional. A supplied but mismatching central replay capability rejects
the encounter rather than silently falling back to the peer path.

This reduces expensive game simulation replay, not envelope authentication.
The current prototype still uses one authority key for plan, close, and
encounter checkpoints. It can now issue an opaque conflict capability when a
signed encounter slot is beyond the committed registry count, or when a valid
Merkle proof includes another digest at the same slot, or when a valid
authenticated-map non-membership proof shows that an in-range signed slot is
absent. A malformed, missing, cross-slot, or ambiguous pair of proofs never
creates an accusation. A plan-bound `n - f` observer certificate can replace
the authority-signed encounter as evidence that a registration was seen, so an
authority cannot avoid the conflict merely by withholding its encounter
checkpoint after observers accepted the request. Registration observers do not
assert replay correctness. Dynamic zone assignment, a production durable
signing-store adapter, delegated referee keys, and append-only transparency
remain future work.

The public signing path now reserves `(plan, slot, digest)` through an
`OpenWorldObserverSigningStore` before calling the signer. Store failure and a
different previously reserved digest return without emitting a signature.
Exact retry signs the same statement again; signature-byte identity is not part
of the production contract. The bundled authenticated in-memory store is a
sequential compare-and-set reference adapter. Production implementations must
make reservation atomic and durable before returning success. Restore can
require an exact trusted `(observer id, signer key, root, size)` anchor, which
rejects empty or foreign snapshots. A domain-separated authority checkpoint can
now publish a key-unique authenticated map from `(observer id, signer key)` to
`(root, size)`. A valid membership proof opens an opaque published-anchor
capability that the restore API consumes. A plain Merkle list was rejected
because one batch could include both old and new values for the same key. Peer
head comparison now detects same-epoch different digests and next-epoch wrong
parents once two authenticated branches meet. Duplicates are idempotent, while
gaps and unlinked stale heads do not create accusations. Network fanout,
durable head history, and a witness quorum are still required to ensure that
partitioned clients eventually exchange heads.

An ordered gap response can be validated as an atomic batch. Every step is
classified against a temporary planned head; only a completely valid chain is
committed. A wrong parent, same-epoch fork, second gap, stale entry, or foreign
boundary rolls back all planned advances. This is process-local atomicity, not
a substitute for a production database transaction.

The opaque publication capability is not sent over the network. The public
wire envelope instead contains a signed checkpoint, the claimed anchor, and
its authenticated-map membership proof. A receiver rechecks the expected
authority signature and checkpoint digest, then the log session, domain
manifest, exact key/value, and membership path before reconstructing the
capability. A bounded gap request is pinned to the receiver's authenticated
`(session, publisher, epoch, checkpoint digest)` cursor. The reference
in-memory transport indexes this cursor and returns a contiguous page even when
its input was unordered. Recovery opens the whole page before the atomic batch
merge; an invalid envelope, oversized response, or ambiguous source leaves the
tracker unchanged. Source ambiguity is not itself authority-fork evidence
because the candidates have not yet been independently authenticated.
Production network I/O, retry/backpressure, multi-peer selection, and durable
commit remain future work.

The byte boundary is now a versioned deterministic CBOR codec. It checks total
bytes before parsing, preflights every declared CBOR length/count against the
actual remaining input, requires byte-identical deterministic re-encoding, and
then enforces text, proof-depth, and page-item budgets. This preflight closes a
concrete short-input/huge-declared-length allocation counterexample found while
reviewing the external CBOR decoder. See
[`game-audit-wire-ja.md`](./game-audit-wire-ja.md) for the v1 field order,
limits, and measurements.

The complete threat model and game-design implications are in
[`open-world-audit-ja.md`](./open-world-audit-ja.md).

## Verification boundary

Generic checkpoint cadence/head policy is in `src/audit/`; game-specific
executable policy is in `src/x/game_audit/audit/checkpoint.mbt`, with logical
predicates and lemmas in `src/x/game_audit/audit/checkpoint.mbtp`.
Authenticated checkpoint envelopes and their canonical serialization are in
`src/x/game_audit/checkpoint/`. Roster-bound signature collection is in
`src/audit/quorum/`; game replay/finality adaptation is in
`src/x/game_audit/attestation/`. Run:

```sh
just test-game-pkg audit
just test-game-pkg checkpoint
just test-game-pkg attestation
moon test src/audit/merkle
just test-game-pkg market
moon test src/audit/authmap
just test-game-pkg replay
just test-game-pkg inventory
just test-game-pkg open_world
just test-game-pkg wire
just test-game-pkg crypto
just prove-game-audit
just prove-audit-core
```

The Nix development shell pins Why3 1.7.2 and Z3 4.8.17. The generic audit
packages prove 39 goals for nested cadence/retention, localization precision,
finality arithmetic, exact-next head classification, late-event admission,
trusted epoch closure, exact success-ACK admission, and checkpoint delivery
authentication, plus vote-merge idempotence, commutativity, associativity, and
equivocation absorption.
The game audit package
proves 161 additional goals that establish:

- a finalized checkpoint requires an authority acceptance;
- a challenged checkpoint can finalize only after a matching replay;
- checkpoint replay evidence requires capability possession, exact checkpoint
  digest equality, and exact verified authority identity; absence or either
  mismatch fails closed;
- a replay-witness policy requires `n > 3f` and uses `n - f` approvals;
- an open-world central replay requires the trusted job boundary, an external
  transparency publication, authenticated plan and seal/seed, observer
  registration quorum, encounter inclusion, and exact replay match simultaneously;
- every valid witness quorum exceeds `f`, and two valid quorums intersect in
  more than `f` roster positions;
- invalid witness policies and under-quorum certificates fail closed;
- observer-anchor publication requires valid identity, log session, domain
  manifest, and authenticated-map membership;
- an anchor-log head advances only to the exact next epoch and parent; foreign
  boundaries and gaps do not manufacture fork accusations;
- an open-world registration-observer policy requires `n > 3f`, uses `n - f`
  approvals, has quorum intersection beyond `f`, and fails closed otherwise;
- an existing observer `(plan, slot)` never produces a second new signature;
  exact retries reuse the prior observation and conflicting digests reject;
- open-world peer acceptance requires a matching witness certificate and no
  sample, challenge, or mandatory-central outcome;
- samples and signed challenges require central replay, central mismatch is
  rejected, and an unwitnessed economic outcome cannot become provisional;
- seal truncation requires a matching encounter boundary and an out-of-range
  signed slot;
- seal substitution requires an in-range slot and an exact valid inclusion for
  a different digest; wrong boundaries and missing proofs cannot accuse;
- seal missing-slot conflict requires an in-range slot and an exact valid
  non-membership proof; invalid or ambiguous evidence cannot accuse;
- marketplace acceptance requires finalization, inclusion, and clean ancestry;
- executable approval counting and decisions match their logic-side models;
- participant vote merge is idempotent, commutative, and associative;
- an observed challenge cannot merge back into a clean approval;
- equivocation is absorbing;
- zero and oversized thresholds cannot create participant quorum;
- an authorized ownership transfer requires all six declared preconditions;
- absence of any one transfer precondition rejects the transition;
- an accepted source capability requires both session and digest equality;
- either a session or digest mismatch rejects the source;
- replay capability issuance requires authenticated source, matching session,
  valid effect, present manifest, and kernel acceptance;
- absence of any replay issuance condition rejects the effect;
- an accepted telegraphed dodge requires valid telegraph and player evidence,
  causal binding, a valid reaction window, a bounded authority receipt, and
  legal movement;
- absence of any one dodge condition rejects the input;
- an accepted reaction tick is after the minimum reaction floor and before
  resolution;
- an accepted authority receipt is not earlier than the client tick and stays
  within the configured maximum backdate; early, future, and excessive claims
  are rejected;
- encounter HP never becomes negative, death is absorbing, and a miss preserves
  valid HP;
- encounter clear requires a complete schedule and at least one survivor;
- encounter loot requires both a cleared encounter and a living player;
- wire admission requires byte, canonical-encoding, version, shape, text,
  proof, and item-count conditions; any failed condition rejects.

The signed checkpoint binds `session_id`, epoch, previous checkpoint, session
manifest, event root, public state root, item delta root, and an optional hidden
state commitment into a versioned length-prefixed serialization. Verification
fails closed on a wrong authority key, a recomputed hash mismatch, or an invalid
signature.

The proof does not establish signature unforgeability, hash collision
resistance, determinism or semantic correctness of a concrete game kernel, or
cryptographic correctness of the Merkle implementation. It proves the Boolean
issuance boundary, while executable tests cover the sealed reference kernel's
payload, author, session, effect, and manifest bindings. The checkpoint and BFT
packages use FNV and a mock HMAC-like signer as deterministic test doubles.
An additional `experimental_crypto@0.0.2` SHA-256/Ed25519 adapter passes known
vectors and measures realistic pure-MoonBit cost, but its upstream explicitly
states that it is unaudited and not production-grade. MoonBit verification
currently reasons over mathematical integers, so runtime overflow also remains
outside this proof boundary.

## Complexity and measurement

The collector validates one attestation with expected `O(1)` roster lookups and
signature/hash work proportional to its short serialized record. Exporting the
approval vector is `O(n)`. The quorum path then counts approvals in `O(n)`.
Authority rejection, an unresolved challenge, and a matching replay return in
`O(1)`. Converting an opaque replay match into decision evidence adds one
`O(1)` digest comparison. The marketplace policy itself is `O(1)` and Merkle inclusion is
`O(log items)`. Receipt batch validation and Merkle construction are `O(items)`
in time and memory. Proof size is `O(log items)`.

Reference replay checks are linear in the short canonical effect payload and
otherwise `O(1)`. Inventory indexes replay capabilities once, then performs
expected `O(1)` exact source/effect lookups before each authenticated-map
update. A checkpoint commit additionally compares the plan's single replay
manifest with its signed `manifest_digest`.

The authenticated inventory map is a deterministic persistent treap: keys are
ordered lexicographically and priorities are derived from tagged key hashes.
Its root is independent of insertion order. Forking a plan is `O(1)`, and one
lookup, update, or membership proof is expected `O(log assets)`; committing a
plan applies `O(changed assets)` record updates. A plan therefore costs expected
`O(changed assets * log assets)` instead of cloning all records. This is an
expected bound, not a worst-case bound: the current FNV test hash permits an
adversary to bias priorities, so production must use an appropriate keyed or
cryptographic priority hash (or a worst-case-balanced authenticated tree).

For an encounter with `a` attacks, `p` players, and `e` total evidence records,
the replay performs expected `O(a * p + e)` map work. Canonicalizing the attack
plan costs `O(a log a)` and constructing the exact transcript root costs
`O((a + e) log(a + e))` because digests are sorted before Merkle construction.
The central PvE verifier additionally decodes `O(bundle bytes)`, authenticates
`a + 2e` signed events, and builds the causal digest map in expected `O(a + e)`.
Its input allocation is capped at 1 MiB before cryptography. A 2,585-byte,
one-player/one-attack/one-dodge real-crypto bundle took 23 ms inside local
workerd's Durable Object; Queue delivery took about 1.04 seconds because the
single-message batch timeout is one second.

For an open-world audit epoch with `m` eligible encounters, building the close
tree is `O(m)` and one eligibility proof is `O(log m)` in size and verification
time. Building the authenticated slot registry is expected `O(m log m)` with
the current treap. Sampling hashes one short tagged record and scans the
fixed-length digest. Only the selected/challenged/high-value/unwitnessed-economic
subset incurs the game-specific central replay cost.

For `n` registration observers, plan-manifest canonicalization is
`O(n log n)` and receipt verification/counting is `O(n)`. This work can run at
the participating peers or zone edge; the central investigation path receives
only the opaque certificate and proof-bearing seal conflict.

For `s` records in one observer's authenticated signing ledger, a new record is
expected `O(log s)` because it updates the treap commitment. Exact retries and
conflict rejection perform a map lookup and do not update the authenticated
root. Anchor comparison is `O(1)` because the root and size are cached by the
reference authenticated map. These bounds exclude durable storage and remote
anchor I/O. Publishing `a` observer anchors builds the current authenticated
treap in expected `O(a log a)`; verifying one publication is expected
`O(log a)`. Constructing the reference gap source indexes `h` stored envelopes
in expected `O(h)` map work. Fetching and merging a `k`-head page is expected
`O(k)` cursor lookup plus `O(k log a)` receiver-side membership verification;
checkpoint hashing and signature verification run once per head.

Truncation evidence is checked in `O(1)`. Slot-substitution evidence verifies
one Merkle path in `O(log m)`. Missing-slot evidence verifies one authenticated
search path in expected `O(log m)`. These checks route only proof-bearing
conflicts to an authority investigation queue and do not trigger game replay by
themselves.

Example measurement on 2026-08-03, Apple M5 arm64, MoonBit
`0.1.20260724`, using `just bench-game-pkg audit`:

| Benchmark batch | Before early return | After early return |
| --- | ---: | ---: |
| 8-player quorum × 1,000 | 28.67 µs | 28.38 µs |
| 64-witness quorum × 1,000 | 82.73 µs | 87.50 µs |
| 64-witness authority replay × 1,000 | 81.53 µs | 17.83 µs |
| Marketplace gate × 10,000 | 164.05 µs | 208.32 µs |

The quorum and marketplace differences are within ordinary benchmark noise.
The replay fallback avoids the 64-entry scan and was about 4.2× faster in this
run.

Checkpoint envelope measurement on the same machine and toolchain:

| Benchmark batch | Mean |
| --- | ---: |
| Sign 1,000 checkpoints | 867.46 µs |
| Verify 1,000 checkpoints | 865.90 µs |

These numbers measure the canonical serialization and deterministic test
doubles, not production SHA-256/Ed25519 performance.

Authenticated event-path measurement after adding session binding and the
`AuthenticatedEvent` capability:

| Benchmark batch | Mean |
| --- | ---: |
| Sign 1,000 events | 1.06 ms |
| Deliver 1,000 linear events | 1.83 ms |
| Deliver 1,000 independent events | 1.53 ms |
| Flush 100 causally buffered events | 198.54 µs |

Participant evidence measurement using the same deterministic test doubles:

| Benchmark batch | Mean |
| --- | ---: |
| Sign 1,000 participant approvals | 740.10 µs |
| Verify and collect 8 approvals | 7.45 µs |
| Verify and collect 64 approvals | 57.00 µs |
| Build and certify 8 replay witnesses, `f=2` | 8.93 µs |
| Build and certify 64 replay witnesses, `f=21` | 67.40 µs |

The replay-witness benchmark includes canonical manifest comparison, all mock
signature checks, vote merge, approval counting, and certificate issuance. It
does not include the game replay that honest witnesses must perform first.

Merkle and marketplace measurement using deterministic test doubles:

| Benchmark batch | Mean |
| --- | ---: |
| Build 1,000-leaf Merkle tree | 800.67 µs |
| Verify 1,000 proofs in 1,024 leaves | 4.78 ms |
| Validate and build 1,000 item receipts | 2.35 ms |
| Verify 1,000 marketplace listings with replay capability | 7.34 ms |

The two verification batches correspond to roughly 4.78 µs and 7.34 µs per
proof/listing respectively. They are not production cryptography benchmarks.

Reference replay capability measurement:

| Benchmark batch | Mean |
| --- | ---: |
| Replay 1,000 canonical asset effects | 916.18 µs |
| Match 1,000 replay capabilities | 85.04 µs |

This corresponds to roughly 0.92 µs per reference-kernel replay and 0.085 µs
per capability match. A real combat kernel will have a different cost profile.

Open-world routing measurement using the same FNV/mock boundary:

| Benchmark batch | Mean |
| --- | ---: |
| Select 1,000 delayed audit samples | 666.31 µs |
| Evaluate 1,000 Merkle-eligible provisional encounters | 3.01 ms |
| Reject 1,000 false seal-conflict accusations | 1.16 ms |
| Certify 1,000 four-observer registrations (`f=1`) | 6.01 ms |
| Detect 1,000 observed omissions in 10,000 slots | 28.36 ms |
| Sign 1,000 new observer-ledger registrations | 15.10 ms |
| Reject 1,000 conflicting observer signatures | 561.21 µs |
| Validate 1,000 trusted observer signing anchors | 660.84 µs |
| Reject 1,000 rolled-back observer signing stores | 524.94 µs |
| Verify 1,000 publications in a 1,024-observer anchor map | 12.45 ms |
| Advance 1,000 authenticated anchor heads | 141.55 µs |
| Recover 1,000 anchor-head gaps as one atomic batch | 231.21 µs |
| Fetch, authenticate, and recover 1,000 wire anchor heads | 4.42 ms |
| Detect 1,000 same-epoch anchor-checkpoint forks | 119.79 µs |

The second batch includes a single-leaf inclusion proof, checkpoint/capability
comparisons, and construction of an empty participant-evidence collector. It
does not include production cryptography, network/storage I/O, or central game
replay. FNV produced a real collision between different one-leaf test payloads
while this path was developed, reinforcing that it is only a deterministic test
double and must not be used for production security.

The 4.42 ms wire-recovery measurement was added on 2026-08-04. Unlike the
231.21 µs batch-only measurement, it includes indexed source lookup, checkpoint
rehashing, 1,000 mock signature checks, membership-proof checks, capability
construction, and the atomic merge. It still excludes serialization, sockets,
durable storage, and production cryptography.

Versioned wire and experimental-crypto measurement on the same machine:

| Benchmark | Mean |
| --- | ---: |
| Encode 1,000 sixteen-step CBOR envelopes | 7.50 ms |
| Preflight + decode 1,000 sixteen-step CBOR envelopes | 20.23 ms |
| Decode one 64-envelope gap page | 1.74 ms |
| SHA-256 1,000 short checkpoint records | 1.52 ms |
| Experimental Ed25519 sign | 3.99 ms |
| Experimental Ed25519 verify | 2.36 ms |
| Decode and capability-open one real-crypto envelope | 2.29 ms |

A single-leaf mock envelope is 400 bytes; the SHA-256/Ed25519 integration
envelope is 1,064 bytes. Ed25519 dominates the pure-MoonBit path, so checkpoint
frequency, duplicate-verification caching, verification distribution, and an
audited faster backend are deployment variables rather than constants hidden
by the old mock benchmark.

Checkpointed telegraphed-attack replay measurement:

| Benchmark batch | Mean |
| --- | ---: |
| Replay 1,000 checkpointed 8-player attacks | 59.87 ms |
| Replay 100 checkpointed 64-player attacks | 44.67 ms |

This is about 59.9 µs per 8-player attack and 446.7 µs per 64-player attack.
The path recomputes the roster-bound manifest and sorted transcript Merkle root
on every replay. The measured growth is consistent with linear work in players
and evidence, but it is an empirical observation rather than an asymptotic
proof.

Multi-attack encounter preparation, with eight attacks and one valid signed
dodge plus authority receipt per player per attack:

| Benchmark batch | Mean |
| --- | ---: |
| Prepare 100 × 8-player, 8-attack encounters | 46.59 ms |
| Prepare 10 × 64-player, 8-attack encounters | 33.73 ms |

This is about 465.9 µs per 8-player encounter and 3.373 ms per 64-player
encounter. It includes plan sorting, all dodge checks, HP transitions, state
serialization, and transcript Merkle-root construction, but excludes event
signature verification performed before replay and uses FNV/mock crypto.

Authenticated-map measurement using the FNV test hash:

| Benchmark batch | Mean |
| --- | ---: |
| Insert 10,000 entries into an empty map | 145.73 ms |
| Update 1,000 entries in a 10,000-entry fork | 18.90 ms |
| Verify 1,000 membership proofs in 10,000 entries | 28.86 ms |
| Verify 1,000 non-membership proofs in 10,000 entries | 13.90 ms |

Inventory planning and proof measurement:

| Benchmark batch | Mean |
| --- | ---: |
| Plan 1,000 replay-authorized asset creations | 19.20 ms |
| Plan 1,000 replay-authorized transfers in 10,000 assets | 39.72 ms |
| Plan 1 replay-authorized transfer in 1,000 assets | 27.27 µs |
| Plan 1 replay-authorized transfer in 10,000 assets | 53.18 µs |
| Verify 1,000 inventory proofs in 10,000 assets | 48.58 ms |

The one-transfer result grew by about 2.0× when the committed inventory grew
10×, which is consistent with traversing a tree path rather than copying every
asset. This is an empirical observation from one implementation and machine,
not an asymptotic proof. The inventory and authenticated-map measurements also
exclude disk I/O and use string-heavy canonical records plus FNV, not production
cryptography.

## Contract reconciliation ledger

| Claim | Authority | Executable evidence | Status |
| --- | --- | --- | --- |
| Finalized implies authority acceptance | MoonBit prove contract | `finalized_requires_authority` | Proven |
| Challenge needs matching replay to finalize | MoonBit prove contract | `challenged_finalization_requires_replay` | Proven |
| Only clean, included, finalized items enter the market | MoonBit prove contract | `market_acceptance_is_fail_closed` | Proven |
| Event author equals the manifest key owner | BFT adapter contract | roster mismatch tests | Tested |
| Event signature is bound to one session | BFT adapter contract | cross-session replay test and `event-v2` serialization | Tested |
| Event dependency IDs match authenticated hashes | BFT adapter contract | direct and buffered mismatch tests | Tested |
| Raw or rejected events cannot mint an accepted-event capability | BFT capability contract | private fields plus accepted/buffered/rejected delivery tests | Tested |
| Signed checkpoint binds every declared root | checkpoint envelope contract | tamper tests | Tested |
| Only roster-bound valid signatures affect approvals/challenges | attestation collector contract | impersonation, tamper, and target tests | Tested |
| Checkpoint approval signatures cannot be reused as replay-witness claims | attestation domain contract | `attestation-v2` purpose binding and cross-purpose rejection tests | Tested |
| Vote aggregation converges independent of order and duplicates | participant vote proof contract | semilattice lemmas and integration tests | Proven |
| Empty or invalid threshold cannot manufacture quorum | audit policy contract | threshold lemmas and regression test | Proven |
| Marketplace API requires a matching verified and finalized checkpoint | finalization capability contract | mismatch and unresolved-challenge tests | Tested |
| Receipt is included under the signed `asset_delta_root` | Merkle/market contract | all-index, malformed-proof, and cross-checkpoint tests | Tested |
| Listed seller owns the committed receipt | market contract | wrong-owner regression test | Tested |
| Asset creation is unique across loaded checkpoint ancestry | inventory accumulator contract | duplicate creation across committed checkpoints is rejected | Tested |
| Inventory root is independent of creation order | authenticated-map contract | forward/reverse/shuffled map and receipt-order tests | Tested |
| Finalized checkpoint binds the atomic inventory transition | inventory commit contract | session, parent, epoch, delta, state-root, stale-plan, and atomicity tests | Tested |
| Transfer authorization fails closed on each declared precondition | MoonBit prove contract | transfer predicate and seven fail-closed lemmas | Proven |
| Source capability must match both session and digest | MoonBit prove contract | exact-match and two mismatch lemmas | Proven |
| Replay capability issuance requires every trust condition | MoonBit prove contract | issuance theorem and five fail-closed lemmas | Proven |
| Arbitrary consumers cannot implement an allow-all replay kernel | replay API contract | sealed `AssetReplayKernel` generated interface | Tested |
| Reference kernel binds its manifest to version and effect-author key | replay kernel contract | author-manifest and non-author rejection tests | Tested |
| Dungeon checkpoint signer equals the configured authority | replay/checkpoint contract | cross-authority checkpoint rejection test | Tested |
| Replayed effect exactly matches canonical event payload | replay kernel contract | create, transfer, mismatched-effect, invalid-effect tests | Tested |
| Inventory and marketplace require checkpoint/kernel manifest equality | replay/checkpoint contract | mixed-plan, commit-mismatch, and listing-mismatch tests | Tested |
| Later ownership transfers preserve creation provenance | inventory state contract | origin and last-event assertions after transfer | Tested |
| Current-owner listing is included under signed `public_state_root` | inventory/market contract | owner, record, root, and proof-tamper tests | Tested |
| Witness-certified current-owner proof binds authority checkpoint, game manifest, origin receipt, owner/version, and inventory root | central inventory-listing contract | canonical wire, quorum, stale-owner, origin, version/root tamper tests | Tested |
| Worker per-asset inventory head advances only through an exact parent with increasing epoch and owner/version consistency | MoonBit proof + DO transaction contract | 64-case predicate test, wrong-parent/version regression workerd test | Proven + Tested locally |
| Inventory survives process restart without trusting a snapshot | storage adapter contract | Worker per-asset head survives in SQLite; player-local treap reconstruction remains | Partially met |
| Creation and transfer source events are replay-authorized | replay capability contract | missing, wrong-session, wrong-effect, and wrong-manifest tests | Tested |
| Authority-emitted canonical effect is accepted only from configured key | reference replay-kernel contract | author-key and exact-payload tests | Tested |
| Minimal telegraphed PvE survival entitles a deterministic loot effect | dungeon replay contract | timing, evidence, causality, equivocation, omission, and loot tests | Tested |
| Multi-attack encounter carries position/HP and derives clear from the complete plan | encounter replay contract | order, omission, prior-position, death, and clear tests | Tested |
| Encounter loot requires clear and a living player | MoonBit prove contract | fail-closed loot lemmas and sealed encounter-kernel test | Proven |
| Encounter checkpoint binds replay-derived manifest, event root, and public-state root | encounter/checkpoint contract | missing attack and forged-state tests | Tested |
| Replay-witness policy is Byzantine-safe within the declared fault assumption | MoonBit prove contract | `n > 3f`, `n-f` quorum, honest-intersection and fail-closed lemmas | Proven |
| Replay-witness certificate binds game manifest, roster, fault bound, checkpoint, and independent referee | witness capability contract | manifest-order, purpose, overlap, cross-checkpoint, and cross-referee tests | Tested |
| Public PvP replay is independent of transcript delivery order | PvP replay contract | simultaneous wipe, moving target, roster order, and equivocation tests | Tested |
| Positive PvP score requires an enemy-caused alive-to-defeated transition | MoonBit prove contract | score gate and fail-closed lemmas | Proven |
| Honest PvP witness signing requires an exact replay/checkpoint/referee match | PvP session capability contract | end-to-end `n-f`, cross-checkpoint, and cross-referee tests | Tested boundary |
| Open-world peer finality excludes samples, challenges, and mandatory-central outcomes | MoonBit prove contract | seven routing lemmas and peer-finalization integration test | Proven + Tested |
| Audit seed cannot select an encounter outside the pre-reveal eligible set | open-world capability contract | plan/close binding and false-inclusion rejection tests | Tested |
| Open-world authority, parent epoch, evidence, witness, and central replay cannot cross checkpoints | capability contract | cross-boundary and genuine replay integration tests | Tested |
| Seal conflict capability requires truncation, exact-slot substitution, or exact in-range non-membership | MoonBit + capability contract | conflict-policy proof goals and truncation/substitution/missing-slot/tamper tests | Proven + Tested |
| Registration-observer certificate requires a plan-bound `n > 3f`, `n-f` policy | MoonBit + observer capability contract | policy/intersection proofs and roster/plan/signature/under-quorum tests | Proven + Tested |
| Observer certificate plus exact seal proof can expose an authority-hidden registration | observer/seal capability contract | missing-slot, foreign-plan, and tampered-proof tests | Tested + Proven boundary |
| Observer signing decision cannot select a second digest for an existing plan/slot | MoonBit pure decision contract | never-sign-second proof | Proven |
| Signing-store reservation precedes signature emission | signing-store API contract | unavailable-store call-count and shared-store conflict tests | Tested for reference/control flow; production durability assumed |
| Trusted signing anchor rejects rollback/foreign restore | restore contract | exact-match, empty-store, and foreign-observer tests | Tested |
| Published anchor requires valid identity, log session, domain manifest, and state membership | MoonBit + checkpoint capability contract | six proof goals; invalid/session/manifest/substitution tests | Proven + Tested |
| One anchor batch has only one value per observer/key | authenticated-map contract | same-key replacement leaves size one and invalidates the old value | Tested |
| Anchor head advances only through the exact next parent | MoonBit + head-tracker contract | seven proof goals; advance/duplicate/gap/stale/boundary tests | Proven + Tested |
| Two authenticated branches produce fork evidence when they meet | head-tracker contract | same-epoch and wrong-parent regression tests | Tested |
| A failed gap-recovery batch commits no prefix | in-memory transaction contract | parent-fork/gap/foreign/same-epoch rollback tests | Tested; durable DB transaction unmet |
| Wire gap recovery authenticates every envelope before committing any head | transport/capability contract | authority/signature/membership tamper, bounded-response, pagination, and atomic rollback tests | Tested for in-memory transport; production network adapter unmet |
| Wire bytes fail closed on every declared syntax/budget condition | MoonBit + codec contract | nine proof goals; round-trip/noncanonical/version/truncation/oversize/path/item/declared-length tests | Proven + Tested |
| Experimental SHA-256/Ed25519 adapters match standard vectors | adapter interoperability contract | SHA-256 `abc`, RFC 8032 empty-message, real-envelope round trip | Tested; upstream audit/constant-time unmet |
| All partitioned clients eventually exchange one append-only head | deployment/liveness contract | no production gossip transport or witness quorum | Unmet |
| Full PvE/PvP game state actually entitles every asset effect | game-mode kernel contract | phase-separated PvE boss HP/player attack/cooldown and public PvP cooldown/capture objective are tested; projectile/visibility, central bundle v2, and raid loot binding remain | Partially met |
| Hashes/signatures are production-reviewed and side-channel safe | deployment assumption | FNV/mock plus unaudited experimental SHA-256/Ed25519 adapters | Unmet |
| Checkpoint replay fallback is derived from a complete replay transcript | replay/attestation capability contract | private `CheckpointReplayMatch`, exact digest/authority gate, foreign-capability regression tests | Tested + Proven boundary |
| Queue delivery alone cannot claim deterministic replay success | central replay artifact contract | anchor-only awaits transcript; verification requires anchor, transcript, checkpoint link, complete kernel, and matching result | Proven + Tested bridge |
| A PvE Queue job reaches verified only after all signed events and all game-checkpoint roots match | central replay/wire contract | bounded bundle tests, real-crypto bridge test, workerd Queue integration | Tested locally + remote benchmark |
| A PvP Queue job reaches verified only after all signed events, all checkpoint roots, and an `n-f` witness certificate match | central replay/wire contract | bounded bundle tests, real-crypto bridge test, workerd Queue integration | Tested locally + remote benchmark |
| An open-world Queue job reaches verified only after transparency/plan/seal/encounter authentication, two publication proofs, delayed seed reveal, `n-f` registration observation, eligible inclusion, and PvE replay | central replay/wire contract | bounded bundle tests, real-crypto bridge test, workerd Queue integration | Tested locally + remote benchmark |
| The open-world encounter checkpoint is included in the signed eligible seal | capability contract | Merkle inclusion and trusted-boundary regression tests | Tested locally |
| The audit plan/seal is included in an independent publisher's transparency checkpoint | deployment link contract | exact authenticated-map memberships, trusted head digest, real-crypto/workerd tests | Tested locally |

## Next integration

The checkpoint, session-bound event capability, sealed replay-effect
capability, participant-evidence, Merkle receipt, and in-memory authenticated
inventory slices are now present. The remaining integration work is:

1. carry the phase-separated raid boss HP/player attack/cooldown fields through
   canonical wire, central replay, and checkpoint-bound loot;
2. extend the implemented public-state PvP cooldown/objective kernel with
   projectile travel and mode-specific visibility rules, then migrate wire/manifest v2;
3. anchor the implemented open-world plan/seal digests in an external
   transparency log, and collect the already-verifiable PvP/open-world statements from
   remote peers with retry and appeal-window retention;
4. implement a crash-safe concurrent `OpenWorldObserverSigningStore`, persist
   the now-transportable anchor-checkpoint envelopes and heads, add production
   gossip/retry/multi-peer adapters, then extend the fixed observer certificate
   with zone/epoch assignment and delegated referee keys;
5. replace the test doubles/experimental adapter with an audited production
   hash and signature backend;
6. bind the BFT session context to the exact authenticated manifest version,
   in addition to requiring a globally unique session id;
7. persist checkpoints, inventory records, treap nodes, proofs, and evidence
   alerts transactionally in each player's local-first database, reconstruct
   the authenticated root on restart, and batch multiple asset proofs under one
   inventory checkpoint instead of only the Worker prototype's per-asset heads;
8. define snapshot/pruning and checkpoint-recovery rules so old event logs can
   be discarded without trusting an unauthenticated local snapshot.
