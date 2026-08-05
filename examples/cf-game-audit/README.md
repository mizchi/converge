# Cloudflare game-audit infrastructure

`src/x/game_audit` の versioned CBOR、SHA-256/Ed25519検証、証明済みhead classifierを
SQLite-backed Durable Objectsへ接続する実験環境である。production認定ではない。

## Pattern mapping

| mode | Durable Object id | 主な相互検証 | 中央へ送る契機 |
| --- | --- | --- | --- |
| `pve` | `pve:<encounter>` | authority + participant sample | high-value / challenge |
| `pvp` | `pvp:<match>` | cross-team participant quorum | fork / dispute |
| `open` | `open:<encounter>` | interest-group observers | sample / challenge / marketplace |

一つのDOは一つのcoordination unitだけを直列化する。別match/encounterは別DOなので水平に
分散する。authority key、log session、initial epoch/parentは管理APIで一度だけ固定し、同じ設定の
retryだけを許す。これにより、正しく署名された過去headを新規DOの初期値にするrollbackを拒否する。

anchor submissionは次を実行する。

```text
bounded JSON/hex
  -> MoonBit canonical CBOR preflight
  -> SHA-256 + Ed25519 + exact membership capability
  -> MoonBit-proved head classification
  -> SQLite transactionSync(history + head or fork evidence)
  -> hibernatable WebSocket notification
```

SQLite tablesは`audit_config`、`anchor_head`、`anchor_history`、`anchor_forks`、
`replay_outbox`、`replay_artifacts`、`verified_item_creations`に加え、汎用checkpoint runtime用の
`checkpoint_runtime_config`、`checkpoint_local_head`、`checkpoint_history`、
`checkpoint_closures`、`checkpoint_outbox`、`checkpoint_destination_provisioning`、authority受信用の
`checkpoint_receiver_config`、`checkpoint_receiver_head`、
`checkpoint_receiver_history`、`checkpoint_receiver_forks`、署名収集用の
`checkpoint_witness_collections`、`checkpoint_witness_approvals`、`checkpoint_witness_conflicts`、
送信元隔離用の`checkpoint_witness_source_windows`。gap endpointは
保存済みhistoryから最大256 envelopeの連続pageだけを返す。

checkpoint runtimeは、固定したboundary・初期head・必要destination集合・outbox容量に対して、
MoonBitの`TrustedEpochClosure` admissionとopaque `AtomicCheckpointSealPlan`を呼ぶ。SQLiteの一つの
`transactionSync`でhistory、head CAS、全destinationのpending outbox、closure消費を適用する。
history/head/outbox/closure書込み直後のfault injectionはすべて全旧状態へrollbackし、成功commitは
Durable Object abort/restart後も全新状態として復元される。
管理APIでruntimeを設定すると、source DOは各destination DOへboundary、destination identity、initial
epoch/digestを事前provisionし、その完了を`checkpoint_destination_provisioning`へ保存する。全destinationが
完了するまでsealは`destination_not_provisioned`でfail-closedになり、receiverは最初のjobから設定を
作らない。

seal commit後、source DOはpending entryを30秒lease付きでclaimし、destination DOへ直接internal RPCする。
各entryはboundary、destination、epoch、digestから決定したidempotency keyと同じcanonical envelopeを
再利用する。ACKはMoonBitのopaque gateでauthority、boundary、epoch、digest、decisionを照合してから、
source SQLiteのacknowledged tombstoneへcommitする。ACK前にprocessが止まった場合はDO alarmがlease切れ後に
destinationごとのepoch、created order、digest順で最古entryを再送する。authority DOはhistory lookupを
head比較より先に行い、exact nextを`Accepted`、既知の同一bytesを`Duplicate`として返すため、authority
commit後のACK lossも回収できる。alarmを含む全dispatch入口は、同期MoonBit gateを呼ぶ前にWasm runtimeを
request scopeでロードする。ロード成功はbranded `LoadedCheckpointRuntime` capabilityとして表現し、
receiver認証、witness収集、atomic seal、ACK保存はcapabilityなしに型検査を通らない。

