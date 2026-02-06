# crdt_db Sync Server — Cloudflare Workers + Durable Objects

MoonBit JS target ベースの CRDT sync hub。Durable Objects で単一インスタンス + co-located storage。

## Prerequisites

- Node.js + pnpm
- `moon build --target js`

## Run locally

```bash
# JS ビルド (プロジェクトルートで)
moon build --target js

# 依存インストール
pnpm install

# ローカル起動
pnpm dev
```

## Deploy

```bash
pnpm deploy
```

## API

| Method | Path | Body | Response |
|--------|------|------|----------|
| GET | `/api/state` | — | `{ frontier, versions }` |
| POST | `/api/push` | `{ events: EventRun[] }` | `{ ok, merge_ops }` |
| POST | `/api/pull` | `{ known_peers }` | `{ events, server_frontier }` |

## Architecture

- **Worker**: リクエストを受けて単一の Durable Object にルーティング
- **Durable Object (CrdtDoc)**: CRDT doc をメモリ保持、DO Storage に永続化
- `blockConcurrencyWhile` で起動時に Storage から replay
- Dynamic import で MoonBit JS ランタイムの初期化をハンドラスコープに遅延（CF Workers のグローバルスコープ制約を回避）

## Performance (vs Deno Deploy)

| Operation | Deno Deploy | CF Workers (DO) |
|-----------|-------------|-----------------|
| State | ~420ms | ~80ms |
| Push 1 op | ~670ms | ~95ms |
| Push 1000 ops | ~5.9s | ~250ms |
| Pull | ~410ms | ~80ms |
