# 検証可能リアルタイムゲーム監査 要求仕様

更新日: 2026-08-04

## 1. 目的と適用範囲

本仕様は、次の三者を接続するゲーム監査実装が満たすべき要求を定める。

1. プレイヤーごとのlocal-first DB
2. 同じparty、match、zone、encounterに属するpeer
3. 低頻度でcheckpointまたは完全replayを処理する権威サーバー

対象は1:N協力PvE、N:N敵対PvP、不規則なopen-world encounterである。リアルタイム表示を
中央承認待ちにせず、あとから操作列、状態遷移、item生成・所有権を検証できなければならない。

この文書では次の語を規範的に使う。

- **MUST**: 安全性または相互運用性に必要。満たさなければ受理してはならない。
- **SHOULD**: gameplay、費用、可用性のため原則必要。外す場合は理由と代替策を記録する。
- **MAY**: game固有の選択。

実装状況は `Proven`、`Tested`、`Implemented`、`Partial`、`Pending` で表す。`Proven`は
MoonBit/Why3のモデル内だけを意味し、暗号強度や分散livenessまで含まない。

## 2. 信頼モデル

### AUD-TRUST-001: 入力は原則として敵対的に扱う（MUST）

client、peer、Queue payload、保存済みbundleの内容を単独では信用してはならない。署名、session、
manifest、epoch、parent、root、roster、authority identityを信頼境界の外側から固定した期待値と
照合する。bundle自身がauthority keyやtrusted checkpointを選べてはならない。

状態: `Tested`。三modeのcentral replayとwire tamper testがある。

### AUD-TRUST-002: Byzantine保証はfault boundを明示する（MUST）

witness/observer方式はroster sizeを`n`、最大fault数を`f`として`n > 3f`を要求し、certificateは
異なるroster memberから`n-f`承認を要求する。`f`を超える結託時の正当性は保証してはならない。

状態: `Proven + Tested`。

### AUD-TRUST-003: 証拠不足と不正確定を区別する（MUST）

timeout、packet loss、partition、under-quorum、証拠期限切れはcheat確定ではない。結果を
`provisional`、`pending`、`central replayへ昇格`のいずれかにし、不可逆な経済状態へ入れない。

状態: 判定contractは`Proven + Tested`、production appeal運用は`Pending`。

## 3. 汎用converge監査contract

### AUD-CORE-001: game固有規則を汎用層へ入れない（MUST）

`src/audit/`はcadence/retention、commitment射影、head分類、Merkle/authenticated-map、
application非依存の署名quorum・checkpoint配送・永続runtime契約だけを扱う。
cooldown、hit、visibility、score、loot、sampling rate等はgame packageが定義する。

状態: `Implemented`。

### AUD-CORE-002: checkpoint policyはfail-closedに開く（MUST）

有効なpolicyは次の包含関係を満たさなければならない。

```text
0 < event interval <= micro interval <= macro interval
macro interval <= event retention <= micro retention <= macro retention
```

不正なpolicyから`VerifiedCheckpointPolicy`を構築できてはならない。

状態: `Proven + Tested`。

### AUD-CORE-003: 共通checkpoint commitmentを固定する（MUST）

game固有checkpointは少なくとも次を共通contractへ射影する。

- scope/session ID
- epoch
- previous checkpoint digest
- game/rule manifest digest
- event root
- public state root
- effect/item-delta root
- hidden/sealed state commitment（必要な場合）

異なるsession、manifest、epoch、parentのrootを流用できてはならない。

状態: adapter contractは`Implemented + Tested`。各gameの意味的一致はgame testの責務。

### AUD-CORE-004: headはexact next parentだけ進める（MUST）

head更新は境界一致、未知の次epoch、`incoming_epoch = current_epoch + 1`、parent一致をすべて
満たす場合だけ`Advance`にする。同一digestの再送は`Duplicate`、同一epochの異digestは
`SameEpochFork`、次epochのwrong parentは`ParentFork`、飛び越しは`Gap`、過去は`Stale`とする。
境界不一致だけで相手をforkと告発してはならない。