Queue consumerのcheckpoint分岐は後方互換・遅延配送用に残している。この経路ではauthorityへ送る前に
source DOへ戻り、job全体がdurable outbox行と完全一致することを確認する。idempotency keyをdigestに
合わせて再計算しただけの偽造jobもreceiverを変更できない。通常checkpoint経路はQueue bindingを使わず、
`REPLAY_QUEUE`は中央replayだけを自動投入する。
管理者限定seal header `x-audit-checkpoint-dispatch: deferred`はfault/互換経路試験用で、entryをclaimして
直接送信だけを保留する。30秒lease後のalarmは通常どおりdirect retryする。header省略時は`direct`である。

敵対的peerのwitness署名は、producer署名だけを持つcollectionを管理APIで作成し、peerが公開GETで
exact statement/policyを取得、公開POSTへ署名approvalを返すpull型reference transportで収集する。
公開POSTは管理tokenではなく、provision済みroster keyのEd25519署名を認証情報として扱う。
同一approvalは冪等、非roster・署名不正は無変更、同じwitnessの競合は競合側の署名も有効な場合だけ
evidenceとして保存する。deadline前に必要quorumへ達したcollectionだけが`ready`になり、seal APIは
`authentication_collection_ids`からexact statementを再確認して署名bundleを取り出す。
期限切れは`expired/pending`でありcheat確定ではない。
公開approval入口はCloudflareが設定する`CF-Connecting-IP`をserver secret付きHMAC-SHA-256 bucketへ変換し、
raw IPを保存せず、collection・sourceごとに1秒8件のfixed-window上限を適用する。client指定の内部bucket
headerは入口で除去するため、ある送信元のinvalid floodが別bucketの正当quorumを直接消費しない。
これは単一sourceの隔離であり、botnet/IP churn、巨大NAT、全source間の公平性を解決するものではない。
`CF-Connecting-IP`を信頼できるCloudflare ingressだけを公開境界とし、任意headerを設定できる直結proxyを
このWorkerの前に置かない。bucket secret未設定または32文字未満ではapproval入口を503にする。

```json
{
  "destination_id": "authority-1",
  "epoch": 7,
  "previous_checkpoint": "<parent>",
  "checkpoint_digest": "<digest>",
  "canonical_envelope": "<canonical bytes representation>",
  "deadline_at": 1785860000000,
  "producer_authentication": {
    "version": 1,
    "producer_id": "player-or-referee-id",
    "producer_key": "<64 lower-hex>",
    "statement_digest": "<64 lower-hex>",
    "producer_signature": "<128 lower-hex>",
    "approvals": []
  }
}
```

開始は`POST .../checkpoint-witness-collections`、取得は同pathのGET `?collection_id=...`、
応答は`POST .../checkpoint-witness-approvals`へ`collection_id`と1件の`approval`を送る。
実験用peer clientは公開GET後にroster key、deadline、collection状態を検査し、秘密seedをローカルの
MoonBit Ed25519 bridgeだけへ渡して署名する。seedは引数でなく環境変数から与える。

```sh
AUDIT_BASE_URL=http://127.0.0.1:8787 \
AUDIT_WITNESS_SEED_HEX=<32-byte lower-hex seed> \
pnpm witness -- pvp <unit> <collection-id> <witness-id>
```

このbridgeは`experimental_crypto`を使う未監査のreferenceであり、authority Worker routeへseedを
送るAPIではない。本番では端末keystore/HSMと監査済み署名backendへ置換する。

中央replayは全headを送らず、次だけをQueueへ送る。

| mode | 明示reason | 自動reason |
| --- | --- | --- |
| `pve` | `high_value`, `challenge` | `fork` |
| `pvp` | `dispute` | `fork` |
| `open` | `sample`, `challenge`, `marketplace` | `fork` |

明示要求は管理tokenを必須とする。DOはQueue送信前に`replay_outbox`へjobを保存し、
`mode/unit/reason/epoch/digest[/game-checkpoint-digest]`由来のidempotency keyでretryを重複排除する。送信失敗はDO alarmで
再試行する。Queue consumerは成功messageだけを個別ackし、at-least-once再配送は同じoutbox行の
transport上の`delivered`更新に収束させる。その後、jobがDOに保存されたhead/fork evidenceと
一致するかを検証し、MoonBitで証明したartifact classifierを通す。

