# mizchi/converge

EG-Walker inspired Local-First DB Sync Engine in MoonBit.

[日本語版 / Japanese](README-ja.md)

## Two-Tier Architecture

```
┌──────────────────────────────────────────────────┐
│                   Application                    │
├───────────────────────┬──────────────────────────┤
│    Durable Layer      │    Ephemeral Layer        │
│    (CrdtDoc)          │    (EphemeralStore)        │
│                       │                           │
│  - Event Graph        │  - LWW Register Map       │
│  - Causal ordering    │  - Timestamp + PeerId     │
│  - RLE compressed     │  - No history             │
│  - Conflict-free      │  - Overwrite semantics    │
│    merge (EG-Walker)  │                           │
│                       │                           │
│  Use: DB CRUD,        │  Use: Cursors, presence,  │
│  document edits       │  player positions, typing │
│                       │  indicators               │
├───────────────────────┴──────────────────────────┤
│                 Sync Transport                    │
│  HTTP (push/pull)     │  WebSocket (broadcast)    │
└──────────────────────────────────────────────────┘
```

**Durable Layer** records every operation in a causal event graph with Lamport timestamps. Ideal for low-frequency operations that require full history and deterministic conflict resolution.

**Ephemeral Layer** uses simple Last-Writer-Wins registers organized by namespace. No event graph overhead — designed for high-frequency, short-lived state where only the latest value matters.

## Package Structure

```
src/
├── types/       Core type definitions (PeerId, EventId, Value, RowOp, Event, EventRun)
├── clock/       Lamport logical clock
├── graph/       Event DAG with frontier tracking and LCA computation
├── oplog/       Operation log with RLE compression
├── merge/       EG-Walker conflict resolution (LWW per column)
├── doc/         CrdtDoc — high-level Durable Layer API
├── ephemeral/   EphemeralStore — LWW Register Map (Ephemeral Layer)
├── sync/        Sync protocol (PushRequest, PullRequest, PullResponse)
├── topology/    Network topology simulations (Star, Gossip, Mesh, etc.)
├── wasm/        WASM/JS exports for both layers
└── e2e/         End-to-end integration tests
```

## Build Targets

```bash
moon build --target wasm-gc   # WASM-GC output
moon build --target js        # JavaScript output
moon test                     # Run all tests
```

## Usage Guide

### Durable Layer (CrdtDoc)

For persistent, conflict-free data:

```
create_doc(peer_id) -> handle
doc_insert(handle, tbl, row_id, values_json)
doc_update(handle, tbl, row_id, col, value_json)
doc_delete(handle, tbl, row_id)
doc_merge_remote(handle, events_json)
doc_get_pending(handle, known_json)
doc_sync_state(handle)
```

### Ephemeral Layer (EphemeralStore)

For transient, high-frequency state:

```
ephemeral_set(handle, ns, key, value_json, timestamp)
ephemeral_get(handle, ns, key)
ephemeral_get_all(handle, ns)
ephemeral_merge(handle, entries_json)
```

## Byzantine-aware verification

Signed-event authentication, equivocation detection, checkpoint audit
contracts, formal specifications, and the multiplayer game-audit prototype are
provided by the optional [`mizchi/bft`](https://github.com/mizchi/bft)
companion library. It depends on converge without changing CRDT merge semantics.

## Recommended Backend Adapters

| Platform | Layers | WASM Target | Sync | Example |
|----------|--------|-------------|------|---------|
| **Cloudflare Workers + Durable Objects** | Durable + Ephemeral | `js` | HTTP push/pull + WebSocket | `examples/cf-do/` |
| **Deno Deploy + Deno KV** | Durable | `wasm-gc` | HTTP push/pull | `examples/deno-deploy/` |

### Cloudflare Workers + Durable Objects (Recommended)

Best fit for production use. A single Durable Object instance per document co-locates CRDT state with persistent storage (DO Storage). HTTP endpoints handle push/pull sync for the Durable Layer, while WebSocket connections broadcast Ephemeral Layer state in real-time.

- Durable Layer: events persisted as `event:<counter>` keys in DO Storage, replayed on startup via `blockConcurrencyWhile()`
- Ephemeral Layer: WebSocket relay with LWW merge for presence, cursors, game state
- WASM loaded via dynamic import to work within CF Workers constraints

### Deno Deploy + Deno KV

Lightweight alternative using Deno KV for persistence. Supports multi-isolate concurrency with a catchUp mechanism that detects events written by other isolates. Uses WASM-GC target with JS String Builtins.

- Large EventRuns split into 50-op chunks (64KB KV value limit)
- Atomic batch writes with max 10 mutations per commit

### Additional Examples

- `examples/cf-do-game/` — Multiplayer Vampire Survivors-style browser demo (Ephemeral Layer + DO game loop, WebSocket)
- `examples/cf-signaling/` — P2P signaling relay with Star/Gossip topology modes (Ephemeral Layer only, WebSocket)

## License

Apache-2.0