状態: `Proven + Tested`。旧game classifierとの400組合せ互換testあり。

### AUD-CORE-005: 証拠精度を保持階層から計算する（MUST）

event、micro root、macro rootの順に証拠をpruneしてよいが、返せる局所化精度を過大表示しては
ならない。ageを`a`、intervalを`δ, μ, T`とすると精度は次のとおりとする。

```text
a <= event retention : δ
a <= micro retention : μ
a <= macro retention : T
otherwise             : evidence unavailable
```

負のage、期限切れ、矛盾したlatency入力はfail-closedにする。

状態: `Proven + Tested`。実際のpruning workerは`Pending`。

### AUD-CORE-006: compact proofの計算量を境界化する（SHOULD）

macro内event leaf数は`ceil(T/δ)`、一leafへのMerkle descentは
`ceil(log2(ceil(T/δ)))` round以下とする。proof検証はtree全体の再送を要求してはならない。

状態: 算術API、Merkle/AuthMap、watermark駆動の階層builder、game checkpointへのroot adapterは
`Implemented + Tested`。player-local論理DBとNode SQLite relation/restartは追加済みだが、
物理DBからwatermark/proof nodeを供給する実運用接続は`Pending`。

## 4. eventとreplay

### AUD-EVENT-001: eventをsessionとauthorへ拘束する（MUST）

eventはcanonical payload、session、author key、counter、causal dependency、digest、signatureを
検証してから認証済み型へ昇格する。未登録key、hash不一致、署名不一致、foreign sessionは拒否する。

状態: `Implemented + Tested`。

### AUD-EVENT-002: equivocationを吸収的に扱う（MUST）

同じauthor/counterまたは同じ署名slotへ異なるdigestが現れた場合、equivocation evidenceを生成し、
どちらか一方を到着順で正当化してはならない。duplicateはidempotentでなければならない。

状態: merge predicateは`Proven + Tested`。`PlayerLocalAuditStore`も同一author/counterの
既存eventを上書きせず、equivocation evidenceをrestart可能なimageへ保持する。

### AUD-EVENT-003: causal dependency不足を正当なeventとして適用しない（MUST）

依存eventが未着ならbufferまたはgap recoveryへ送り、依存関係が満たされるまでgame stateへ適用しない。

状態: in-memory BFT adapterは`Tested`。bounded fanout、指数retry、backpressure、
認証済みresponse/fork選択はpure runtime contractとして`Tested`。production socket transportは`Pending`。

### AUD-REPLAY-001: 正当性はdeterministic kernelで決める（MUST）

CRDT convergenceや署名の正しさだけでgame操作を合法としてはならない。game manifestに固定した
deterministic kernelが全入力を再生し、event/state/effect rootがcheckpointと一致した場合だけ
replay capabilityを生成する。

状態: prototype kernelは`Tested`。実ゲーム全規則への拡張は`Pending`。

### AUD-REPLAY-002: 許される並び替えを明示する（MUST）

独立操作、set/merge、同一epochの同時commandなど、可換性を定義した操作だけをcanonical orderへ
並び替えてよい。因果依存、cooldown消費、乱数seed、ownership transferを任意順に並び替えてはならない。

状態: PvP epochとattestation mergeは`Proven/Tested`。一般的なgame action algebraはgame側の責務。

### AUD-REPLAY-003: canonical wireを有界にdecodeする（MUST）

version、byte数、text長、item数、proof depth、page count、宣言長をallocation前に検査し、
非canonical encoding、truncation、未知version、予算超過を拒否する。

状態: `Proven + Tested`。

## 5. game mode別要求

### 5.1 1:N cooperative PvE

