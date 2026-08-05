# Node player-local audit runtime SQLite adapter

`src/audit/runtime` の `PlayerLocalAuditStore` を、Node.js 24 の組み込み
`node:sqlite` へ写す参照 adapter である。ゲーム規則は含めず、1 player・1 audit
boundary を一つの SQLite transaction domain として保存する。

## 境界

- event は署名・digest・boundary 検証後の `PlayerLocalAuditEvent` だけを受け取る。
- seal は MoonBit の `PlayerLocalSealPlan::write_set()` が出した
  `PlayerLocalSealWriteSet` だけを受け取る。
- ACK は MoonBit の opaque authentication gate を通過した evidence だけを渡す。
- TypeScript の構造型だけでは上の capability を保証できないため、未認証 network
  payload を直接この adapter へ渡してはならない。

公開 DTO は [contracts.ts](./src/contracts.ts)、再生成可能な物理実装は
[player-local-sqlite.ts](./src/player-local-sqlite.ts) に分離した。

seal は次を一つの `BEGIN IMMEDIATE` で適用する。

```text
revision/snapshot CAS
  -> checkpoint history
  -> head CAS
  -> all destination outbox rows
  -> consumed closure evidence
  -> next created-order + revision
```

途中の4書込み点へ障害を注入した場合は全relationをrollbackする。起動時には全rowから
論理imageを再構築し、orphan head、欠けたclosure/outbox、ACK evidenceのない
acknowledged rowを拒否する。event、equivocation、checkpoint、outbox、ACKは線形走査で
検証し、SQLiteのkey/indexで重複とlookupを制約する。

## Peer fanout

[moonbit-peer-policy.ts](./src/moonbit-peer-policy.ts) は、生成済みMoonBit JSから
bounded fair selection、指数backoff、success reset、複数response/fork分類を呼ぶ。
[peer-route-sqlite.ts](./src/peer-route-sqlite.ts) はendpoint、試行順、retry時刻、durable lease、
quarantine、認証済みfork evidenceを同じplayer DBへ保存する。
[peer-checkpoint-transport.ts](./src/peer-checkpoint-transport.ts) は状態とpolicyから分離したI/O driverで、
差し替え可能なsenderに加えてbounded HTTP POST実装を持つ。

```text
SQLite routes + active leases
  -> MoonBit bounded/fair selection
  -> atomic route claims
  -> parallel HTTP POST
  -> application-provided signature/authentication verifier
  -> MoonBit response/fork classification
  -> success/backoff、またはfork evidence + quarantineをSQLite commit
```

未認証bytes、HTTP error、timeout、response byte上限超過はfork evidenceにせずbackoffする。
認証済みの異digestだけをforkとして永続化する。senderの最大試行時間がdurable leaseより長い構成は
起動時に拒否する。`now_ms`はaudit unitのmanifestで固定したclock originからの相対時間であり、
process再起動後も同じoriginから再構築しなければならない。

## 実行

```sh
pnpm install
pnpm typecheck
pnpm test
```

Node 24 時点の `node:sqlite` は experimental API である。本番の端末DBへ採用する場合は、
runtime version固定、migration、fsync/端末強制終了試験、key custody、暗号化at-restを別途
満たす必要がある。IndexedDB adapter、seal write-setの自動JS serialization、実Ed25519 verifier、
WebSocket/WebTransport senderは未実装である。