三modeの管理要求は、最大1 MiBのversioned canonical CBOR bundleと対象game checkpoint digestを
任意で添付できる。bundleは`replay_artifacts`へ原子的に保存し、Queue本体には載せない。consumerは
SHA-256/Ed25519でcheckpointと全eventを認証し、完全event graphを作る。PvEはencounter kernelの
三root一致、PvPは公開状態kernelの三root一致に加えてcommit済みwitness rosterの`n-f` replay
certificateを要求する。open-world v2はaudit plan/seal/encounterに加え、独立publisherの
transparency checkpoint、plan/sealの2本のmap inclusion、遅延seed、`n-f` registration observer、
eligible-set Merkle inclusion、内包PvE replayを要求する。bundleなしの
anchor-only jobは従来どおり`awaiting_transcript`である。

```json
{
  "reason": "high_value",
  "checkpoint_digest": "<64 lower-hex>",
  "bundle_hex": "<mode-specific replay bundle canonical CBOR>"
}
```

open-world artifactは、後付けplan/sealを拒否するため追加境界を明示する。

```json
{
  "reason": "sample",
  "checkpoint_digest": "<encounter digest>",
  "target_session_id": "<encounter session>",
  "audit_checkpoint_digest": "<pre-reveal plan digest>",
  "seal_checkpoint_digest": "<closed eligible-set digest>",
  "transparency_log_session_id": "<independent log session>",
  "transparency_publisher_key": "<independent publisher public key>",
  "transparency_checkpoint_digest": "<trusted published head>",
  "bundle_hex": "<open-world PvE bundle v2 canonical CBOR>"
}
```

生成直後は保存済みcurrent ownerを照会する。transfer後はmarketplace backendが同じendpointへ
inventory proofを添え、per-asset headを進めながら出品判定する。

```json
{
  "asset_id": "<verified asset id>",
  "seller_id": "<authenticated current player>",
  "inventory_bundle_hex": "<inventory listing v1 canonical CBOR>",
  "inventory_checkpoint_digest": "<authority-signed candidate head>",
  "inventory_game_manifest_digest": "<configured asset kernel>"
}
```

candidateは保存済みheadのexact childでなければならず、epochは増加する。ownerが変わる場合は
versionも必ず増加する。同じheadの再照会はowner/versionが保存値と完全一致する場合だけidempotentに
成功する。

## Local validation

```sh
pnpm install
pnpm test
pnpm typecheck
pnpm deploy:dry
```

testはCloudflare Workers Vitest integration/workerd上で、checkpoint atomic seal、4 fault pointの
rollback、outbox容量不足、restart復元に加え、初期化、連続advance、duplicate、
same-epoch fork、gap、SQLite永続化後のDO eviction/restart、同一DOへの同一next head競合が
厳密に1回だけadvanceすることを確認する。加えて、mode別replay reason、outbox重複排除、
Queueの二重配送、矛盾したidempotency keyのretry、anchor-only jobがverifiedにならないこと、
実暗号PvE、3/4 witness付きPvP、3/4 registration observerとeligible proof付きopen-world bundleが
Queue consumerでverifiedへ到達することを確認する。
checkpoint transportではさらに、通常の`Accepted` ACK、Queue二重配送、authority commit後のACK消失、
headが先へ進んだ後のhistorical `Duplicate` ACKによる回復、digestを改変してidempotency keyを再利用した
jobのretryを確認する。
加えて、未provision receiverの拒否と、自己整合した偽造jobをsource outbox認証で拒否した後も正規jobが
forkにならずacceptedされることを確認する。
remote witness collectionではforeign/署名不正応答の無変更、exact duplicate、3/4 quorum、
approval保存後のactor abort/restart、quorum前seal拒否、collection-backed seal、deadline expiryに加え、
client指定bucketを無視した同一source 429と別source quorum成立、peer単独署名clientのroster key照合を確認する。
open-worldではさらに、検証済みitem生成だけがSQLiteへ入り、管理tokenなし・売り手不一致を拒否し、
生成直後のownerと、署名checkpoint・3/4 replay witness・origin receipt・authenticated inventory proofで
更新したcurrent ownerだけが`eligible_current_owner`になることを確認する。wrong parentとversion rollbackは
409で拒否し、古いownerのproofなし照会も拒否する。