- `AUD-PVE-001`（MUST）: attackは事前にtelegraphされ、attack ID、発生tick、範囲、判定窓をmanifestへ固定する。
- `AUD-PVE-002`（MUST）: dodge/inputは署名intentとreceiptを持ち、client timeだけで成功判定しない。
- `AUD-PVE-003`（MUST）: HP、生死、clear、survivor、lootを同じdeterministic replayから導出する。
- `AUD-PVE-004`（MUST）: lootはclear、living recipient、checkpoint-bound effectの全条件なしに生成しない。
- `AUD-PVE-005`（MUST）: party全員が結託できる場合、peer署名だけで取引可能itemを確定しない。中央sample、独立witness、またはauthority receiptを要求する。

状態: prototype encounter/lootと、defense/damage phaseを分けたboss HP・署名済みplayer attack・
cooldown・boss clear reference kernelは`Proven + Tested`。raid wire/central replay/loot bindingと
overlap mechanicは`Pending`。

### 5.2 N:N adversarial PvP

- `AUD-PVP-001`（MUST）: player/team/referee/witness roster、rule manifest、fault boundをmatch開始前に固定する。
- `AUD-PVP-002`（MUST）: 同一epochのmove/attackは配送順ではなく公開された同時解決規則で処理する。
- `AUD-PVP-003`（MUST）: scoreは敵対原因によるalive-to-defeated遷移からのみ増加する。
- `AUD-PVP-004`（MUST）: equivocationしたplayer/witnessを有効command/approvalへ数えない。
- `AUD-PVP-005`（MUST）: peer finalityはcheckpoint、referee、manifestへ拘束された`n-f` witness certificateを要求する。
- `AUD-PVP-006`（MUST）: challenge、fork、under-quorum、高価値rank結果は中央replayへ昇格する。

状態: 公開状態epoch kernel、cooldown、単独capture objective、witness gateは`Proven + Tested`。
visibility、projectile、wire/manifest migrationは`Pending`。

### 5.3 irregular open world

- `AUD-OW-001`（MUST）: encounter結果を知る前にregistration slotとencounter digestを予約する。
- `AUD-OW-002`（MUST）: sampling seedはeligible setをsealした後に公開するcommit-revealとする。
- `AUD-OW-003`（MUST）: observer certificateは登録を証明するだけで、gameplay正当性を証明したと扱わない。
- `AUD-OW-004`（MUST）: plan、seal、registered count、Merkle root、AuthMap rootを同じepochへ拘束する。
- `AUD-OW-005`（MUST）: authority単独の履歴差替えを抑えるため、独立transparency publisherによるplan/seal publication proofを要求する。
- `AUD-OW-006`（MUST）: sample、challenge、equivocation、高価値、sparse economic outcomeは完全中央replayへ送る。
- `AUD-OW-007`（SHOULD）: 通常のunsampled outcomeはmanifest-bound witness certificateでprovisional finalityを得てよい。
- `AUD-OW-008`（MUST）: signing observerは署名を返す前にslot予約をatomicかつdurableにcommitする。

状態: selection/conflict/publication/central replay contractは`Proven + Tested`。公開pull、端末ローカル署名、
submit、durable quorum、sealまでのreference fanoutは`全mode Tested locally + remote E2E`。加えて
player-local SQLite leaseからMoonBit policyを経由するbounded HTTP pushをloopbackで検査した。
production端末のdurable observer signing store、実credential付きpersistent socket、異なる実source間の
global fairnessは`Pending`。

## 6. item、inventory、marketplace

### AUD-ASSET-001: item生成をreplayへ拘束する（MUST）

item ID、recipient、kind、quantity、origin checkpoint、effect digestをcanonical effectとして生成し、
検証済みclear/reward ruleとeffect rootへ一致した場合だけcreation receiptを発行する。

状態: `Proven + Tested`。

### AUD-ASSET-002: listing時にoriginとcurrent ownerを検証する（MUST）

marketplace listingはauthority checkpoint、game manifest、witness certificate、origin receipt、
current owner/version、inventory root membershipを照合する。proof省略時も保存済みcurrent owner以外を
許可してはならない。

状態: `Tested locally + remote benchmark`。

### AUD-ASSET-003: inventory headをrollbackさせない（MUST）

