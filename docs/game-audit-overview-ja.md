# ゲーム監査prototypeの全体像

## 何を作ったか

このprototypeは、リアルタイム操作を中央サーバーの承認待ちにせず、あとから「その結果が正当な
操作列から生成されたか」を検証する。プレイヤーのローカルDB、同じencounter/matchにいるpeer、
低頻度の権威サーバーreplayを組み合わせる。

目的はブロックチェーンをゲームループへ入れることではない。署名済みevent、Merkle/authenticated-map
checkpoint、CRDTの順序非依存部分、deterministic game kernelを使い、中央の高価な再計算をsample、
challenge、高価値報酬、marketplace移転へ限定することである。

```text
client prediction / 即時演出
        │ signed intent・receipt・telegraph
        ▼
player-local event DB ── peer witness / observer certificate
        │ checkpoint + compact proof
        ▼
provisional result ── sample/challenge/high-value ── Cloudflare Queue
        │                                             │
        │ matching certificate                        ▼
        └──────── peer finality              deterministic central replay
                                                      │
                                                      ▼
                                       durable result / tradable asset
```

## ゲームモードごとの実装

| mode | 相互検証単位 | 現在のkernelと証拠 | 中央fallback |
| --- | --- | --- | --- |
| FF14型 1:N PvE | encounter | 予兆、入力receipt、複数AoE、位置、HP、生死、clear、loot | 全event graph、checkpoint三root、asset receipt rootを再計算 |
| LoL/Splatoon型 N:N PvP | match epoch | 同時move+attack、range、HP、team score、equivocation、`n-f` replay witness | referee checkpointと公開状態kernelを再計算 |
| 不規則open world | zone/encounter | 遅延seed、eligible-set seal、`n-f` registration observer、Merkle inclusion | sample/challenge/high-valueだけ完全PvE replay |

open-world v2では、audit planとsealを同じauthorityの署名だけでは信用しない。独立publisherの
transparency checkpointにplan digestと`plan -> seal` linkが含まれる2本のauthenticated-map proofを
要求する。transparency session、publisher key、checkpoint digestはbundle外の管理境界から固定する。

## 実装の層

| package | 責務 |
| --- | --- |
| `src/audit` | ゲーム非依存のcadence/retention、commitment射影、head分類、配送認証、vote quorumと形式証明 |
| `src/audit/merkle`, `src/audit/authmap` | compact inclusion/non-inclusion proof |
| `src/audit/layered` | watermark駆動のevent→micro→macro生成と二段inclusion proof |
| `x/game_audit/policy`, `checkpoint` | mode別presetと署名済みgame checkpoint adapter |
| `replay` | PvE/PvP deterministic kernelと完全transcript再生 |
| `attestation`, `witness_manifest` | `n > 3f`, `n-f` witness certificate |
| `open_world` | delayed sampling、observer anti-equivocation、seal、transparency publication |
| `wire` | canonical CBOR、version、byte/text/item/proof budget |
| `central_replay` | bundle外のtrusted boundaryと完全replayを結ぶcapability gate |
| `worker` | SHA-256/Ed25519 MoonBit bridge |
| `examples/cf-game-audit` | SQLite Durable Object、Queue、中央replay用idempotent outbox、検証済みitem生成記録、workerd実測 |

汎用contractと認証データ構造だけを `src/audit/` に置き、mode別の数値、replay規則、
witness rosterの選定・replay finality、asset生成は `src/x/game_audit/` に隔離している。

## 現在のゲーム別policy

同じ汎用アルゴリズムへ `src/x/game_audit/policy` が次の初期値を与える。event intervalは
rendering frameではなく監査leafの時間slotであり、画面更新やclient predictionをこの頻度へ
同期させる必要はない。

| mode | event | peer micro checkpoint | authority macro checkpoint | event / micro / macro retention | macro内leaf / 二分探索round |
| --- | ---: | ---: | ---: | --- | ---: |
| N:N adversarial PvP | 16 ms | 250 ms | 2 s | 60 s / 5 min / 1 day | 125 / 7 |
| 1:N cooperative PvE | 33 ms | 1 s | 15 s | 2 min / 10 min / 1 day | 455 / 9 |
| irregular open world | 50 ms | 2 s | 30 s | 5 min / 1 h / 7 days | 600 / 10 |

たとえばPvEで検証latencyがmean 100 ms、p99 244 msなら、一様到着近似の平均finalityは
7.6 s、保守的なp99上限は15.244 sになる。event leafを保持している2分間は33 ms単位、
その後10分までは1 s単位、1日までは15 s単位で不一致を局所化できる。これらはpresetであり、
実測latency、appeal window、item価値、保存費用からgame側で調整する。

## 現在の機械的な裏付け

- MoonBit: 362 tests passed。
- Why3 1.7.2 + Z3 4.8.17: 汎用audit 31 + game audit 161、計192 proof goals proved。
- TLA+ / TLC 2.18: 2 peer・2 epochのcrash/drop/partition/bounded-outboxモデルを11,340 distinct statesで検査し、
  safetyとnetwork安定後のauthority finalityに反例なし。witness collectionもsafety 30,720、liveness
  19,456 distinct statesで反例なし。6つの破損設定では期待した反例を検出。
- Cloudflare workerd integration: 42 tests passed（atomic sealの4 fault rollback、restart復元、producer/witness署名拒否・収集、source secret fail-closed、rate isolation、peer client、direct authority ACK、MoonBit runtime capability、settlement/percentile metricを含む）。
- local witness collection 20 run: hostile sourceの8件拒否後9件目429、別sourceの3/4 quorumは20/20成功。
  peer GET + local sign + POSTはmean 33.471 ms / p95 40.808 ms、3 approval wallはmean
  100.440 ms / p95 110.266 ms、clean seal pathはmean 160.867 ms / p95 191.552 ms。