ローカルbenchmarkは二つのterminalで実行する。

```sh
pnpm exec wrangler dev --port 8787 \
  --var ADMIN_TOKEN:test-admin-token \
  --var WITNESS_SOURCE_BUCKET_KEY:test-source-bucket-key-000000000000
pnpm bench:local
pnpm bench:witness
```

初回remote deploymentではWorkerを作成してから共有tokenを設定する。`pnpm deploy`はpnpm自身の
予約済みcommandなので、必ず`pnpm run deploy`を使う。

```sh
pnpm run deploy
pnpm exec wrangler secret put ADMIN_TOKEN
pnpm exec wrangler secret put WITNESS_SOURCE_BUCKET_KEY
AUDIT_BASE_URL=https://<worker>.workers.dev \
AUDIT_ADMIN_TOKEN=<token> \
AUDIT_LOCATION_HINT=apac-ne \
pnpm bench

AUDIT_BASE_URL=https://<worker>.workers.dev \
AUDIT_ADMIN_TOKEN=<token> \
AUDIT_LOCATION_HINT=apac-ne \
AUDIT_WITNESS_BENCH_SOURCE_MODE=single-egress \
AUDIT_WITNESS_BENCH_APPROVAL_MODE=parallel \
pnpm bench:witness
```

alarm retryを意図的に測る場合は、管理者限定のdeferred dispatchとACK timeoutを指定する。

```sh
AUDIT_WITNESS_BENCH_DISPATCH_MODE=deferred \
AUDIT_WITNESS_ACK_TIMEOUT_MS=75000 \
pnpm bench:witness
```

`location_hint=apac-ne`等は最初のDO accessだけに反映されるbest-effort hintである。既存DOは
動かないため、地域比較では毎回新しいunit idを使う。

benchmarkの既定値は、各modeについて64 head逐次投入、同一next headの16並行投入、中央replayを
1件enqueueしてdelivery待機、8 shardへ各8 head投入である。`AUDIT_BENCH_HEADS`、`AUDIT_BENCH_CONTENDERS`、
`AUDIT_BENCH_SHARDS`、`AUDIT_BENCH_HEADS_PER_SHARD`で変更できる。modeを分離して再測定する場合は
`AUDIT_BENCH_MODES=pve`またはcomma区切りを使う。open-world runはcurrent-owner proofによる
inventory head更新を1回行い、その後のmarketplace readも測る。
`bench:witness`は各runで不正送信元を8件拒否・9件目429にした後、別送信元のpeer client 3件で
quorumを作り、collection referenceからsealする。run数は`AUDIT_WITNESS_BENCH_RUNS`で変更できる。
remoteの単一clientでは送信元を分離できないため、`single-egress`は9並行burstを最大3回送り、
429の`Retry-After`後に正当approvalを送る。`parallel`は実peer fanoutと同様に3 approvalを並行送信する。
出力の`clean_seal_path`は敵対burstを除くcollection開始、quorum wall、sealのrun単位合計である。

## Local workerd baseline (2026-08-04)

Apple M5、Wrangler `4.118.0`、64 contiguous heads、HTTP clientからlocal workerd/DO/SQLiteと
experimental MoonBit Ed25519を含む。network RTTは含まない。
この節のmain benchmarkはpercentile修正前であり、20 samplesのp95/p99列は旧計算上のmaxである。

| mode | cold commit | warm mean | warm p95 | duplicate mean | 64-head gap |
| --- | ---: | ---: | ---: | ---: | ---: |
| PvE | 40.782 ms | 10.945 ms | 17.195 ms | 8.708 ms | 6.995 ms |
| PvP | 7.310 ms | 9.137 ms | 11.496 ms | 6.716 ms | 5.184 ms |
| open world | 6.980 ms | 8.150 ms | 9.913 ms | 8.604 ms | 5.304 ms |

