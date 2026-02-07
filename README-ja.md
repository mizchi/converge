# mizchi/converge

EG-Walker にインスパイアされた MoonBit 製ローカルファースト DB 同期エンジン。

[English](README.md)

## 2層アーキテクチャ

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

**Durable Layer** は因果イベントグラフに全操作を Lamport タイムスタンプ付きで記録する。完全な履歴と決定論的な競合解決が必要な低頻度操作に最適。

**Ephemeral Layer** は名前空間ごとの LWW レジスタを使用。イベントグラフのオーバーヘッドなし。最新値のみが重要な高頻度・短命な状態向け。

## パッケージ構成

```
src/
├── types/       コア型定義 (PeerId, EventId, Value, RowOp, Event, EventRun)
├── clock/       Lamport 論理クロック
├── graph/       フロンティア追跡と LCA 計算付きイベント DAG
├── oplog/       RLE 圧縮付き操作ログ
├── merge/       EG-Walker 競合解決（列単位 LWW）
├── doc/         CrdtDoc — Durable Layer の高レベル API
├── ephemeral/   EphemeralStore — LWW レジスタマップ（Ephemeral Layer）
├── bft/         BFT-CRDT アダプター（ビザンチン障害検出）
├── sync/        同期プロトコル (PushRequest, PullRequest, PullResponse)
├── topology/    ネットワークトポロジシミュレーション (Star, Gossip, Mesh 等)
├── wasm/        両レイヤーの WASM/JS エクスポート
└── e2e/         E2E 統合テスト
```

## ビルドターゲット

```bash
moon build --target wasm-gc   # WASM-GC 出力
moon build --target js        # JavaScript 出力
moon test                     # 全テスト実行
```

## 使い方

### Durable Layer (CrdtDoc)

永続的で競合のないデータ向け:

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

一時的で高頻度な状態向け:

```
ephemeral_set(handle, ns, key, value_json, timestamp)
ephemeral_get(handle, ns, key)
ephemeral_get_all(handle, ns)
ephemeral_merge(handle, entries_json)
```

## BFT Layer (Byzantine Fault Tolerance)

P2P 環境でのチート検出のため、Kleppmann の "Making CRDTs Byzantine Fault Tolerant" (PaPoC 2022) に基づく検証レイヤー。既存の Durable Layer を変更せず、アダプターとして上に乗る設計。

```
[Application]
     |
[CrdtDoc]        <- 変更なし
     |
[BFTAdapter]     <- deliver() で検証後、CrdtDoc に渡す
     |
[Transport]      <- 変更なし
```

`BFTAdapter::deliver(signed_event)` は受信した `SignedEvent` に対し以下を順に検証する:

1. **Hash 整合性** — イベント内容を再シリアライズしてハッシュを再計算、不一致なら拒否
2. **署名検証** — `Verifier` trait で author_key に対する署名を検証
3. **Equivocation 検出** — 同一 `(peer, counter)` に異なる digest が来た場合拒否
4. **因果配送** — 依存する digest が未到着の場合バッファリングし、到着次第フラッシュ

暗号プリミティブは `Hasher` / `Signer` / `Verifier` trait で抽象化されており、テスト用の FNV-1a + Mock 実装と、本番用の SHA-256 + Ed25519 実装を差し替え可能。

## Examples

- `examples/cf-do/` — Cloudflare Durable Objects (HTTP sync + WebSocket for ephemeral state)
- `examples/deno-deploy/` — Deno Deploy (HTTP sync)

## License

Apache-2.0
