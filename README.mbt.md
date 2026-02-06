# mizchi/crdt_db

EG-Walker inspired Local-First DB Sync Engine in MoonBit.

## Two-Tier Architecture

```
┌─────────────────────────────────────────────────┐
│                   Application                    │
├────────────────────┬────────────────────────────┤
│   Durable Layer    │     Ephemeral Layer         │
│   (CrdtDoc)        │     (EphemeralStore)         │
│                    │                              │
│  - Event Graph     │  - LWW Register Map          │
│  - Causal ordering │  - Timestamp + PeerId        │
│  - RLE compressed  │  - No history                │
│  - Conflict-free   │  - Overwrite semantics        │
│    merge (EG-Walk) │                              │
│                    │                              │
│  Use: DB CRUD,     │  Use: Cursors, presence,     │
│  document edits    │  player positions, typing     │
│                    │  indicators                   │
├────────────────────┴────────────────────────────┤
│              Sync Transport                      │
│  HTTP (push/pull)  │  WebSocket (broadcast)       │
└─────────────────────────────────────────────────┘
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

## Examples

- `examples/cf-do/` — Cloudflare Durable Objects with HTTP sync + WebSocket for ephemeral state
- `examples/deno-deploy/` — Deno Deploy with HTTP sync

## License

Apache-2.0
