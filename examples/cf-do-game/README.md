# converge survivors (Cloudflare DO demo)

`converge` の Ephemeral Layer を使った、マルチプレイ可能な Vampire Survivors 風デモです。

- Durable Object が WebSocket リレー + ゲームループを担当
- `EphemeralRelay` でプレイヤー入力 (`input_x`, `input_y`, `input_name`, `input_color`) を LWW merge
- サーバー側で敵スポーン / 自動攻撃 / ダメージ / レベルアップ / リスポーンを処理
- ブラウザを複数タブ開くだけでマルチプレイ確認可能

## ローカル実行

```bash
cd examples/cf-do-game
pnpm install
pnpm dev
```

`pnpm dev` は起動前に `moon build --target js` を自動実行します。

ブラウザで `http://localhost:8787` を開く。

別タブや別ブラウザで同URLを開くと同じルーム (`main`) に参加する。

## 操作

- PC: `WASD` または `矢印キー`
- Mobile: 画面左側ドラッグで移動
- 上部で名前/色変更

## 追加アルゴリズム

- 空間ハッシュ（Uniform Grid）でオーラ判定の候補を絞り込み
- スポーンディレクタ（予算ベース）で時間経過・平均レベルに応じて敵構成を調整
- 敵アーキタイプ（`grunt` / `runner` / `tank`）を導入

## デバッグ

- クライアント:
  - URL に `?debug=1` を付けると HUD にサーバー側メトリクス表示
  - `Backquote` キーで debug 表示を切り替え（再接続）
- サーバー:
  - `GET /debug` で現在の world と直近 tick の debug 履歴を取得

## テスト

```bash
pnpm test
```

`src/game.ts` の純粋ロジックに対する TDD テストを実行します。

E2E（Playwright）:

```bash
# 初回のみ
pnpm exec playwright install chromium

# 2クライアント接続 + 移動同期
pnpm test:e2e
```

現在の E2E シナリオ:

- 2クライアント同時接続 + 移動同期
- ページ再読み込み後の再接続 + 移動継続

## デプロイ

```bash
pnpm deploy
```

## 補足

過去の CLI シミュレーションも残しています。

```bash
pnpm sim
```

## トラブルシュート

- `Connecting...` から進まない
  - まず `pnpm dev` のログにエラーが出ていないか確認
  - 必要なら手動で `pnpm run build:moon` を実行してから再起動
  - ブラウザは `http://localhost:8787`（wrangler が別ポートを選んだ場合はそのポート）を開く