current-owner接続後の小規模open-world run（32 heads、8 contenders、4 shard × 4 heads）では、
3,141-byte inventory proofの署名/Merkle検証とhead更新が26.527 ms、更新後の出品照会20回が
mean 2.931 ms / p95 5.901 msだった。

| mode | same-DO 16 requests | result | 8 DO x 8 heads | local throughput |
| --- | ---: | --- | ---: | ---: |
| PvE | 108.176 ms | 1 advance + 15 duplicate | 505.637 ms | 126.573 heads/s |
| PvP | 99.308 ms | 1 advance + 15 duplicate | 508.235 ms | 125.926 heads/s |
| open world | 110.818 ms | 1 advance + 15 duplicate | 475.331 ms | 134.643 heads/s |

| mode | replay reason | bundle | enqueue | queue -> delivered | kernel | audit decision |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| PvE | challenge | 2,585 bytes | 9.117 ms | 1,041.206 ms | 23 ms | verified |
| PvP（8-head補助run） | dispute | 3,546 bytes | 6.370 ms | 1,045.876 ms | 36 ms | verified |
| open world v2（8-head補助run） | sample | 6,178 bytes | 16.131 ms | 1,136.114 ms | 96 ms | verified |

PvE-v2 asset evidence接続後のopen-world再測定（8 heads / 4 contenders / 2 shard × 2 heads）は
7,045 bytes、enqueue 8.539 ms、delivery 1,114.007 ms、DO内検証52 msだった。保存された生成記録への
`market-listing`照会20回はmean 2.096 ms、p50 2.127 ms、p95/p99 4.095 ms。

local Queue consumerの`max_batch_timeout`は1秒なので、単発jobのdeliveryはほぼその待ち時間に
支配された。PvE kernelの23 msは16 heads・8 contenders・4 shardの補助runでDO内に記録した値で、
Queue待ちを含まない。forkは同じoutbox/Queue経路へ自動投入される。ここでdeliveryはtransportの
完了であり、`verified`は別にkernel成功を要求する。

既定の64-head/16-contender runは別runでPvE verifiedまで成功した一方、再計測時にopen-worldの
16並行duplicateの1件がlocal Wrangler `4.118.0`から500となりdev processが停止した。8並行の
integration testは安定しているため、これはprotocol違反の隠蔽ではなく、local負荷試験のフレーク
として今後Wrangler logとともに切り分ける。

### Local witness collection baseline (2026-08-05)

Apple M5、Wrangler `4.118.0`、loopback、PvP、20 collections。各collectionで`192.0.2.10`から
invalid approvalを8件拒否して9件目を429にし、その直後に別bucket `198.51.100.20`から3件の
独立peer署名を逐次送った。20/20で3/4 quorumとcollection-backed sealが成立した。

| 経路 | samples | mean | p50 | p95 | p99/max |
| --- | ---: | ---: | ---: | ---: | ---: |
| collection start | 20 | 15.037 ms | 9.437 ms | 22.542 ms | 105.794 / 105.794 ms |
| invalid rejection | 160 | 8.848 ms | 8.541 ms | 13.807 ms | 16.992 / 21.080 ms |
| 9件目の429 | 20 | 4.113 ms | 3.719 ms | 6.740 ms | 11.111 ms |
| peer GET + local sign + POST | 60 | 33.471 ms | 33.125 ms | 40.808 ms | 53.908 ms |
| 3 approval quorum wall | 20 | 100.440 ms | 97.943 ms | 110.266 ms | 126.737 ms |
| clean seal path | 20 | 160.867 ms | 152.674 ms | 191.552 ms | 251.177 ms |
| collection作成からready（敵対8+1件を含む） | 20 | 175.850 ms | 166 ms | 211 ms | 254 ms |
| collection-backed seal | 20 | 45.390 ms | 45.021 ms | 49.547 ms | 49.572 ms |