assetごとのheadはeligible creation、proof成功、manifest一致、exact parent、epoch前進、
owner/version整合をすべて満たす場合だけtransactionで更新する。再送はidempotentにする。

状態: predicateは`Proven`、Durable Object integrationは`Tested locally`。

### AUD-ASSET-004: 後発rejectionを子孫へ伝播する（MUST for production）

originまたはtransferが後からreject/revokeされた場合、descendant ownershipとlisting eligibilityを
無効化し、appeal結果に応じて再計算する。

状態: `Pending`。現状の`eligible`は完全なancestry保証ではない。

## 7. 永続化、配送、障害時動作

この節の具体的な型、DB relation、transaction境界、ACK/retry状態遷移は
[persistence / transport実装契約](./game-audit-implementation-contract-ja.md)を規範とする。

- `AUD-OPS-001`（MUST）: signing reservation、head更新、inventory更新はcompare-and-setまたはDB transactionでatomicにする。
- `AUD-OPS-002`（MUST）: gap batchの一要素でも不正なら、正しかったprefixを含め一切commitしない。
- `AUD-OPS-003`（MUST）: Queue/outboxはat-least-once配送を前提にidempotency keyを持つ。
- `AUD-OPS-004`（MUST）: crash/restart後にtrusted anchor、head、outbox、replay result、inventory headを復元できる。
- `AUD-OPS-005`（MUST）: pruningはappeal windowと最悪replay時間を超えるまで必要証拠を消さない。
- `AUD-OPS-006`（SHOULD）: partition解消後、正直なreplicaは同じ認証済みheadへ収束する。

状態: SQLite Durable Object、中央replay Queue/idempotent outbox、checkpoint sealとatomicなoutbox、
direct authority RPC、lease/alarm retry/ACK、restart testは`Tested locally + remote E2E`。
2 peer・2 epochのTLA+有限モデルではcrash/drop/partitionとbounded outbox下の安全性、network安定後の
authority finalityを`Model checked`。player-local論理DBとNode SQLite参照adapterの
atomic seal/restart/ACK/破損検知は`Tested`。observer DB、IndexedDB/mobile SQLiteへのproduction接続、
witness quorum収集は公開pull/署名submit型referenceと有限TLA+モデルまで`Tested locally / Model checked`。
端末側のローカル署名clientとhashed sourceごとのfixed-window隔離は`Tested locally + 全mode remote E2E`。
東京clientから全modeの`apac-ne`、PvPの`wnam`/`weur` hintを各20 run測り、単一egressのrate-limit
回復後に並列3/4 quorumとsealが100/100成立した。
bounded HTTP outbound referenceは実装済みだが、persistent socket、NAT/botnetを含むglobalな
公平queueingのproduction分散livenessは`Pending`。

注意: Cloudflareの`replay_outbox`は中央replay job用、`checkpoint_outbox`はplayer checkpointを
sealと同じtransactionで保存するserver-side referenceである。端末側には別途Node SQLite参照adapterを追加した。
checkpoint経路には実暗号producer/witness検証と
公開pull/ローカル署名/submit収集とNode SQLite端末DB参照adapterも接続済みだが、
production端末runtime・実credentialへの統合とpersistent socket fanoutは未実装である。

## 8. realtime性とゲーム表現

- `AUD-UX-001`（MUST）: movement、VFX、hit marker、回避feedbackをmacro checkpoint待ちで停止しない。
- `AUD-UX-002`（MUST）: display state、provisional result、economic finalityを別stateとして表現する。
- `AUD-UX-003`（SHOULD）: telegraph、projectile travel、charge/release、parry window、capture/hold、seed固定waveのように、検証可能な時間窓を面白さとして見せる。
- `AUD-UX-004`（SHOULD）: rollbackは見た目の位置補正より、rank、報酬、取引可能化、appeal状態へ主に適用する。
- `AUD-UX-005`（MUST）: clientだけが知るhidden stateや1-frame判定から、第三者検証なしに不可逆assetを生成しない。
- `AUD-UX-006`（MUST）: quorumに必要なpeer approvalは並列収集し、収集待ちをrender/input pathへ置かない。

