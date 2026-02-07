# mizchi/converge

EG-Walker inspired Local-First DB Sync Engine in MoonBit.

EG-Walker にインスパイアされた MoonBit 製ローカルファースト DB 同期エンジン。

## Two-Tier Architecture / 2層アーキテクチャ

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

**Durable Layer** は因果イベントグラフに全操作を Lamport タイムスタンプ付きで記録する。完全な履歴と決定論的な競合解決が必要な低頻度操作に最適。

**Ephemeral Layer** uses simple Last-Writer-Wins registers organized by namespace. No event graph overhead — designed for high-frequency, short-lived state where only the latest value matters.

**Ephemeral Layer** は名前空間ごとの LWW レジスタを使用。イベントグラフのオーバーヘッドなし。最新値のみが重要な高頻度・短命な状態向け。

## Package Structure / パッケージ構成

```
src/
├── types/       Core type definitions (PeerId, EventId, Value, RowOp, Event, EventRun)
│                コア型定義
├── clock/       Lamport logical clock / Lamport 論理クロック
├── graph/       Event DAG with frontier tracking and LCA computation
│                フロンティア追跡と LCA 計算付きイベント DAG
├── oplog/       Operation log with RLE compression / RLE 圧縮付き操作ログ
├── merge/       EG-Walker conflict resolution (LWW per column)
│                EG-Walker 競合解決（列単位 LWW）
├── doc/         CrdtDoc — high-level Durable Layer API
│                CrdtDoc — Durable Layer の高レベル API
├── ephemeral/   EphemeralStore — LWW Register Map (Ephemeral Layer)
│                EphemeralStore — LWW レジスタマップ（Ephemeral Layer）
├── bft/         BFT-CRDT adapter (Byzantine fault detection)
│                BFT-CRDT アダプター（ビザンチン障害検出）
├── sync/        Sync protocol (PushRequest, PullRequest, PullResponse)
│                同期プロトコル
├── topology/    Network topology simulations (Star, Gossip, Mesh, etc.)
│                ネットワークトポロジシミュレーション
├── wasm/        WASM/JS exports for both layers
│                両レイヤーの WASM/JS エクスポート
└── e2e/         End-to-end integration tests / E2E 統合テスト
```

## Build Targets / ビルドターゲット

```bash
moon build --target wasm-gc   # WASM-GC output
moon build --target js        # JavaScript output
moon test                     # Run all tests / 全テスト実行
```

## Usage Guide / 使い方

### Durable Layer (CrdtDoc)

For persistent, conflict-free data: / 永続的で競合のないデータ向け:

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

For transient, high-frequency state: / 一時的で高頻度な状態向け:

```
ephemeral_set(handle, ns, key, value_json, timestamp)
ephemeral_get(handle, ns, key)
ephemeral_get_all(handle, ns)
ephemeral_merge(handle, entries_json)
```

## BFT Layer (Byzantine Fault Tolerance)

Verification layer based on Kleppmann's "Making CRDTs Byzantine Fault Tolerant" (PaPoC 2022) for cheat detection in P2P environments. Sits on top of the existing Durable Layer as an adapter without modifying it.

P2P 環境でのチート検出のため、Kleppmann の "Making CRDTs Byzantine Fault Tolerant" (PaPoC 2022) に基づく検証レイヤー。既存の Durable Layer を変更せず、アダプターとして上に乗る設計。

```
[Application]
     |
[CrdtDoc]        <- unchanged / 変更なし
     |
[BFTAdapter]     <- validates before passing to CrdtDoc
     |               deliver() で検証後、CrdtDoc に渡す
[Transport]      <- unchanged / 変更なし
```

`BFTAdapter::deliver(signed_event)` validates each received `SignedEvent` through:

`BFTAdapter::deliver(signed_event)` は受信した `SignedEvent` に対し以下を順に検証する:

1. **Hash integrity** — Re-serialize and recompute hash; reject on mismatch / イベント内容を再シリアライズしてハッシュを再計算、不一致なら拒否
2. **Signature verification** — Verify signature against author's public key via `Verifier` trait / `Verifier` trait で author_key に対する署名を検証
3. **Equivocation detection** — Reject if same `(peer, counter)` arrives with a different digest / 同一 `(peer, counter)` に異なる digest が来た場合拒否
4. **Causal delivery** — Buffer events with missing dependencies; flush when deps arrive / 依存する digest が未到着の場合バッファリングし、到着次第フラッシュ

Crypto primitives are abstracted via `Hasher` / `Signer` / `Verifier` traits, allowing swappable implementations (FNV-1a + Mock for testing, SHA-256 + Ed25519 for production).

暗号プリミティブは `Hasher` / `Signer` / `Verifier` trait で抽象化されており、テスト用の FNV-1a + Mock 実装と、本番用の SHA-256 + Ed25519 実装を差し替え可能。

## Examples

- `examples/cf-do/` — Cloudflare Durable Objects with HTTP sync + WebSocket for ephemeral state
- `examples/deno-deploy/` — Deno Deploy with HTTP sync

## License

Apache-2.0
