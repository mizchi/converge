# 汎用 checkpoint audit 層

`src/audit/` は、CRDT や local-first DB に接続できるゲーム非依存の監査契約を提供する。
ここで扱うのは checkpoint の構造、保持期間から得られる検証精度、head 遷移、
Merkle/authenticated-map の compact proof である。cooldown、命中、loot、勝敗などの
ゲーム規則は application が deterministic kernel として実装する。

```text
authenticated canonical events ── layered watermark builder
          │                              │ micro roots
          │                              ▼
          │                         macro event root
          │                              │
application checkpoint ── CheckpointAdapter ── CheckpointCommitment
          │                                      │
          └── local DB / peers / authority ── head classifier
                                                  │
                                      application-owned replay policy
```

## パッケージ境界

| package | 汎用契約 |
| --- | --- |
| `audit` | checkpoint cadence/retention capability、精度・finality 見積り、storage 非依存 head classifier、MoonBit proof |
| `audit/commitment` | ゲーム固有 checkpoint を共通 commitment へ射影する trait |
| `audit/merkle` | immutable Merkle tree と inclusion proof |
| `audit/authmap` | deterministic authenticated treap と membership/non-membership proof |
| `audit/layered` | watermark駆動のevent→micro→macro builderと二段 inclusion proof |
| `audit/runtime` | trusted closure、atomic seal/outbox/ACK、player-local論理DB、peer fanout/retry選択 |
| `audit/delivery_auth` | destination固有checkpointのproducer署名とdistinct witness quorumをopaque capabilityへ変換 |
| `audit/quorum` | opaque subjectへのdomain-separated vote、roster認証、重複排除、equivocation収束 |
| `audit/quorum/vote` | vote join-semilatticeと可換・結合・冪等・equivocation吸収のproof |
| `audit/runtime/bridge` | Node/Worker等から利用するprimitive/JSONの小さいJS/Wasm bridge |

`CheckpointCommitment` は scope、epoch、previous checkpoint、manifest、event、state、
effect、任意の sealed-state commitment だけを固定する。digest の具体表現、署名、event decode、
replay、永続化 transaction は adapter 側の責務である。

persistence/transport adapterが満たすべきatomic seal、durable outbox、ACK、ordered retry、
crash recoveryの規範は
[ゲーム監査 persistence / transport 実装契約](../../docs/game-audit-implementation-contract-ja.md)に置く。
現在の`LayeredCheckpointBuilder`自体はin-memory builderである。`PlayerLocalAuditStore`は
event/equivocation/checkpoint/head/closure/outbox/ACK履歴を同一revisionでcommitし、公開された
永続row DTOからrestart復元する参照adapterを提供する。ACK済みoutboxだけで対応ACK履歴がないimageは
復元しない。SQLite/IndexedDBの物理transaction、row encoding、fsyncは
host adapterの責務であり、端末用production DBが完成したという意味ではない。

peer transportについては、persist済みleast-recently-attempted順のbounded fanout、in-flight
backpressure、上限付き指数backoff、成功reset、認証済みresponseの最速選択、認証済み異digestの
fork優先をpure contractとして持つ。socket/WebTransport/WebSocketと端末credentialは未接続である。

ゲーム固有の preset、PvE/PvP kernel、witness rosterの選定とfinality条件、open-world sampling、
inventory、marketplace は `src/x/game_audit/` に残す。したがって converge の汎用層を使っても、
「その操作がゲーム上合法」という結論は application の replay verifier なしには得られない。
詳細な昇格基準と保証境界は
[ライブラリ境界](../../docs/library-boundary-ja.md)に記録する。

## 精度と計算量

検証済み policy は次の包含関係を満たす。

```text
0 < event interval <= micro interval <= macro interval
macro interval <= event retention <= micro retention <= macro retention
```

証拠の age を `a`、各 interval を `δ`, `μ`, `T` とすると、保持中の時間方向の局所化精度は
次のように段階的に粗くなる。境界値は保持側に含む。

```text
a <= event retention : δ
a <= micro retention : μ
a <= macro retention : T
otherwise             : evidence expired
```

一つの macro checkpoint が覆う event leaf 数は `ceil(T / δ)`、二分探索で不一致を
一 leaf まで絞る round 数は `ceil(log2(ceil(T / δ)))` である。API は整数の反復 ceiling
division で計算する。