event intervalはrendering frameやserver packet frequencyではない。現presetは次のとおりだが、
game実測により変更してよい。

| mode | event | micro | macro | event/micro/macro retention |
| --- | ---: | ---: | ---: | --- |
| N:N PvP | 16 ms | 250 ms | 2 s | 60 s / 5 min / 1 day |
| 1:N PvE | 33 ms | 1 s | 15 s | 2 min / 10 min / 1 day |
| open world | 50 ms | 2 s | 30 s | 5 min / 1 h / 7 days |

一様到着を仮定するengineering estimateは、平均finalityが
`macro/2 + mean validation latency`、保守上限が
`macro + p99 validation latency`である。これはSLAではなく、実測latencyを代入する式である。

`validation latency`には、敵対burstを除く`collection start + parallel quorum + seal`のrun単位合計を
使う。東京→`apac-ne` hintの各mode 20 runから得た値を代入すると次になる。sampleが少ないため
p99ではなくp95を使った保守的engineering budgetでありSLAではない。

| mode | macro | clean seal mean / p95 | 平均event→seal | 保守値（macro + measured p95） |
| --- | ---: | ---: | ---: | ---: |
| N:N PvP | 2 s | 0.744 / 1.238 s | 1.744 s | 3.238 s |
| 1:N PvE | 15 s | 0.865 / 1.268 s | 8.365 s | 16.268 s |
| open world | 30 s | 0.756 / 1.348 s | 15.756 s | 31.348 s |

macro間隔よりquorumが遅くても、collectionをpipelineできればcheckpoint頻度を落とす必要はない。
ただし未確定epoch数、保持量、rank/報酬settlement期限はこのtailを吸収できなければならない。

## 9. securityとproduction gate

- `AUD-SEC-001`（MUST）: collision-resistant hashと監査済みsignature実装を使用する。
- `AUD-SEC-002`（MUST）: message種別、session、world、epoch、purposeをdomain separationへ含める。
- `AUD-SEC-003`（MUST）: private keyをclient bundleやsource treeへ置かず、custody、委任、rotation、失効を定義する。
- `AUD-SEC-004`（MUST）: replay、cross-session、cross-purpose、key substitutionをtamper testで拒否する。
- `AUD-SEC-005`（SHOULD）: witness/observer/transparency roleを同一failure domainへ集中させない。

状態: FNV/mockと`experimental_crypto` SHA-256/Ed25519接続は`Implemented + Tested`だが未監査。
したがってproduction security gateは`Pending`。

## 10. 受入条件

### 10.1 converge汎用library

次をすべて満たしたとき汎用層を受入可能とする。

1. game名・game固有数値・game state型が`src/audit/`の公開APIへ入っていない。
2. 不正policyからverified capabilityを構築できない。
3. checkpoint adapterが共通commitment全fieldを拘束する。
4. head exact-next、fork、gap、stale、boundary mismatchが証明・testされる。
5. Merkle/AuthMapの正常・改ざん・不存在proof testが通る。
6. `moon info`の公開interface差分が意図どおりである。

### 10.2 個別game実装

gameごとに次を定義しなければならない。

1. canonical manifestとversioning
2. actor/roster/trust anchor/fault bound
3. event schema、署名purpose、causal relation、可換性
4. deterministic replay kernelとroot計算
5. checkpoint/retention/appeal policy
6. peer finality条件とcentral escalation条件
7. asset生成・移転・revocation規則
8. client上のprovisional/final/rejected表現
9. storage/transport failure時のfail-closed動作
10. cost、latency、proof size、central replay率のKPI

### 10.3 現在の回帰guard

```sh
moon check --target all
moon test
just prove
just tla-check
just tla-counterexamples
pnpm --dir examples/cf-game-audit test
pnpm --dir examples/cf-game-audit typecheck
pnpm --dir examples/cf-game-audit deploy:dry
moon info && moon fmt
```