- Cloudflare remote: direct authority RPC、durable retry、witness collection buildをversion
  `a3c07778-037d-40cf-b2e9-5ad55afdec91`としてdeploy済み。東京clientから全3 modeの`apac-ne`、
  PvPの`wnam`/`weur` hintを各20 run測り、公開pull、ローカル署名、公開submit、3/4 quorum、sealは
  100/100成功した。clean accepted-seal pathは`apac-ne`でmean 0.744〜0.865秒 /
  p95 1.238〜1.348秒、PvP `wnam`でmean 1.555秒 / p95 1.983秒、`weur`でmean 1.831秒 /
  p95 2.472秒だった。PvP `apac-ne`のauthority ACK追跡は20/20成功し、seal開始からACKまで
  mean 0.729秒 / p95 1.003秒、seal応答後の観測差はmean 29.613 ms / p95 35.884 msだった。
- PvE-v2 asset evidence付きopen-world小規模run: 7,045-byte bundle、enqueue 8.539 ms、Queue delivery
  1,114.007 ms、Queue待ちを除くDO内検証52 ms、保存後の出品照会20回はmean 2.096 ms / p95 4.095 ms。

`Proven`は`.mbtp`へ書いた純粋predicateと数学整数の範囲を表す。署名の偽造困難性、hash衝突耐性、
machine integer overflow、disk/network liveness、ゲームルールの完全性を証明した意味ではない。

初回の逐次/並列比較から、witness fanoutは並列を実装要件とする。clean pathを使うと2秒PvP macroの
東京→`apac-ne` event→accepted-sealは、一様到着近似でmean約1.744秒、保守的な
`macro interval + measured p95`で約3.238秒になる。これは描画・入力の待ち時間ではなく、rankや報酬を
確定するsettlement budgetとして使う。ただし単一client・単一egress、best-effort hint、各20 sampleの
baselineなので、全地域SLAや異なるsource間の公平性は未保証である。

## ゲームとして自然に見せる方法

操作、hit marker、回避、VFXはclient predictionで即時に見せる。監査待ちはプレイを止めず、結果の
重さにだけ反映する。

- 通常戦闘: 即時表示し、短いappeal window中はprovisional。
- rank/高価値drop: checkpoint後に確定。
- marketplace: central replayで生成過程を検証し、transfer後はauthority checkpoint、`n-f` replay
  witness、origin receipt、current-owner/versionのauthenticated-map proofを検証する。Workerはassetごとの
  inventory headをexact parent・epoch前進・owner/version整合でのみ更新する。
- このlisting fast pathはtransfer event列そのものを中央で毎回replayせず、manifestに拘束された
  `n-f` witness certificateを信用する。challenge、高価値、witness forkでは該当assetのtransition sliceを
  取得して既存`InventoryIndex`で中央replayする経路が次段階になる。
- 後発rejectionを過去のinventory ancestryへ伝播するrevocationとappeal windowは未接続なので、
  現在の`eligible` flagより強い祖先保証はまだ主張しない。
- certificate不足: cheat確定ではなく、報酬保留と中央replayへの昇格。

予兆AoE、projectile travel、charge/release、parry window、capture/hold、seed固定waveは監査と相性が
よい。1 frameのlast hit、chaotic rigid body、clientだけが持つhidden informationから不可逆な資産を
直接生成する設計は避けるか、権威サーバー境界へ残す。

## 残ロードマップ

prototypeのprotocol骨格は通ったが、production完成ではない。優先順は次のとおり。

1. 監査済み暗号backend、private-key custody、zone/epoch委任key、rotation。
2. transparency headとwitness certificateのpersistent remote socket、端末credential、fork alert。
   pure bounded fanout/retry/multi-peer response選択と、SQLite lease + bounded HTTP loopbackは実装済み。
3. observer signing storeとIndexedDB/mobile SQLiteへのproduction persistence、appeal window、pruning。
   player-local論理DB、storage-neutral write-set、Node SQLiteのatomic seal/restart/ACK復元は実装済み。
4. marketplaceのancestry revocation、appeal window、複数assetを同じinventory checkpointへ
   一括反映するhead registryと、risk-adaptive sampling/Queue backpressure。
5. PvE raidのwire/loot binding、PvPのprojectile/visibilityなど実ゲームkernel。
   phase分離boss HP/player attack/cooldownとPvP cooldown/capture objectiveのreferenceは実装済み。
6. packet loss/partitionを含むnetwork impairment試験、tail latency、実プレイテスト。
7. TLA+モデルを複数authority shard、pruning/appealへ拡張。bounded outboxは実装・反例確認済み。

head propagationの最小TLA+モデルは追加した。durable outbox、最古未ACKのretry、exact-parentがあれば、
networkが最終的に安定する公平な実行でauthorityがlatest epochへ到達することを有限状態で確認した。
一方、任意peer/epoch数、witness quorum、Byzantine送信者、実際のDB/transportへの対応付けは未検証である。

## 実行入口

```sh
just check-all
just test
just prove
just tla-check
just tla-counterexamples
just test-cf-game-audit
just check-cf-game-audit
just build-cf-game-audit
```

詳細は[研究とアーキテクチャ](./research-and-architecture-ja.md)、
[実装が満たすべき要求仕様](./game-audit-requirements-ja.md)、
[ゲーム表現と予兆設計](./telegraph-game-design-ja.md)、
[open-world選択的監査](./open-world-audit-ja.md)、
[Cloudflare実装と実測](./cloudflare-game-audit-ja.md)を参照する。
