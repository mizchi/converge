# Cloudflare Workers game-audit evaluation

## 現在地

game-auditの純粋な受理判定、canonical wire、実暗号互換adapterまで揃ったため、永続化と配送の
仮定をCloudflare Workers上で実測する段階へ移った。実装は
[`examples/cf-game-audit`](../examples/cf-game-audit/README.md) に隔離した。

これで「プロトコル側の残件がすべて終わるまでinfraを待つ」のではなく、次の未達contractを
実験で閉じられる。

| 未達contract | Cloudflare実験で見るもの |
| --- | --- |
| crash-safe head/history | SQLite-backed DOのtransactionとeviction後復元 |
| atomic checkpoint seal | MoonBit opaque planをSQLite history/head/outbox/closureへ一括適用 |
| seal crash consistency | 4 write pointのfault rollbackと成功commit後のabort/restart復元 |
| first-head rollback | trusted configのinitial epoch/parentとの完全一致 |
| gap transport | bounded contiguous HTTP page |
| realtime fanout | hibernatable WebSocket通知 |
| coordination cost | 1 unit / 1 DOの直列化latency、別DOの水平scale |
| geographical cost | 新規DOへのlocation hint別RTT |
| central replay budget | Queue enqueue率、backpressure、outbox重複排除 |

## 三パターン

### 1:N PvE / dungeon

encounterごとにDOを作る。authority checkpointを参加者observerが検証し、通常lootはpeer witness、
high-value/challengeだけ中央replayへ送る。DOはcombat tick authorityではなく、署名済み監査headの
永続化とfork/gap検出を担当する。

### N:N adversarial PvP

matchごとにDOを作る。cross-team witnessを優先し、同一epochの異なるauthority-signed digestまたは
next epochのwrong parentをfork evidenceとして保存する。全frameをDOへ送らずcheckpointだけを送る。

### Open world irregular encounter

短いencounterごとにDOを作り、interest group内のobserver結果をanchorにする。通常結果は中央へ
送らず、sample/challenge/marketplace時にだけhistory/gap pageを取得する。player単位の永久DOへ
全encounterを集中させないことでhot keyを避ける。

## 初回local baseline

Apple M5上のworkerdで、HTTP routing、MoonBit canonical CBOR、experimental SHA-256/Ed25519、
capability open、証明済みclassifier、SQLite transactionを含めて測った。64 headを各modeへ逐次投入。
この初回main benchmarkはpercentile修正前であり、20 samplesのp95/p99列は旧計算上のmaxである。

| mode | cold commit | warm mean | warm p95 | duplicate mean | 64-head gap |
| --- | ---: | ---: | ---: | ---: | ---: |
| PvE | 40.782 ms | 10.945 ms | 17.195 ms | 8.708 ms | 6.995 ms |
| PvP | 7.310 ms | 9.137 ms | 11.496 ms | 6.716 ms | 5.184 ms |
| open world | 6.980 ms | 8.150 ms | 9.913 ms | 8.604 ms | 5.304 ms |

同一DOへ同じnext headを16並行投入した結果は、全modeで1 advance + 15 duplicateだった。
wall timeはPvE 108.176 ms、PvP 99.308 ms、open world 110.818 ms。8個の別DOへ各8 headを
逐次投入したlocal throughputは、それぞれ126.573、125.926、134.643 heads/sだった。
後者は単一local workerd processのCPU競合を含むため、本番Cloudflareの水平scale値ではない。

中央replay単発jobの経路では、PvEに2,585 bytesの完全bundleを添付し、enqueue 9.117 ms、
transport delivered 1,041.206 ms、Queue待ちを除くDO内kernel 23 msで`verified`になった。追加した
PvP補助run（8 heads、4 contenders、2 DO × 2 heads）では3,546-byte bundle、enqueue 6.370 ms、
delivery 1,045.876 ms、DO内36 msで3/4 witness certificateまで検証して`verified`になった。
open-world v2補助run（同じく8 heads、4 contenders、2 DO × 2 heads）では6,178-byte bundle、enqueue
16.131 ms、delivery 1,136.114 ms、DO内96 msで独立transparency checkpoint、plan/sealの2 inclusion、
plan/seal/encounter、3/4 registration observer、eligible inclusion、PvE replayまで検証して`verified`になった。単発deliveryは1秒のlocal Queue
batch timeoutに支配された。