approval requestは60件でmean 680.5 bytes、p50/p95 682 bytesだった。測定artifactは
[`benchmarks/witness-local-2026-08-05.json`](./benchmarks/witness-local-2026-08-05.json)に保存した。
percentileはnearest-rankである。これは単一processのlocal workerd値であり、地域間RTT、botnet、
NAT共有時の公平性を表さない。

## Formal reconciliation: Queue delivery vs replay verification

| 項目 | 結果 |
| --- | --- |
| source of truth | MoonBitの`CheckpointReplayMatch`は完全transcriptのkernel replayと署名済みgame checkpoint一致からだけ生成される |
| implementation observation | anchor-only jobに加え、管理境界でmode固有の期待checkpointを固定して完全bundleをDO保存する経路がある |
| model question | anchor配送だけで`verified`へ到達可能か |
| machine result | 不可能。`verified`はanchor、transcript、checkpoint link、kernel complete、kernel matchを要求し、open-worldではさらにtrusted boundary、外部transparency publication、plan、seal/seed、registration、inclusion、replayの全条件を要求する。item生成の保存とinventory head更新もfail-closedで、game audit 161 + 汎用audit 31、計192 proof goals成功 |
| decision | anchor-onlyは`awaiting_transcript`。PvEは三root、PvPはさらに`n-f` replay witness、open-world v2は4 checkpoint・2 publication proofs・遅延seed・`n-f` registration・eligible inclusion後だけ`verified`にする |
| regression lock | `central_replay.mbt/.mbtp`、mode別wire/verifier tests、Worker bridge test、workerd Queue integration test |

最初のPvE commitにはMoonBit generated moduleのrequest-scope lazy importが含まれる。他modeは
同じWorker isolateでmoduleがwarmだった。1 headは約1.17 KiB、64 headsは約74.8 KiBだった。
並列値は単一local workerd processのCPU競合を含み、Cloudflare上で別DOが水平scaleする量を
推定する値ではない。

## Remote status (2026-08-05)

`https://converge-game-audit.mizchi.workers.dev`へcheckpoint transport、witness collection、
HMAC source isolationを含むbuildをdeploy済み。現行versionは
`a3c07778-037d-40cf-b2e9-5ad55afdec91`、upload 1,639.42 KiB、
gzip 174.29 KiB、startup 5 ms。checkpointはsource DOからauthority DOへの直接RPC、中央replayは
`converge-game-audit-replay` Queueを使う。`ADMIN_TOKEN`と
`WITNESS_SOURCE_BUCKET_KEY`はCloudflare Secretとして存在する。healthは200、公開witness routeは
HMAC設定不足の503ではなくruntime未設定の409まで5回連続で到達することを確認した。
rotated `ADMIN_TOKEN`はmacOS Keychain service `converge-game-audit-admin-token`だけに保存し、
文書・shell出力へ記録していない。

`apac-ne`への新規unitで、64 head/mode、16 same-DO contenders、8 DO × 8 head、中央replayの
remote benchmarkを完走した。

| mode | warm mean | warm p95 | same-DO result / wall | 8-DO throughput | replay delivery |
| --- | ---: | ---: | --- | ---: | ---: |
| PvE | 101.125 ms | 154.498 ms | 1 advance + 15 duplicate / 723.096 ms | 31.275 heads/s | 2,218.898 ms |
| PvP | 62.378 ms | 126.228 ms | 1 advance + 15 duplicate / 300.734 ms | 45.345 heads/s | 2,617.076 ms |
| open world | 105.272 ms | 178.294 ms | 1 advance + 15 duplicate / 748.040 ms | 43.890 heads/s | 5,177.180 ms |

中央replayは全3 modeで`verified`。open worldの3,141-byte inventory proof検証とhead更新は
216.444 ms、更新後のmarketplace照会20回はmean 29.781 ms、p50 22.734 ms、
p95/p99 102.303 msだった。詳細とSecret rolloutの観測は
[`docs/cloudflare-game-audit-ja.md`](../../docs/cloudflare-game-audit-ja.md)を参照する。
このmain benchmarkはpercentile修正前の出力で、20-read marketplaceのp95/p99は旧計算上のmaxである。
今後の`bench`/`bench:witness`はnearest-rankを明記して出力する。