event が macro interval に一様に到着すると仮定した finality 見積りは、平均が
`floor(T / 2) + mean validation latency`、上限見積りが
`T + supplied p99 validation latency` である。これは測定値から作る engineering estimate
であり、network/disk の SLA や cheat 検出率の保証ではない。

## 階層checkpoint builder

`LayeredCheckpointBuilder` は認証済みcanonical eventをevent timeとともに保持し、単調な
watermarkがwindow境界を越えたときだけsealする。event timeはclient wall clockではなく、
applicationが認証・割当したaudit timeでなければならない。

- `event_time < watermark` はlate eventとして拒否する。
- `event_time == watermark` は次の未確定範囲として受理する。
- 同じcanonical payloadの再送はpending中idempotentに扱う。
- window内payloadはsortしてからMerkle化するためarrival orderに依存しない。
- canonical payloadにはsession内で一意なevent IDを含める。
- macro境界がmicro境界と一致しない場合、最後のmicroをmacro境界でforce-closeする。
- macroは直前macro digestを含み、各microのmetadataとevent rootをMerkle rootへ拘束する。
- catch-upは`max_windows`を超えると一切mutationせず拒否し、拒否判定も
  `max_windows + 1`走査で打ち切る。

保持中はevent→microとmicro→macroの二段inclusion proofを生成できる。compact metadataだけへ
stripした後はleaf proof生成能力を失うが、外部から提示されたproofの検証は可能である。

pending duplicate lookupはexpected `O(1)`、一windowのsealはcanonical sortを含む
`O(n log n)`、proof生成・検証は`O(log n)`である。FNV test backendによる現在のbenchmarkでは、
1000 eventを一microへsealして約1.0 ms、15 microを含むmacroまでsealして約1.2 msだった。
production hashでの値ではないため、採用gameのbackendで再測定する。

## head 遷移

`classify_checkpoint_head` は認証済み入力と storage lookup の結果だけを受け取り、
`Advance`, `Duplicate`, `SameEpochFork`, `ParentFork`, `Gap`, `Stale`,
`BoundaryMismatch` のいずれかを返す。永続化は pure classifier の外で transaction として行う。
境界不一致は fork accusation にせず、同一 epoch の異なる digest と exact-next epoch の
wrong parent だけを fork として分類する。

## atomic seal plan

`prepare_atomic_checkpoint_seal`はtransaction内で取得したstorage snapshot、canonical
checkpoint draft、`TrustedEpochClosure`、必要destinationを検査する。exact-nextかつparent一致で、
closure未消費、destination重複なし、outbox容量内の場合だけopaqueな
`AtomicCheckpointSealPlan`を返す。planはhistory追加、head更新、全outbox entry追加、closure消費を
一つのwrite setとして表す。既知digestの完全なcommitは`AlreadyCommitted`、既知異digestや
parent fork、不完全な既知commitはconflict、gap/stale/capacity不足はrefusalになる。

plan生成はDB commitではない。adapterは同じtransactionでexpected snapshotをCASし、plan全体を
適用する必要がある。これによりpure contractはDB/Cloudflare/SQLite固有実装から分離される。

## 証明と限界

`policy.mbtp`、`head.mbtp`、`time.mbtp`と`quorum/vote/participant_vote.mbtp`は、policyの
包含関係、保持精度、finalityの算術、headのexact-next/fork、vote mergeの可換・結合・冪等、
equivocation吸収、watermark未満のlate-event拒否、atomic seal成功時の
boundary/closure/exact-next/parent/destination/capacity/order条件を Why3/Z3 で検査する。
runtime testはcapabilityの構築不能性、atomic planの全-or-nothing結果、player-local restart、
ACK永続化、peer retry/fork選択、階層Merkle生成、境界値、game classifierとの互換性を補う。

証明していないものは hash collision resistance、署名偽造困難性、machine integer overflow、
storage/transport の liveness、ゲーム kernel の完全性、aimbot 等の観測不能な不正である。

```sh
just test-audit
just test-audit-layered
just test-audit-runtime
moon test src/audit/delivery_auth
moon test src/audit/quorum
moon test src/audit/runtime/bridge
just prove-audit-core
moon test src/audit/merkle
moon test src/audit/authmap
moon test src/audit/commitment
just bench-audit-layered
```