PvE-v2 asset evidenceとmarketplace接続後のopen-world小規模再測定（8 heads、4 contenders、
2 DO × 2 heads）では、7,045-byte bundle、enqueue 8.539 ms、delivery 1,114.007 ms、Queue待ちを
除くDO内完全検証52 msだった。生成記録は1件eligibleとして保存され、同じDOへの出品照会20回は
mean 2.096 ms、p50 2.127 ms、p95/p99 4.095 msだった。これはlocal loopbackかつ初期owner照会であり、
transfer後inventory proofやremote RTTを含まない旧baselineである。

current-owner inventory v1接続後のopen-world run（32 heads、8 contenders、4 DO × 4 heads）では、
3,141-byte bundleにauthority checkpoint、4 witness roster中3署名、origin receipt commitment、
current owner/versionのauthenticated-map membershipを格納した。署名・Merkle検証とSQLiteの
per-asset head更新は26.527 ms、更新後のcurrent-owner出品照会20回はmean 2.931 ms、p50 2.709 ms、
p95/p99 5.901 msだった。同runの7,112-byte open-world replayはQueue待ちを除くDO内60 msである。

### Local peer witness collection（2026-08-05）

公開pull→端末内MoonBit署名→公開submit→durable quorum→collection-backed sealを同じlocal workerdへ
接続した。PvP 20 collectionsそれぞれで、hostile sourceからinvalid approvalを8件送り、client指定の
内部bucketを毎回変えても9件目が429になることを確認した。その直後、別sourceから3つのprovision済み
witness seedで個別に署名・送信し、20/20で3/4 quorumとsealが成立した。

| 経路 | samples | mean | p50 | p95 | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| collection start | 20 | 15.037 ms | 9.437 ms | 22.542 ms | 105.794 ms |
| hostile invalid rejection | 160 | 8.848 ms | 8.541 ms | 13.807 ms | 21.080 ms |
| hostile 9件目の429 | 20 | 4.113 ms | 3.719 ms | 6.740 ms | 11.111 ms |
| peer GET + local sign + POST | 60 | 33.471 ms | 33.125 ms | 40.808 ms | 53.908 ms |
| 3 approval quorum wall | 20 | 100.440 ms | 97.943 ms | 110.266 ms | 126.737 ms |
| clean seal path | 20 | 160.867 ms | 152.674 ms | 191.552 ms | 251.177 ms |
| 作成→ready（hostile 9件込み） | 20 | 175.850 ms | 166 ms | 211 ms | 254 ms |
| collection-backed seal | 20 | 45.390 ms | 45.021 ms | 49.547 ms | 49.572 ms |