### Remote witness collection baseline

東京clientから新規DOを作り、各collectionへ同一egressからinvalid approvalを9並行で送った。
fixed-window境界をまたいで429が出ない場合は最大3 burstまで続け、`Retry-After`後に3 peerの
GET・ローカル署名・POSTを並行実行した。全mode・全hintで20/20の3/4 quorumとsealが成立した。

最初のPvP `apac-ne`比較runでは、並列quorum wallがmean 1,093.013 ms / p50 940.130 ms、
逐次がmean 2,467.038 ms / p50 2,651.699 msだった。この比較からpeer fanoutは並列を必須とする。
この旧runのp95列は旧floor-index計算で20 sampleのmaxになっているため、tail設計には使わない。

その後、通常settlementへ直接使える`clean_seal_path`を追加した。これはrunごとの
`collection start + quorum wall + collection-backed seal`であり、意図的な敵対burstと回復待ちを除く。
p50/p95/p99はnearest-rankで計算し、20 sampleのp95をmaxと同一視しない。同一時刻帯の
`apac-ne` 20-run比較ではmode差は小さかった。

| mode | collection start mean | quorum mean | seal mean | clean mean | clean p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| PvP | 96.463 ms | 370.517 ms | 277.094 ms | 744.074 ms | 1,238.188 ms |
| PvE | 103.124 ms | 431.465 ms | 330.346 ms | 864.934 ms | 1,267.799 ms |
| open world | 98.371 ms | 361.717 ms | 295.881 ms | 755.969 ms | 1,347.831 ms |

同じPvP workloadのlocation-hint比較では、東京に近い`apac-ne`が最短だった。

| location hint | clean mean | clean p95 |
| --- | ---: | ---: |
| `apac-ne` | 744.074 ms | 1,238.188 ms |
| `wnam` | 1,554.724 ms | 1,983.401 ms |
| `weur` | 1,830.777 ms | 2,472.400 ms |

hintはbest-effortであり実coloを証明しない。各20 sampleなのでSLAではなく、同一clientから見た配置傾向の
baselineである。敵対burst込みの`server_collection`はrate-limit検査用で、render/input pathへ置かない。

同じ`apac-ne` PvP workloadを、seal後にauthority ACKがsource outboxへ保存されるまで追跡して20 run
再測定した。20/20が最初のpollで`Accepted`となり、ACK timeoutは0件だった。

| 経路 | mean | p50 | p95 | p99/max |
| --- | ---: | ---: | ---: | ---: |
| collection + quorum + seal | 1,241.528 ms | 1,063.771 ms | 1,884.616 ms | 1,893.033 ms |
| collection + quorum + authority ACK | 1,271.142 ms | 1,097.452 ms | 1,912.035 ms | 1,920.432 ms |
| seal request | 699.550 ms | 624.640 ms | 975.618 ms | 1,000.645 ms |
| seal開始からauthority ACK | 729.163 ms | 658.697 ms | 1,003.017 ms | 1,028.064 ms |
| seal応答後のACK観測差 | 29.613 ms | 29.505 ms | 35.884 ms | 40.834 ms |

途中の負荷試験で、Wasm未ロードの新規isolateからalarmがACK gateを呼ぶ反例を本番tailで検出した。
authority commit済みentryは修正版deploy後に4回目の試行でhistorical `Duplicate` ACKとして自動回復し、
その後の20 runは全件成功した。
branded runtime capabilityを追加した現行versionではdirect smokeも1/1 `Accepted`（seal開始からACK
678.542 ms）。さらに初回direct RPCを意図的に保留したdeferred smokeは、30秒lease後のalarmで
1/1 `Accepted`となり、seal応答後29,492.525 ms、233回目のpollでACKを観測した。

artifact:

- [`witness-remote-apac-ne-pvp-parallel-2026-08-05.json`](./benchmarks/witness-remote-apac-ne-pvp-parallel-2026-08-05.json)
- [`witness-remote-apac-ne-pve-parallel-2026-08-05.json`](./benchmarks/witness-remote-apac-ne-pve-parallel-2026-08-05.json)
- [`witness-remote-apac-ne-open-parallel-2026-08-05.json`](./benchmarks/witness-remote-apac-ne-open-parallel-2026-08-05.json)
- [`witness-remote-wnam-pvp-parallel-2026-08-05.json`](./benchmarks/witness-remote-wnam-pvp-parallel-2026-08-05.json)
- [`witness-remote-weur-pvp-parallel-2026-08-05.json`](./benchmarks/witness-remote-weur-pvp-parallel-2026-08-05.json)
- [`witness-remote-apac-ne-parallel-2026-08-05.json`](./benchmarks/witness-remote-apac-ne-parallel-2026-08-05.json)
- [`witness-remote-apac-ne-sequential-2026-08-05.json`](./benchmarks/witness-remote-apac-ne-sequential-2026-08-05.json)
- [`witness-authority-remote-apac-ne-pvp-direct-2026-08-05.json`](./benchmarks/witness-authority-remote-apac-ne-pvp-direct-2026-08-05.json)
- [`witness-authority-remote-apac-ne-pvp-deferred-2026-08-05.json`](./benchmarks/witness-authority-remote-apac-ne-pvp-deferred-2026-08-05.json)

## Guarantee boundary

- SQLite transaction内でhead/historyまたはfork evidenceを更新する。
- checkpoint sealはhistory/local head/必要outbox/closure消費を同じSQLite transactionで更新する。
- 必要destination集合はruntime configへ固定し、retry時の縮小で完全commitを偽装できない。
- 4つの途中faultは部分状態を残さず、成功commitはactor abort後も復元できる。
- eviction後もSQLiteからheadを復元できる。
- 初回headも管理側が固定したepoch/parentに完全一致しなければ初期化しない。
- raw envelopeやwire decode成功だけではheadを進めない。
- remote peerのwitness署名は公開pull/submit APIとdurable collectionへ接続済み。端末側の
  pull/署名/submit clientとper-source fixed-window隔離は全modeでremote実測済み。outbound push、
  global/roster-aware fair queue、端末側retry、botnet/IP churn対策は未接続。
- open-world plan/sealの外部log inclusionは接続済み。log headのremote witness/fanoutは未接続。
- local workerd値はCloudflare global networkのlatency/CPU billing値ではない。remote値も
  東京の単一clientからbest-effort hintを付けた各20-sample runであり、全地域の代表値ではない。
- `experimental_crypto`は未監査であり、本番暗号backendではない。
- mode固有bundleの期待checkpointは現在、管理tokenで認証した要求に固定したdigestである。
  current-owner proofとper-asset monotonic headは実装済み。transparency log headのremote witness、
  private-key custody、ancestry revocation、multi-asset atomic head、pruningは未実装。
- checkpoint outboxの直接DO RPC、lease/alarm retry、authority history、ACK保存はremote E2Eまで接続済み。
  Queue checkpoint consumerは後方互換経路として残す。敵対的peerからのproducer/witness署名はreceiver前の
  認証adapterへ接続済みだが、internal DO RPC自体は同一Cloudflare accountの認証済みchannelとして扱う。
- receiverの初期boundary/headは管理tokenで認証されたruntime設定時に事前provisionし、未設定receiverは
  fail-closedにする。これは同一Cloudflare account内のcontrol plane保証であり、外部peerのidentity証明ではない。

checkpoint runtime adapterとwitness collectionはremoteへdeploy・E2E実測済み。Wrangler remote-devは
QueuesとSQLite Durable Objectsをサポートしないため、production endpointの新規unitだけを使用した。

Cloudflareは新規DOにSQLite backendを推奨し、storageをstrongly consistentかつtransactionalと
説明している。WebSocketはhibernation APIを用いた。Queuesを追加する場合はat-least-once delivery
なので、checkpoint digestをidempotency keyとしてconsumer側で重複排除する。

- [SQLite-backed Durable Object Storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [Durable Object WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)
- [Cloudflare Queues delivery guarantees](https://developers.cloudflare.com/queues/reference/delivery-guarantees/)
- [Cloudflare Queues batching and retries](https://developers.cloudflare.com/queues/configuration/batching-retries/)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
