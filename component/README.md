# converge-component

[mizchi/converge](https://github.com/mizchi/converge) の WebAssembly Component Model パッケージ。

WIT (WebAssembly Interface Types) で型付けされた CRDT sync engine を、任意の Wasm Component 対応ランタイムから利用できます。

## API

### Durable Layer

永続的な CRDT データ操作。EG-Walker ベースの因果イベントグラフで競合解決。

| 関数 | 説明 |
|------|------|
| `create-doc(peer-id) -> handle` | ドキュメント作成 |
| `doc-insert(handle, tbl, row-id, values) -> event` | 行の挿入 |
| `doc-update(handle, tbl, row-id, col, val) -> event` | セルの更新 |
| `doc-delete(handle, tbl, row-id) -> event` | 行の削除 |
| `doc-merge-remote(handle, events) -> list<merge-op>` | リモートイベントのマージ |
| `doc-get-pending(handle, known) -> list<event-run>` | 未送信イベントの取得 |
| `doc-sync-state(handle) -> sync-state` | 同期状態の取得 |

### Ephemeral Layer

一時的な LWW レジスタ。カーソル位置やプレゼンスなど高頻度・短寿命の状態向け。

| 関数 | 説明 |
|------|------|
| `ephemeral-set(handle, ns, key, val, timestamp) -> entry` | 値のセット |
| `ephemeral-get(handle, ns, key) -> option<entry>` | 値の取得 |
| `ephemeral-get-all(handle, ns) -> list<entry>` | namespace 内の全エントリ取得 |
| `ephemeral-merge(handle, entries) -> list<changed>` | リモートエントリのマージ |

## Prerequisites

- [MoonBit](https://www.moonbitlang.com/) toolchain
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools)
- [jco](https://github.com/bytecodealliance/jco) (JS transpile / テスト用)
- [just](https://github.com/casey/just) (タスクランナー)

## Build

```bash
just build    # wasm ビルド → component 作成
just test     # build + jco transpile + Node.js テスト
just wit      # コンポーネントの WIT を表示
```

## Usage (JavaScript)

`jco transpile` で生成した JS モジュールから利用:

```js
import { converge } from './gen/converge-component.js';

const handle = converge.createDoc("peer-A");

// Insert a row
const ev = converge.docInsert(handle, "users", "row1", [
  { key: "name", val: { tag: "val-str", val: "Alice" } },
  { key: "age",  val: { tag: "val-int", val: 30 } },
]);

// Sync to another peer
const h2 = converge.createDoc("peer-B");
const pending = converge.docGetPending(handle, []);
const ops = converge.docMergeRemote(h2, pending);
// ops = [{ tag: "insert-row", val: { tbl: "users", rowId: "row1", ... } }, ...]
```

## Type Definitions

WIT で定義された主要な型:

```wit
variant value {
    val-null, val-bool(bool), val-int(s32), val-float(f64), val-str(string),
}

record key-value { key: string, val: value }
record event-id  { peer: string, counter: s32 }

variant row-op {
    insert(insert-op), update(update-op), delete(delete-op),
}

variant merge-op {
    set-cell(set-cell-op), insert-row(insert-row-op), delete-row(delete-row-op),
}
```

完全な型定義は [wit/world.wit](wit/world.wit) を参照。

## Directory Structure

```
component/
├── justfile           # ビルドタスク
├── wit/world.wit      # WIT インターフェース定義
├── gen/cabi/          # 生成: canonical ABI ヘルパー
├── impl/
│   ├── bindings.mbt   # 生成: FFI バインディング
│   └── impl.mbt       # 手動: 型変換 + ハンドル管理
└── test/
    └── test.mjs       # E2E テスト
```

## License

Apache-2.0