percentileはnearest-rank。approval POST bodyはmean 680.5 bytes、p95 682 bytes。raw IPはSQLiteへ保存せず、Worker入口で
server secretと`checkpoint-witness-source-v1` domainを使うHMAC-SHA-256 bucketへ変換する。
secretが未設定または32文字未満なら公開approval入口は503でfail-closedする。現在の1秒8件fixed windowは
別source progressの局所的な隔離であって、botnet/IP churnや同一NAT内の多数player、全source間の
公平性を保証しない。測定artifactは
[`examples/cf-game-audit/benchmarks/witness-local-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-local-2026-08-05.json)。

## Queueと中央replayの形式的境界

既存のMoonBit `CheckpointReplayMatch`は、完全なgame transcriptをkernelで再実行し、署名済みgame
checkpointのmanifest/event/public-state rootsに一致した場合だけ生成される。Cloudflareの標準
Queue jobが持つsigning-anchor head/fork digestだけでは、この条件を満たさない。

この差を5入力のartifact classifierとしてモデル化し、anchorだけなら`awaiting_transcript`、
`verified`ならanchor一致、transcript存在、checkpoint link、kernel完遂、kernel一致がすべて真である
ことを証明した。さらにopen-world中央検証をtrusted job boundary、外部transparency publication、
署名済みplan、署名済みsealと遅延seed、observer registration quorum、encounter inclusion、
完全replay一致の7条件としてfail-closedにモデル化した。さらにitem生成の永続化はopen-world境界、
central replay成功、summary正規化、checkpoint一致、DB衝突なしの5条件を要求する。
inventory head更新はeligible creation、proof成功、manifest一致、exact parent、epoch前進、
owner/version整合の6条件を要求し、wrong-parentとversion rollbackを拒否する。
game-audit packageで161 proof goals、汎用audit policy/head/event-time/closure/ACK/atomic seal/
delivery authenticationとvote semilatticeで39 goals、計200 goalsが成功している。Workerは汎用headを含むMoonBit分類器を直接呼ぶため、Queue配送成功を
ゲーム結果の検証成功へ昇格させない。

三modeでversioned canonical CBOR bundleを`replay_artifacts`へ保存する経路を実装した。PvE bundleは
署名済みgame checkpoint、encounter config/roster/attack plan、署名済みtelegraph/input/receiptを
持つ。PvP bundleはreferee checkpoint、公開state config、team/player/witness roster、fault bound、
署名済みcommand/receipt、replay-witness attestationを持つ。consumerは1 MiB等の上限を先に確認し、
全eventをBFT adapterへ通してから既存kernelを実行する。PvPはさらに`n > 3f`のmanifestと`n-f`
certificateを検証する。checkpoint digest、authority/referee、sessionはbundleから信用せず、管理APIが
固定した期待値と比較する。

open-world bundleは署名済みaudit plan/seal、遅延公開seed、observer roster/fault bound、署名済み
registration observations、eligible Merkle proof、完全PvE bundleを持つ。consumerはplan/seal/encounter
の3 digestを管理境界の期待値と比較し、`n-f` observer certificate、seed commitment、seal inclusion、
game replayをすべて通す。seed公開後にauthorityが署名した別plan/sealへの差し替えは期待digestで拒否する。

PvE bundle v2はauthority署名のtyped asset-effect eventを戦闘event graphへ追加する。中央replayは
survivorだけに決定論的loot kernelを適用し、`ItemReceipt`のMerkle rootがcheckpointの
`asset_delta_root`と一致した場合だけ`VerifiedItemCreation`を返す。open-world consumerはこの要約を
`replay_outbox`のverified更新と同じSQLite transactionで`verified_item_creations`へ保存する。
管理tokenを持つmarketplace backendは`POST /v1/open/:unit/market-listing`へ`asset_id`と、上流で
認証済みの`seller_id`を渡す。所有権を進める場合はさらに`inventory_bundle_hex`、
`inventory_checkpoint_digest`、`inventory_game_manifest_digest`を渡す。中央verifierは署名checkpoint、
`n-f` replay witness、生成時receipt、current-owner Merkle proofを検証し、DOは保存済みper-asset headの
exact childだけをtransactionで受理する。wrong parent、epoch/version rollback、古いowner、revoked状態は
fail-closedになる。proof省略時も、最後に保存したcurrent ownerだけを許可する。

このcompact listing verifierはtransfer event列をbundleに含めず、manifest-bound `n-f` witnessが
同じinventory transitionをreplayしたというByzantine fault assumptionを使う。したがって通常出品の
低コストfast pathにはなるが、challenge・高価値・witness fork時にtransition sliceを取得して
`InventoryIndex`を中央replayするslow pathはまだ未接続である。

このprototypeの`checkpoint link`は、管理tokenで認証した要求が対象game checkpoint digestを
指定した、という接続境界である。signing-anchor内にgame checkpoint inclusionを証明するものでは
ない。PvP bundle内のreplay-witness certificateは実装済みだが、anchorとtarget checkpointの包含関係を
代替しない。open-worldではencounterのeligible-set inclusionまで実装したが、audit plan/seal自体を
signing-anchorや外部transparency logへ含める最後のlinkは管理APIによる期待digest固定のままである。

PvE cold値はMoonBit moduleのlazy importを含む。production runtimeはglobal scopeでの乱数生成を
拒否したため、generated moduleをrequest scopeで読む必要があった。Vitestだけでは発見できず、
実際の`wrangler dev`起動を回帰手順に含める理由になった。

この値はlocal loopbackであり、Cloudflare上の地域間RTT、CPU time、課金、tail latencyを表さない。
また、最新の既定64-head/16-contender再計測ではopen-worldのduplicate 1件が500となりWrangler
`4.118.0` dev processが停止した。8並行integration testと8-contender補助runは成功している。
再現条件、Wrangler log、production isolateでの再現有無を切り分けるまでは、16並行値を安定上限とは
扱わない。

## Remote deployの現在地

2026-08-05にcheckpoint transport、witness collection、HMAC source isolationを含むbuildを
`https://converge-game-audit.mizchi.workers.dev`へdeployした。現行versionは
`a3c07778-037d-40cf-b2e9-5ad55afdec91`、upload 1,639.42 KiB、gzip 174.29 KiB、
startup 5 ms。checkpointはsource DOからauthority DOへの直接internal RPCを通常経路とし、
SQLite leaseとDO alarmで再送する。Queue checkpoint consumerは後方互換経路として残し、
`converge-game-audit-replay` Queueは中央replayを配送する。`ADMIN_TOKEN`と
`WITNESS_SOURCE_BUCKET_KEY`はCloudflare Secretとして存在する。
rotated `ADMIN_TOKEN`はmacOS Keychain service `converge-game-audit-admin-token`だけに保存し、値を文書や
shell出力へ記録していない。healthは200、公開approval routeはsource secret欠落の503を通過し、
runtime未設定の409へ5回連続で到達した。

承認を得て`ADMIN_TOKEN`をrotateした後、production endpointの新規unitでremote witness E2Eを
完走した。`wrangler dev --remote`も試したが、Wrangler `4.118.0`はremote modeでQueues未対応かつ
SQLite Durable Objectsをlocal modeだけに制限するため503となり、代替測定環境にはできなかった。

### apac-ne remote baseline

2026-08-04T11:16:50Zから、東京のclientから新規unitへ`location_hint=apac-ne`を付けて
既定条件を実測した。各modeは64 headを逐次投入し、同一next headを16並行、別8 DOへ
各8 head、中央replayを1件処理する。`location_hint`はbest-effortであり、Cloudflareが実際に
配置したcoloを証明する値ではない。healthの単発RTTは202.137 msだった。

| mode | configure | warm commit mean | p95 | p99 | duplicate mean | 64-head gap |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| PvE | 890.935 ms | 101.125 ms | 154.498 ms | 201.429 ms | 86.699 ms | 102.743 ms |
| PvP | 792.367 ms | 62.378 ms | 126.228 ms | 151.381 ms | 53.584 ms | 22.578 ms |
| open world | 772.460 ms | 105.272 ms | 178.294 ms | 243.717 ms | 89.152 ms | 25.990 ms |

同一DOの16競合は全modeで1 advance + 15 duplicateだった。複数DOは8 DO × 8 headの
wall timeと、clientから見たend-to-end throughputである。

| mode | same-DO wall | same-DO throughput | 8-DO wall | 8-DO throughput | parallel commit p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| PvE | 723.096 ms | 22.127 req/s | 2,046.388 ms | 31.275 heads/s | 271.607 ms |
| PvP | 300.734 ms | 53.203 req/s | 1,411.405 ms | 45.345 heads/s | 251.439 ms |
| open world | 748.040 ms | 21.389 req/s | 1,458.196 ms | 43.890 heads/s | 262.666 ms |

| mode | bundle | enqueue | queue -> delivered | decision |
| --- | ---: | ---: | ---: | --- |
| PvE challenge | 3,401 bytes | 1,028.241 ms | 2,218.898 ms | verified |
| PvP dispute | 3,546 bytes | 397.856 ms | 2,617.076 ms | verified |
| open-world sample | 7,112 bytes | 329.415 ms | 5,177.180 ms | verified |

open-world replayはeligible itemを1件保存した。続けて3,141-byte current-owner inventory proofの
署名/Merkle検証とper-asset head更新は216.444 ms、更新後のmarketplace照会20回は
mean 29.781 ms、p50 22.734 ms、p95/p99 102.303 msだった。

このmain benchmarkはpercentile修正前の出力で、20-read marketplaceのp95/p99は旧floor-index計算上の
maxである。今後のbenchmarkはshared nearest-rank集計とmethod metadataを使う。

Secret変更直後は新値を参照するrequestと旧値で401を返すrequestが混在した。今回は
変更から約30秒後に新値が初めて見え、約115秒後に5秒間隔のprobeが12回連続で成功した。
このrollout待ちは上記latencyに含めていない。Secret rotationは直ちに完全切り替えと仮定せず、
新旧両tokenのgrace periodまたはversion-aware deploymentを検討する必要がある。

### remote witness baseline

東京clientから新規unitを作り、公開pull、端末内MoonBit署名、公開submit、durable quorum、
collection-backed sealを実測した。同一egressからinvalid approvalを9並行で送り、fixed-window境界を
またいで429が出ない場合は最大3 burstまで再試行した。`Retry-After`後に3 peerのapprovalを並行送信し、
全mode・全hintで20/20の3/4 quorumとsealが成立した。

初回PvP `apac-ne` runの並列quorum wallはmean 1,093.013 ms / p50 940.130 ms、比較用の逐次runは
mean 2,467.038 ms / p50 2,651.699 msだった。したがってpeer fanoutは並列化を実装要件とする。
この旧runのp95列は旧floor-index計算で20 sampleのmaxになっているため、tail設計には使わない。

通常settlement向けには、runごとの`collection start + quorum wall + collection-backed seal`を
`clean_seal_path`として追加した。意図的な敵対burstとrate-limit回復待ちは含めない。同一時刻帯の
`apac-ne` 20-run比較ではmode差は小さかった。percentileはnearest-rankとし、20 sampleのp95とmaxを
別々に記録する。

| mode | start mean | quorum mean | seal mean | clean mean | clean p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| PvP | 96.463 ms | 370.517 ms | 277.094 ms | 744.074 ms | 1,238.188 ms |
| PvE | 103.124 ms | 431.465 ms | 330.346 ms | 864.934 ms | 1,267.799 ms |
| open world | 98.371 ms | 361.717 ms | 295.881 ms | 755.969 ms | 1,347.831 ms |

同じPvP workloadのlocation-hint比較:

| location hint | clean mean | clean p95 |
| --- | ---: | ---: |
| `apac-ne` | 744.074 ms | 1,238.188 ms |
| `wnam` | 1,554.724 ms | 1,983.401 ms |
| `weur` | 1,830.777 ms | 2,472.400 ms |

`location_hint`はbest-effortで実coloを証明しない。各20 sampleなのでSLAではなく、東京clientから見た
配置傾向のbaselineである。敵対burst込みの`server_collection`はrate-limit検査経路であり、
render/input pathや通常checkpoint cadenceの下限には使わない。

### authority ACK settlement baseline

直前version `9553b23b-4ea0-47c5-836d-321ab7ee6f9b`を同じ`apac-ne` PvP条件で、seal開始から
authority ACKがsourceのdurable outboxへ保存されるまでを
20 run追跡した。20/20が`Accepted`、ACK timeoutは0件、全runで最初のpollにより完了を観測した。

| 経路 | mean | p50 | p95 | p99/max |
| --- | ---: | ---: | ---: | ---: |
| collection + quorum + seal | 1,241.528 ms | 1,063.771 ms | 1,884.616 ms | 1,893.033 ms |
| collection + quorum + authority ACK | 1,271.142 ms | 1,097.452 ms | 1,912.035 ms | 1,920.432 ms |
| seal開始からauthority ACK | 729.163 ms | 658.697 ms | 1,003.017 ms | 1,028.064 ms |
| seal応答後のACK観測差 | 29.613 ms | 29.505 ms | 35.884 ms | 40.834 ms |

最初の20-run試行では9件目でtimeoutし、本番tailから「新規isolateのalarmがMoonBit runtimeを
ロードせずACK gateを呼ぶ」反例を得た。dispatch入口にruntime loadを移した修正版deploy後、
authority commit済みの当該entryは4回目の試行でhistorical `Duplicate` ACKとして自動回復した。
その後の上記20 runは全件成功した。

branded runtime capabilityを追加した現行versionではdirect smokeも1/1 `Accepted`で、seal開始から
ACKまで678.542 msだった。`x-audit-checkpoint-dispatch: deferred`で初回RPCを意図的に保留した
alarm smokeも1/1 `Accepted`となり、seal応答から29,492.525 ms、233回目の100 ms pollでACKを観測した。
これはSLAではなく、lease expiryからalarm dispatchへ至るproduction action mappingの確認値である。

測定artifact:

- [`witness-remote-apac-ne-pvp-parallel-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-remote-apac-ne-pvp-parallel-2026-08-05.json)
- [`witness-remote-apac-ne-pve-parallel-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-remote-apac-ne-pve-parallel-2026-08-05.json)
- [`witness-remote-apac-ne-open-parallel-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-remote-apac-ne-open-parallel-2026-08-05.json)
- [`witness-remote-wnam-pvp-parallel-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-remote-wnam-pvp-parallel-2026-08-05.json)
- [`witness-remote-weur-pvp-parallel-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-remote-weur-pvp-parallel-2026-08-05.json)
- [`witness-remote-apac-ne-parallel-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-remote-apac-ne-parallel-2026-08-05.json)
- [`witness-remote-apac-ne-sequential-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-remote-apac-ne-sequential-2026-08-05.json)
- [`witness-authority-remote-apac-ne-pvp-direct-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-authority-remote-apac-ne-pvp-direct-2026-08-05.json)
- [`witness-authority-remote-apac-ne-pvp-deferred-2026-08-05.json`](../examples/cf-game-audit/benchmarks/witness-authority-remote-apac-ne-pvp-deferred-2026-08-05.json)

これは東京の単一client・単一egressからの測定である。HMAC fixed windowのfail-closedと回復は確認したが、
異なる実peer source間の公平性、NAT共有、botnet/IP churn、全地域のtail latencyは証明しない。

secret設定後は、新しいunit idにだけlocation hintを適用して測る。

```sh
cd examples/cf-game-audit
pnpm exec wrangler secret put ADMIN_TOKEN
pnpm exec wrangler secret put WITNESS_SOURCE_BUCKET_KEY
AUDIT_BASE_URL=https://converge-game-audit.mizchi.workers.dev \
AUDIT_ADMIN_TOKEN=<同じtoken> \
AUDIT_LOCATION_HINT=apac-ne \
pnpm bench

AUDIT_BASE_URL=https://converge-game-audit.mizchi.workers.dev \
AUDIT_ADMIN_TOKEN=<同じtoken> \
AUDIT_LOCATION_HINT=apac-ne \
AUDIT_WITNESS_BENCH_SOURCE_MODE=single-egress \
AUDIT_WITNESS_BENCH_APPROVAL_MODE=parallel \
pnpm bench:witness
```

## 残件の優先順

1. remote benchmarkを複数時刻・複数egressから実行し、p95/p99のrun間分散とsource間公平性を測る。
2. `apac-ne`、`wnam`、`weur`を各地域のclientから測り、client→hintの組合せを比較する。
3. experimental Ed25519とWorkers WebCrypto Ed25519を比較し、監査済みbackend境界を決める。
4. PvE bundle v2を拡張し、phase checkpoint、cooldown、player attack、boss HPを扱う。
5. open-world plan/sealのexternal transparency headへ、remote実測済みcheckpoint witness collectionを接続する。
6. marketplaceへancestry revocation、appeal window、checkpoint単位のmulti-asset head更新を追加する。
7. witness sourceをIP以外のdevice/session credentialへ結び、NAT-aware global fair queueとhistory pruningを実装する。
8. playtest telemetryを接続する。

ここで3、7はinfra contractと独立であり、remote baselineを始める阻害要因ではない。

## 保証ledger

| Claim | Evidence | 状態 |
| --- | --- | --- |
| accepted headとhistoryは同一SQLite transactionで進む | DO integration test、`transactionSync` | Tested locally |
| checkpoint sealはhistory/head/全outbox/closure消費を一括commitする | opaque MoonBit plan + SQLite transactionSync | Tested locally |
| seal途中の4 fault pointは全旧状態へrollbackする | history/head/outbox/closure fault injection | Tested locally |
| 必要destinationを縮小したretryは完全commitとして扱われない | config-bound destination regression test | Tested locally |
| seal成功後のactor abortでも全新状態が復元される | workerd abort/restart test | Tested locally |
| checkpoint初回送信をdirect RPCし、再送はdestinationごとの最古entryをlease付きで選ぶ | SQLite outbox scheduler + DO alarm + MoonBit retry contract | Tested locally + remote E2E |
| receiver boundary/initial headはcheckpoint受信前に固定される | admin設定時のdestination DO pre-provision + 未設定拒否test | Tested locally |
| source outboxにない自己整合Queue jobはauthorityを変更しない | mutation前exact outbox認証 + forged-job regression | Tested locally |
| producer署名・provision済みroster・必要quorumなしにcheckpointをseal/receiveしない | opaque MoonBit delivery capability + 実Ed25519 bridge + hostile receiver tests | Proven gate + Tested locally |
| authorityはexact nextを受理しhistory/headを一括更新する | receiver SQLite transaction + workerd integration | Tested locally |
| authority commit後にACKを失ってもhistorical Duplicateでsource outboxを完了できる | 2 epoch ahead + lost ACK workerd test | Tested locally |
| ACKはauthority/boundary/epoch/digestとAccepted/Duplicateを厳密照合する | MoonBit opaque ACK gate + source transaction | Proven core + Tested locally |
| eviction後もaccepted headが戻る | workerd eviction test | Tested locally |
| 正当署名された古いheadでもDOを初期化できない | configured initial epoch/parent regression test | Tested locally |
| fork受理時にheadは進まない | same-epoch fork integration test | Tested locally |
| 同じnext headが競合しても1回だけheadが進む | 8並行request integration test | Tested locally |
| Queue再送で中央jobが二重処理されない | SQLite outbox key + duplicate delivery test | Tested locally |
| forkは中央Queueへ自動投入される | fork/outbox integration test | Tested locally |
| anchor-only Queue jobはreplay verifiedにならない | 5条件artifact model + Worker classifier | Proven + Tested locally |
| central replay verifiedは全artifact条件を要求する | `verified_central_replay_requires_every_artifact` | Proven |
| 実暗号PvE bundleは全event認証と三root一致後だけverifiedになる | MoonBit verifier + workerd Queue integration | Tested locally |
| 実暗号PvP bundleは全event認証・三root一致・`n-f` witness後だけverifiedになる | MoonBit verifier + workerd Queue integration | Tested locally |
| 実暗号open-world v2 bundleは4 checkpoint・2 publication proofs・遅延seed・`n-f` observer・eligible inclusion・PvE replay後だけverifiedになる | MoonBit verifier + workerd Queue integration | Tested locally |
| open-world encounterが署名済みeligible sealに含まれる | Merkle capability + workerd integration | Tested locally |
| audit plan/sealが独立publisherのtransparency checkpointに含まれる | exact map membership capability + trusted head digest + workerd integration | Tested locally |
| TS側遷移がMoonBit proofと同じ | Worker bridgeがproved classifierを直接呼ぶ | Proven core + Tested bridge |
| current-owner listingはauthority checkpoint、`n-f` replay witness、origin receipt、inventory root membershipを要求する | MoonBit central verifier + real-crypto workerd integration + apac-ne benchmark | Tested locally + remote |
| per-asset inventory headはexact parent・epoch前進・owner/version整合なしに進まない | 6条件MoonBit predicate、64-case test、wrong-parent/version integration、apac-ne head advance | Proven + Tested locally + remote |
| Cloudflare apac-ne hintでcheckpoint/Queue/inventoryのend-to-end値を得られる | 64-head×3 mode remote benchmark | Measured once |
| remote peerからmode policyどおりquorumを収集する | 公開pull、端末ローカル署名submit、durable collection、deadline、collection-backed seal、HMAC-source fixed window、全mode apac-ne + PvP wnam/weur各20 run | 全mode remote E2E、outbound push・global fairnessはPending |
| checkpoint outboxを配送しACKで完了する | direct DO RPC、lease/alarm retry、historical Duplicate ACK | Tested locally + remote 20/20、本番ACK-loss回復を観測 |
| production cryptoである | unaudited experimental adapter | Unmet |

checkpoint transportはinternal DO RPCを通常の認証済みchannelとして扱い、Queue consumerを
後方互換経路として残す。receiver boundary/initial headは管理APIから事前provisionし、Queue jobはreceiver mutation前にsourceの
durable outboxと完全照合する。加えて管理APIでproducer keyとwitness roster/quorumを事前provisionし、
checkpointのboundary、destination、epoch、parent、digest、canonical envelopeに対するproducer署名と
witness承認をsource seal前とreceiver mutation前に検証する。remote peer向けにはproducer署名だけの
collectionをdurableに開始し、公開GET/端末ローカル署名POSTでapprovalを集め、ready collectionから
sealするpull型referenceを接続した。公開POSTにはhashed sourceごとの1秒8件fixed windowを適用し、
client指定の内部bucketを除去する。remoteでは単一egressの429回復後に並列quorumが100/100成立した。
outbound push、異なる実source間の公平性、NAT/botnetを含むglobal fair queueは未接続であり、
benchmark fixtureの秘密seedをproduction routeへ公開してはならない。