2026-08-05時点の基準値はMoonBit test、MoonBit prove、workerd testの直近成功出力を
source of truthとする。件数は機能追加で増えるため固定しない。

## 11. 未充足のproduction必須項目

優先順は次のとおり。

1. 監査済みcrypto、key custody、rotation/revocation
2. observer signing store、IndexedDB/mobile SQLite player DB、migration/fsync/暗号化at-rest
3. remote witness/transparency socket fanoutと端末credential（pure retry/fork選択は実装済み）
4. ancestry revocation、appeal window、multi-asset atomic checkpoint
5. projectile/visibility、raid lootを含む実ゲームkernel完全化とmanifest/wire migration
6. packet loss、partition、crash、Queue重複を含むfault-injection
7. TLA+モデルを複数authority shard、pruning/appealへ拡張（bounded outboxは完了）
8. 実プレイtelemetryとrollback納得感のplaytest

現時点ではprototypeの受理条件と局所的不変条件は強く検査されているが、production-readyという
仕様は満たしていない。

## 12. contract ledger

| source | expected claim | model/check | machine result | decision/lock |
| --- | --- | --- | --- | --- |
| `src/audit` | invalid policy、非exact head、late event、incomplete/conflicting closure、binding不一致ACK、非atomic seal、署名/quorum不足のdelivery、非収束vote mergeは受理不能 | MoonBit prove | 39 goals proved | `just prove-audit-core` |
| `src/audit/runtime` | capabilityなしclosure、不完全seal、ACK不一致、local restart欠損、peer retry飢餓/fork raceを防ぐ | runtime contract | 20 tests passed | `just test-audit-runtime` |
| `src/audit/layered` | arrival order/retryに依存せず、budget超過時は無変更 | runtime contract | 5 tests passed | `just test-audit-layered` |
| `src/x/game_audit/audit` | game finality、replay、open-world、asset、cooldown/objective/raid clear gateがfail-closed | MoonBit prove | 161 goals proved | `just prove-game-audit` |
| game runtime packages | game classifierと汎用classifierが等価 | bounded exhaustive test | 400 combinations passed | `moon test src/x/game_audit/policy` |
| Cloudflare adapter | Queue成功だけでverifiedにならず、seal途中のfaultで部分commitせず、producer/witness認証失敗でsource/receiverを変更しない | workerd integration + pure metric/capability test | 42 tests passed | `pnpm --dir examples/cf-game-audit test` |
| checkpoint transport | durable bounded outbox、retry、exact-parentによりnetwork安定後authorityがlatest epochへ到達する | TLA+/TLC、2 peer・2 epoch、crash/drop/partition | 11,340 distinct states、反例なし。capacity gateを外すbroken modelも反例 | `just tla-check && just tla-counterexamples` |
| witness collection | producer/roster/quorum/expiry/fairnessなしにreadyやreceiver更新へ進まない | TLA+/TLC、4 roster + 1 intruder | safety 30,720、liveness 19,456 distinct states、反例なし。2 broken gateは期待どおり反例 | `just tla-check && just tla-counterexamples` |
| witness source isolation | 同一sourceのinvalid floodは別sourceのquorum quotaを消費せず、client指定bucketを信用しない | workerd integration + local 20 run + remote単一egress20 run | HMAC secret欠落時503、local別source quorum 20/20、remote 429回復後quorum 20/20。異なるremote source間公平性は未測定 | `pnpm --dir examples/cf-game-audit bench:witness` |
| remote checkpoint/witness infrastructure | Worker、direct authority RPC、durable retry、replay Queue、両Secret、公開route | current `a3c07778-037d-40cf-b2e9-5ad55afdec91`、direct 20-run + deferred alarm smoke artifacts | Deployed + authority ACK 20/20、現行version direct/deferred各1/1 | [Cloudflare実測](./cloudflare-game-audit-ja.md) |
| production crypto | signature/hashが攻撃耐性を持つ | security audit未実施 | unresolved | audited backendなしにproduction claimを禁止 |
