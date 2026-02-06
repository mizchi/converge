# crdt_db Sync Server — Deno Deploy

WASM-GC ベースの CRDT sync hub。Deno KV で永続化。

## Prerequisites

- Deno 2.x
- `moon build --target wasm-gc`

## Run locally

```bash
# WASM ビルド (プロジェクトルートで)
moon build --target wasm-gc

# サーバー起動
deno task dev
```

## Deploy

```bash
# WASM を同梱用にコピー
cp ../../target/wasm-gc/release/build/wasm/wasm.wasm ./crdt.wasm

# デプロイ (wasm.ts の WASM_PATH を "./crdt.wasm" に変更すること)
deployctl deploy --project=<your-project> --prod --entrypoint=main.ts
```

## API

| Method | Path | Body | Response |
|--------|------|------|----------|
| GET | `/api/state` | — | `{ frontier, versions }` |
| POST | `/api/push` | `{ events: EventRun[] }` | `{ ok, merge_ops }` |
| POST | `/api/pull` | `{ known_peers }` | `{ events, server_frontier }` |

## Notes

- Deno Deploy ではマルチ isolate のため、`catchUp` で KV バージョンチェックを実施
- Push は `kv.atomic()` でバッチ化済み
- KV value 上限 64KB のため、大きい EventRun は 50 ops ごとにチャンク分割
