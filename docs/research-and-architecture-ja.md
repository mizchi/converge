# CRDT 接続型リアルタイムゲーム検証: 研究とアーキテクチャ

更新日: 2026-08-04

## 目的

プレイヤーごとの local-first DB、同じ session/party/match に所属する peer、
権威サーバーを接続し、次を低いオンラインコストで実現する。

- PvE/PvP の操作をリアルタイムに表示する。
- 不正な操作や矛盾する履歴を拒否または事後検出する。
- 全 frame を永久保存せず、checkpoint と Merkle root で履歴を圧縮する。
- boss clear や所有権移転を再実行し、正当な item だけを marketplace に出せる。
- 独立な event の到着順が違っても、同じ確定結果へ収束する。
- 受理境界を MoonBit verification で証明し、将来は必要な数学的核を Lean へ移す。

最も重要な非目標は、CRDT convergence を game rule の正当性と同一視しないこと
である。CRDT は replica が同じデータ集合へ収束するための層であり、その操作が
cooldown、位置、視界、loot rule に従うかは deterministic game kernel が判断する。

## リポジトリ上の境界

CRDTへ接続する汎用のByzantine-aware event検証は `src/bft/` に置く。ゲームに依存しない
checkpoint cadence/retention、commitment射影、head分類、Merkle/authenticated-mapは
`src/audit/` に置く。一方、mode別preset、participant voteをgame finalityへ接続するadapter、asset replay、inventory、
marketplace、dungeon encounterは一つのゲーム監査設計に依存するため、
`src/x/game_audit/` の実験的namespaceに隔離する。この境界により、汎用contractを再利用しつつ
CRDT本体へgame ruleを持ち込まない。

## 文献マップ

### CRDT と Byzantine convergence

#### Shapiro et al., Conflict-Free Replicated Data Types, 2011

- 一次資料: [INRIA RR-7687](https://inria.hal.science/inria-00609399/document)
- 主張: state-based/operation-based CRDT が coordination なしに収束するための条件を
  与える。
- 採用: operation の可換性、idempotence、causal delivery を基本モデルにする。
- 非採用/限界: 通常の CRDT model は malicious peer が署名、依存関係、規則を
  偽る場合の game validity を保証しない。

#### Kleppmann and Howard, Byzantine Eventual Consistency, 2020

- 一次資料: [arXiv:2012.00472](https://arxiv.org/abs/2012.00472)
- 主張: Byzantine causal broadcast を基礎に Byzantine Eventual Consistency を
  定義し、任意数の Byzantine node を許せる application class を整理する。
- 採用: causal history を content hash で結び、矛盾した history を観測可能にする。
- 限界: arbitrary Byzantine tolerance はすべての game invariant や公平な勝敗を
  自動的に保証する意味ではない。

#### Kleppmann, Making CRDTs Byzantine Fault Tolerant, 2022

- 一次資料: [PaPoC 2022 paper](https://martin.kleppmann.com/papers/bft-crdt-papoc22.pdf)
- 主張: hash graph と Byzantine causal broadcast により、既存 CRDT を比較的小さな
  変更で Byzantine fault tolerant にする。
- 採用: `SignedEvent` が session、event、causal dependency digest をまとめて署名し、
  `(peer, counter)` の equivocation を検出する現在の `BFTAdapter`。
- 限界: hash/signature の暗号強度は別の実装責任である。

#### Chai and Zhao, Byzantine Fault Tolerance for Services with Commutative Operations, 2014

- 一次資料: [DOI 10.1109/SCC.2014.37](https://doi.org/10.1109/SCC.2014.37)
- 主張: commutative operation を使う service で、常時 total order を要求せず、
  periodic/on-demand Byzantine agreement によって replica を同期する。
- 採用: gameplay の全 operation を consensus に載せず、checkpoint/finalization だけを
  強い合意境界にする。
- 差異: 論文の replicated server model と、untrusted player を含む本設計の
  peer/authority topology は同一ではない。

### 公平な game event agreement

#### Baughman and Levine, Cheat-Proof Playout, 2001

- 一次資料: [公開 PDF](https://www.cs.ubc.ca/~krasic/cpsc538a/papers/baughman01cheatproof.pdf)
- 主張: real-time distributed game の lookahead、message suppression、順序操作を
  分析し、commit/reveal と asynchronous synchronization による fair playout を示す。
- 採用: 同時選択、draft、loot roll、target commit など、wind-up が許される境界で
  commit/reveal を使う。
- 非採用: 毎 frame の移動へ pessimistic lockstep を適用すると latency が直接操作感に
  出るため、通常移動には使わない。

#### Corman et al., Secure Event Agreement (SEA), 2006

- 一次資料: [DOI 10.1109/ARES.2006.15](https://doi.org/10.1109/ARES.2006.15)
- 主張: session、sender、round を暗号的に bind し、commit と vote により replay、
  timestamp、suppression、inconsistency cheat を扱う。
- 採用: session-bound canonical serialization、participant vote、equivocation を
  吸収状態にする設計。
- 限界: majority vote は participant selection/collusion の仮定に依存する。
  現在の approval collector は汎用 Byzantine consensus の実装ではない。

### Accountability と deterministic replay

#### Haeberlen et al., PeerReview, 2007

- 一次資料: [SOSP paper/technical report](https://haeberlen.cis.upenn.edu/papers/peerreview-tr.pdf)
- 主張: node が送受信した message の tamper-evident record を保持し、決定的な
  reference implementation で再実行すると、観測された Byzantine deviation を
  faulty node に結び付けられる。
- 採用: signed event、checkpoint、sealed replay kernel、replay 後にだけ得られる
  capability を分離する。
- 限界: 完全な全ログを永久保存する代わりに checkpoint で prune するため、snapshot
  recovery と checkpoint 間の完全 transcript の規則を別途定義する必要がある。

#### Haeberlen et al., Accountable Virtual Machines, 2010

- 一次資料: [USENIX OSDI 2010](https://www.usenix.org/conference/osdi10/accountable-virtual-machines)
- 主張: VM 全体の execution log と deterministic replay により、変更していない
  binary も監査対象にできる。Counter-Strike を用いた cheat detection も評価する。
- 採用: 「入力を分類するより、正しい state transition を再実行する」という方向。
- 非採用: VM 全体の記録は本用途には重い。経済・勝敗に影響する小さな game kernel
  だけを監査する。

#### SelectAudit: Probabilistic verification for networked virtual environments

- 一次資料: [著者公開 PDF](https://people.cs.vt.edu/~danfeng/papers/nve.pdf)
- 主張: Merkle tree で execution state を commit し、audit server が選択した状態だけを
  再計算することで、全状態を常時検査しない probabilistic verification を構成する。
- 採用: open-world encounter の中央 deterministic replay を無作為抽出し、未抽出の
  通常結果は peer certificate で処理する。
- 追加条件: 本設計では sampling seed を plan 時に commit し、eligible encounter の
  Merkle root を close checkpoint で固定した後にだけ seed を reveal する。これは
  抽選対象を公開後に作り直す grinding を避けるために加えた設計上の推論である。

#### A Peer Auditing Scheme for Cheat Elimination in MMOGs

- 一次資料: [論文 PDF](https://citeseerx.ist.psu.edu/document?doi=57f6fb0dc6b7ab61d395de7c0d5e5b5e71179e45&repid=rep1&type=pdf)
- 主張: central authority を残しながら peer に game-state audit を分担させる hybrid
  architecture を提案する。
- 採用: peer witness を安価な通常経路、challenge・証人不足・高価値結果を中央 fallback
  とする非対称な分担。
- 限界: 論文の simulation、trust、network 条件は現在の実装と同じではないため、報告
  された server 削減率を本 prototype へ外挿しない。

### リアルタイム表示と latency masking

#### Valve, Source Multiplayer Networking

- 一次資料: [Valve Developer Community](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking)
- 主張: server simulation tick、snapshot interpolation、client-side prediction、
  server-side lag compensation を分離する。重要な hit decision を client の自己申告に
  任せない。
- 採用: render clock と audit tick を分離し、local animation は即時、被弾/loot は
  bounded replay で確定する。
- 差異: 本設計は client time を authority-signed receipt で挟み、後日の再検証へ
  使える証拠にする。

#### Colyseus, Donnybrook, Outatime

- 一次資料:
  - [Colyseus: A Distributed Architecture for Online Multiplayer Games](https://www.usenix.org/legacy/event/nsdi06/tech/full_papers/bharambe/bharambe_html/main.html)
  - [Donnybrook: Enabling Large-Scale, High-Speed, Peer-to-Peer Games](https://www.microsoft.com/en-us/research/publication/donnybrook-enabling-large-scale-high-speed-peer-to-peer-games/)
  - [Outatime: Using Speculation to Enable Low-Latency Continuous Interaction](https://www.microsoft.com/en-us/research/publication/outatime-using-speculation-to-enable-low-latency-continuous-interaction-for-cloud-gaming/)
- 採用: weakly consistent view、interest management、local speculation は、監査対象を
  狭くしたまま知覚 latency を下げるために使う。
- 限界: prediction/speculation は authoritative correctness の代替ではない。誤予測は
  表示上 reconcile し、経済状態へ直接 commit しない。

### 形式検証

#### MoonBit Formal Verification

- 一次資料: [MoonBit documentation](https://docs.moonbitlang.com/en/latest/language/verification.html)
- 採用: executable `.mbt` と logic-side `.mbtp` を分け、predicate、pre/postcondition、
  lemma を Why3/Z3 で検証する。
- 現在の範囲: checkpoint decision、transfer、source capability、replayed effect、
  telegraph dodge gate、整数 tick の reaction/receipt bound、encounter の HP・clear・
  loot gate、checkpoint-bound replay capability、N:N replay witness quorum、
  open-world seal の truncation/substitution/missing-slot conflict policy、
  registration observer の `n > 3f`, `n-f` quorum policy、同一 plan/slot の
  二重署名拒否 decision、observer anchor publication、anchor head 遷移、wire admissionの
  byte/canonical/version/shape/text/proof/item、central replay artifact、公開PvP gate、open-world中央検証の
  trusted boundary/transparency publication/plan/seal/registration/inclusion/replayとmarketplace永続化の
  fail-closed条件、inventory headのeligible/proof/manifest/parent/epoch/owner-version条件。game audit
  161 proof goals。加えて汎用audit policy/head/event-time/closure/ACK/atomic seal/
  delivery authenticationとvote semilatticeの包含・精度・exact-next・late-event・
  fail-closed/収束条件が39 goals、計200 goals。
- 限界: verifier は数学整数を使うため machine integer overflow を証明しない。暗号の
  collision resistance、signature unforgeability、game kernel 全体の determinism も
  現在の proof 外である。

## 統合アーキテクチャ

```text
player-local DB
  raw signed events / receipts / checkpoints / proofs / current inventory
       │
       ▼
session-bound BFT adapter ───── peer mesh / party / match witnesses
       │                              │
       ▼                              ▼
AuthenticatedEvent             approvals / challenges
       │                              │
       ├── player-local auditable DB  │
       │          │                   │
       │          ▼                   │
       │   watermark builder          │
       │     │ micro root → peers     │
       │     └ macro root ────────────┤
       │                              │
       └──── deterministic game replay ────┐
                                           ▼
                                      authority/referee
                                           │
                                           ▼
                                   finalized checkpoint
                                           │
                                           ▼
                              inventory / marketplace gate
```

データ層は三つに分ける。

| 層 | 内容 | 整合性 |
| --- | --- | --- |
| ephemeral/render | 補間位置、cursor、VFX、camera、予測表示 | lost update を許容 |
| auditable input | skill intent、telegraph、receipt、seed、離散 keyframe | 署名・因果・replay |
| economic state | clear、loot、ownership、market listing | finalized checkpoint 必須 |

公開 capability pipeline は次の通り。

```text
SignedEvent
  -> AuthenticatedEvent
  -> sealed AssetReplayKernel (game-specific path binds checkpoint)
  -> ReplayedAssetEffect
  -> Merkle-bound inventory transition
  -> FinalizedCheckpoint
  -> marketplace acceptance
```

private-field capability により、raw event、拒否済み event、任意実装の allow-all kernel、
未確定 checkpoint から downstream の権限を直接構築できないようにする。

## 三つの時間

| Clock | 決めるもの | 保存方針 |
| --- | --- | --- |
| render clock | frame、animation、interpolation、local prediction | 原則保存しない |
| simulation tick | skill、回避、hit、cooldown、position keyframe | 結果に効く入力だけ |
| audit epoch | event set、state root、asset delta、pruning boundary | checkpoint を保存 |

`src/audit/layered`はsimulation tickやclient wall clockを直接信用せず、認証後に割り当てたaudit
event timeと単調watermarkを使う。watermark未満の遅着eventを拒否し、未確定window内はcanonical
sortするため、peerごとのarrival orderが違っても同じevent setから同じrootへ収束する。micro rootは
peer検査用、micro metadata/rootを束ねたmacro rootはauthority-facing game checkpointのevent rootにする。

予兆回避の現在の規則は次である。

```text
visible_tick + min_reaction_ticks <= client_tick < resolve_tick
client_tick <= authority_received_tick
authority_received_tick - client_tick <= max_backdate_ticks
abs(destination - committed_start) <= max_dodge_distance
```

player の `client_tick` だけは信用しない。player-signed input が telegraph digest を
因果依存に持ち、authority-signed receipt が input digest と受信 tick を bind する。
checkpoint の `event_root` は replay に渡された exact event set の Merkle root と一致
しなければならない。

## 1:N と N:N

| 項目 | 1:N PvE/MMORPG | N:N adversarial match |
| --- | --- | --- |
| telegraph author | authority server | referee または合意済み script |
| input receipt | authority signature | referee + peer witness/attestation |
| hidden state | authority が保持 | peer 全配布を避け、referee が visibility filter |
| fast path | authority replay | participant attestation |
| dispute | server replay | challenge + authority/referee replay |
| economic finality | finalized checkpoint | finalized checkpoint |

N:N でも完全 serverless を目標にしない。hidden state を全 peer に送れば wallhack を
protocol だけで防げず、少人数 session は十分な独立 witness を確保しにくい。
player 同士の相互検証は authority の計算を減らし、矛盾を検出する用途に使い、
visibility と最終判定には referee fallback を残す。

実装済みの N:N witness policy は、referee と witness roster を分離し、game manifest、
referee key、canonical roster、最大 Byzantine 数 `f` を session manifest に commit
する。有効条件は `n > 3f`、certificate threshold は `n - f` とした。このため、最大
`f` 人が不正ならcertificateにはhonest witnessが含まれ、二つのcertificate quorumの
交差にもhonest witnessが含まれる。通常のcheckpoint承認とreplay実行証言は署名domain
を分けており、相互に流用できない。

この保証は「honest witnessはcommit済みkernelを実行して一致した場合だけ署名する」
という仮定付きである。hidden stateは引き続きrefereeがvisibility filterし、peerへ
全配布しない。

この仮定のhonest-client側は、具体的な公開状態PvP kernelへ接続した。短いepochごとに
signed commandとreferee receiptをreplayし、移動、射程攻撃、HP、二teamのscoreを同時
batchで解決する。`PvpEpochResolution`とreferee checkpointが一致しない限り専用の
witness session/署名APIは構築できない。game manifestとwitness-policy manifestの
canonicalizationは共通packageを使い、同じcheckpoint fieldへ異なる意味を持たせない。
詳細は[公開状態 PvP epoch と N:N 相互検証](./pvp-epoch-ja.md)を参照する。

8-player matchで宣言できる上限は`f=2`・quorum=6、10-player matchでは`f=3`・
quorum=7である。チーム全体のcollusionをfault modelへ含めるならplayerだけでは不足する
ため、独立運営observerや遅延replay workerをwitness rosterへ加える必要がある。これは
Sybil resistanceとwitness選定を暗号署名の外側に残す明示的な運用条件である。

## 不規則 encounter の open-world audit

open world では固定 match roster がないため、近傍、party、zone observer から
encounter 単位の witness roster を作る。中央が毎 encounter を replay する代わりに、
次の順序で対象を抽出する。

```text
audit plan: game manifest + rate p/q + hidden seed commitment
            + indexed registry version + observer roster/fault-policy manifest
  -> irregular encounter checkpoints (epoch = registration slot)
  -> n-f observer receipts over (plan, slot, encounter digest)
  -> close manifest: registered count
  -> close checkpoint:
       event_root = Merkle root(slot || encounter digest)
       public_state_root = authenticated map root(slot -> encounter digest)
  -> seed reveal
  -> inclusion verification + deterministic sample
  -> peer finality / central replay / provisional / rejection
```

抽選対象 root を seed 公開より先に固定するのは必須である。commit 済み seed だけが
あっても、公開後に encounter id を作り直せれば都合のよい抽選結果を選べる。現在の
capability API は plan/close の同一 authority、session、連続 epoch、parent、派生 manifest、
proof index/count と tagged encounter digest の Merkle inclusion を検査する。

authority-signed slot が登録数以上なら末尾 truncation、同じ slot に別 digest の inclusion
proof があれば substitution、範囲内 slot の正しい authenticated-map non-membership proof
があれば missing-slot の opaque evidence capability を発行する。単なる proof 不足、偽 proof、
inclusion と non-membership の曖昧な同時提示は告発にしない。

この non-membership proof は署名済み registry 内の不在を示すが、authority が登録 stream
そのものを隠したことまでは単独では示さない。そこで plan に `n > 3f` の observer roster と
fault bound を commit し、`n-f` の署名済み registration receipt を opaque certificate にする。
この certificate と seal の truncation/substitution/non-membership を組み合わせれば、authority
自身の encounter checkpoint がなくても観測済み登録の隠蔽を conflict にできる。

この保証は「faulty observer は `f` 以下」「honest observer は受領・保存した一つの
slot/digest だけへ署名する」という仮定付きである。observer 到達前の遮断、plan roster の
Sybil 支配、receipt の永続化、動的 zone assignment は別途扱う。prototype は署名前に
`OpenWorldObserverSigningStore.reserve` を呼び、失敗時と別 digest 予約済み時には signer を
呼ばない。付属 in-memory adapter は共有 ledger 間の逐次 CAS をテストする。production で
process restart と並行 worker をまたぐには、同じ contract の durable atomic 実装が必要である。
復元時の trusted `(observer, key, root, size)` 完全一致は empty/foreign snapshot を拒否するが、
anchor は authority-verified checkpoint の key-unique authenticated map に batch 公開できる。
session、domain manifest、exact key/value membership を満たす場合だけ opaque capability が
作られる。head tracker は同一 epoch の別 digest と次 epoch の wrong parent を検出し、gap、stale、
別 session/publisher は告発しない。opaque capability 自体は送信せず、signed checkpoint、anchor、
authenticated-map membership proof の公開 envelope を送る。受信側は authority 署名と checkpoint
digest、session、domain manifest、exact key/value、membership path を再検証して capability を
復元する。gap request は受信済みの `(session, publisher, epoch, checkpoint digest)` と target/max 件数へ
固定する。参照 in-memory transport はこの cursor を index 化し、未整列入力から連続 page を返す。
response 全件を capability に戻してから temporary plan で一括反映するため、不正 envelope や途中失敗時は
prefix も commit しない。source ambiguity は未検証候補なので authority fork evidence と混同しない。
transparency headのproduction gossip/fanout、retry/backpressure、複数peer選択、remote head witness、
disk transactionは未実装である。checkpoint approval側には公開pull/ローカル署名submitとper-source
rate isolationの別referenceがあるが、このtransparency head transportを代替しない。

中央 replay は sample、signed challenge、certificate 不足の durable/tradable result、
および `HighValue` result に限定する。未抽出で challenge がなく、matching witness
certificate がある通常結果は peer finality に進める。certificate のない `Ephemeral`
result は表示上 provisional にできるが、資産や永続進行には接続しない。

この方式は中央署名をなくすものではなく、高価な game simulation replay の件数を
減らす方式である。indexed truncation/substitution、範囲内 non-inclusion、固定 roster の
observer registration certificate、signing-store boundary、anchor checkpoint publication は実装したが、zone/epoch
key の委任、動的 observer assignment、production durable store、checkpoint-head transport、local-first
DB の pruning は未実装である。詳細は
[不規則 encounter の選択的アンチチート](./open-world-audit-ja.md)を参照する。

## 面白さを損ねにくい制約

監査可能性と相性がよい表現:

- 予兆 AoE、projectile travel、charge/release、parry/rhythm window。
- capture/hold のように複数 tick を積算する目標。
- shield/poise のように一回の境界誤差を即死へ直結させない resource。
- hit/drop 演出は即時、取引可能化だけ checkpoint 後にする provisional feedback。
- deterministic seed を事前 commit する boss script と spawn wave。

避けるか監査境界から外す表現:

- chaotic rigid-body physics が高価値 item を直接生成する設計。
- 1 frame の body blocking/last hit だけで不可逆な経済結果が決まる設計。
- client のみが保持する hidden state を、peer replay で安全だと仮定する設計。
- 全 player の毎 frame 入力へ commit/reveal を強制する設計。

より詳しい表現案は
[検証可能なリアルタイムゲームの設計](./telegraph-game-design-ja.md)を参照する。

## 現在の計算量と実測

| Path | 計算量 |
| --- | --- |
| BFT event acceptance | dependency 数と短い payload/signature 検証に比例 |
| checkpoint quorum | `O(participants)` |
| replay witness certificate | manifest canonicalization `O(n log n)` + signature/merge `O(n)` |
| open-world sample selection | short tagged hash + `O(digest length)` bucketization |
| open-world eligibility | `O(log encounters in epoch)` Merkle inclusion |
| open-world observer certificate | roster canonicalization `O(n log n)` + receipt verification `O(n)` |
| observer signing ledger | new signature expected `O(log signed slots)`; exact retry/conflict expected map lookup; cached anchor check `O(1)` |
| observer anchor publication | build expected `O(observers log observers)`; one authenticated membership check expected `O(log observers)` |
| observer anchor head gossip | expected map lookup/update per head; accepted history storage `O(epochs retained)` |
| anchor head gap batch | `O(fetched heads)` validation + temporary `O(fetched heads)` plan, then one commit pass |
| wire anchor gap recovery | source index build expected `O(stored heads)`; page lookup `O(fetched heads)` + receiver verification expected `O(fetched heads * log observers)` |
| wire CBOR codec | `O(bytes + proof steps)` preflight/decode/re-encode validation; allocation is capped before crypto |
| open-world in-range omission evidence | expected `O(log registered slots)` authenticated-map non-membership |
| transcript root | expected `O(events)` dedup + `O(events log events)` canonical sort |
| telegraph replay | expected `O(players + evidence)` に加え上記 sort |
| multi-attack encounter | expected `O(attacks * players + evidence)` + canonical sort |
| Merkle inclusion | `O(log leaves)` |
| authenticated inventory lookup/update | expected `O(log assets)` |
| inventory plan | expected `O(changed assets log assets)` |

Apple M5、MoonBit `0.1.20260724`、FNV/mock signature での代表値:

| Benchmark | Mean |
| --- | ---: |
| checkpointed 8-player attack replay | 59.9 µs/attack |
| checkpointed 64-player attack replay | 446.7 µs/attack |
| 8-player × 8-attack encounter preparation | 465.9 µs/encounter |
| 64-player × 8-attack encounter preparation | 3.373 ms/encounter |
| 8 replay witnesses (`f=2`) certificate | 8.93 µs |
| 64 replay witnesses (`f=21`) certificate | 67.40 µs |
| canonical asset effect replay | 0.92 µs/effect |
| replay capability match | 0.085 µs/match |
| delayed open-world sample selection | 0.666 µs/encounter |
| Merkle-eligible provisional gate | 3.01 µs/encounter |
| false seal-conflict accusation rejection | 1.16 µs/encounter |
| 10,000-entry registry non-membership verification | 13.90 µs/proof |
| 4-observer (`f=1`) registration certificate | 6.01 µs/certificate |
| 10,000-slot observed omission detection | 28.36 µs/conflict |
| observer ledger new registration signature | 15.10 µs/signature |
| trusted observer signing anchor validation | 0.661 µs/restore |
| rolled-back observer signing store rejection | 0.525 µs/restore |
| conflicting observer signature rejection | 0.561 µs/rejection |
| 1,024-observer anchor publication verification | 12.45 µs/proof |
| authenticated anchor head advance | 0.142 µs/head |
| atomic anchor head gap recovery | 0.231 µs/head |
| wire envelope の fetch + 再認証 + atomic recovery | 4.42 µs/head |
| same-epoch anchor fork detection | 0.120 µs/evidence |

encounter 値は各攻撃について全 player の正当な署名済み dodge と authority receipt を
含む。event の署名検証は replay より前に完了しているため、この値には含まない。
wire recovery の 4.42 µs/head は 2026-08-04 の追加測定で、cursor lookup、checkpoint
再hash、mock署名検証、membership proof、capability 構築、atomic merge を含む。一方で
source index 構築、serialization、socket、disk I/O は benchmark loop 外である。

versioned wire codec と `experimental_crypto@0.0.2` adapterの追加実測:

| Benchmark | Mean |
| --- | ---: |
| 16-step CBOR envelope encode × 1,000 | 7.50 ms |
| preflight + 16-step CBOR envelope decode × 1,000 | 20.23 ms |
| 64-envelope gap page decode | 1.74 ms |
| SHA-256 short checkpoint record × 1,000 | 1.52 ms |
| experimental Ed25519 sign | 3.99 ms |
| experimental Ed25519 verify | 2.36 ms |
| real-crypto envelope decode + capability open | 2.29 ms |
| 2,585-byte PvE bundleの全署名検証 + replay + checkpoint照合（workerd DO） | 23 ms |
| 3,546-byte PvP bundleの全署名検証 + replay + 3/4 witness（workerd DO） | 36 ms |
| 6,178-byte open-world v2 bundleの4 checkpoint + 2 publication proofs + 3/4 observer + inclusion + replay（workerd DO） | 96 ms |

実暗号adapterは標準vectorを通るが、upstream自身が未監査・production非推奨としている。
single-leaf SHA-256/Ed25519 envelopeは1,064 bytesで、pure MoonBit経路は署名検証が支配的だった。
詳細なschemaとbudgetは[wire protocol v1 / open-world replay v2](./game-audit-wire-ja.md)を参照する。

これは production cryptography、disk I/O、packet loss、mobile hardware を含まない。
詳細は [checkpoint audit prototype](./game-audit-prototype.md)を参照する。

## Correctness ledger

| Claim | Source | Machine/implementation evidence | Status |
| --- | --- | --- | --- |
| CRDT convergence と game validity は別である | architecture contract | replay capability が別層 | Decided |
| accepted dodge は全 trust condition を必要とする | MoonBit contract | `telegraph_dodge_allowed` lemmas | Proven |
| accepted reaction は予兆後かつ resolve 前である | MoonBit contract | integer tick lemmas | Proven |
| client tick は future/backdate bound を破れない | MoonBit contract | receipt-bound lemmas | Proven |
| dodge evidence の順序で結果が変わらない | game-kernel contract | forward/reverse tests | Tested |
| checkpoint に commit 済みの input を省けない | checkpoint contract | event-root omission test | Tested |
| 生存者だけが deterministic loot を得る | replay contract | sealed loot-kernel tests | Tested |
| 複数攻撃で位置とHPを継承し、全計画からclearを導く | encounter contract | order/omission/death tests | Tested |
| encounter loot はclearかつHP正の場合だけ許可される | MoonBit contract | clear/loot lemmas | Proven |
| checkpoint がmanifest/event/public-stateの三つをreplay結果へ拘束する | encounter contract | forged-state/missing-attack tests | Tested |
| authority replay fallback は同一checkpoint・同一authorityの完全replay capabilityだけを受ける | replay/attestation contract | private capability、digest/authority mismatch tests、fail-closed lemmas | Tested + Proven boundary |
| N:N witness policy は `n > 3f` と `n-f` quorumを要求する | MoonBit contract | quorum/intersection/fail-closed lemmas | Proven |
| replay witness certificate は署名用途、manifest、checkpoint、refereeを横断できない | attestation contract | domain/manifest/identity regression tests | Tested |
| open-world peer finality は未抽出・challengeなし・matching certificateを要求する | MoonBit contract | routing lemmas と capability integration tests | Proven + Tested |
| seed公開後に追加したencounterはeligible rootを横断できない | open-world capability contract | plan/close binding と偽 inclusion test | Tested |
| open-world中央fallbackはsample/challenge/high-value/sparse economicを包含する | MoonBit contract | fail-closed routing lemmas と central replay integration test | Proven + Tested |
| seal truncation/substitution/missing-slotだけがauthority conflict capabilityを作る | MoonBit + capability contract | exact-slot/count/non-membership lemmas、改ざん・曖昧proof regression tests | Proven + Tested |
| registration observer policy は `n > 3f` と `n-f` quorumを要求する | MoonBit contract | policy/quorum/intersection/fail-closed lemmas | Proven |
| plan-bound observer quorum は authority checkpoint がない観測済み登録の欠落を告発できる | observer/seal capability contract | roster/plan/slot/digest/signature/foreign-plan tests | Tested + Proven boundary |
| 同一 observer の純粋判定は既存 plan/slot に別 digest を選ばない | MoonBit decision contract | never-sign-second lemma | Proven |
| store 予約は署名発行より先に成功する | signing-store API contract | failure 時 signer call-count=0、共有 store の競合 test | 参照実装/control flow は Tested、production durability は Assumed |
| trusted signing anchor は rollback/foreign restore を拒否する | restore contract | exact/empty/foreign snapshot tests | Tested |
| anchor 公開は identity/session/manifest/membership の全条件を要求する | MoonBit + checkpoint capability contract | 6 proof goals と invalid/cross-boundary/substitution tests | Proven + Tested |
| 同じ batch の observer/key は一つの anchor value だけを持つ | authenticated-map contract | same-key replacement regression | Tested |
| anchor head は exact next parent だけへ進む | MoonBit + head tracker contract | 7 proof goals と advance/duplicate/gap/stale tests | Proven + Tested |
| 交差した二つの authority-signed branch は fork evidence になる | head tracker contract | same-epoch/wrong-parent tests | Tested |
| 不正な gap batch は正しい prefix も commit しない | in-memory transaction contract | fork/gap/foreign/duplicate rollback tests | Tested、durable DB transaction は Unmet |
| wire gap page は全 envelope の authority/membership 再検証後にだけ commit する | transport/capability contract | authority/signature/membership tamper、件数上限、pagination、atomic rollback tests | in-memory transport は Tested、production network は Unmet |
| wire payload は全syntax/budget条件を満たす場合だけadmitする | MoonBit + codec contract | 9 proof goals、round-trip/noncanonical/version/truncation/oversize/path/item/declared-length tests | Proven + Tested |
| experimental SHA-256/Ed25519 adapterは標準vectorと一致する | adapter contract | SHA-256 `abc`、RFC 8032 empty-message、real-envelope round trip | Tested、audit/constant-timeはUnmet |
| Queue配送だけではgame replay成功にならない | central replay artifact contract | anchor-onlyはawaiting、verifiedは5条件すべてを要求 | Proven + Tested |
| PvE bundleは全署名eventとcheckpoint三root一致後だけverifiedになる | central replay/wire contract | canonical budget tests、real-crypto bridge、workerd Queue integration | Tested locally + remote benchmark |
| PvP bundleは全署名event・checkpoint三root・`n-f` witness後だけverifiedになる | central replay/wire contract | canonical budget tests、real-crypto bridge、workerd Queue integration | Tested locally + remote benchmark |
| open-world v2 bundleは4 checkpoint・2 publication proofs・遅延seed・`n-f` observer・eligible inclusion・PvE replay後だけverifiedになる | central replay/wire contract | canonical budget tests、real-crypto bridge、workerd Queue integration | Tested locally + remote benchmark |
| open-world encounterは署名済みeligible sealに含まれる | capability contract | Merkle inclusionとtrusted digest tests | Tested locally |
| audit plan/sealは独立publisherのtransparency checkpointに含まれる | deployment link contract | exact map membership capability、trusted head digest、workerd integration | Tested locally |
| network安定後にauthorityがlatest checkpointへ到達する | TLA+ liveness contract | 2 peer・2 epoch、crash/drop/partition、容量1のdurable outbox、最古retryを11,340 distinct statesで検査 | Bounded model checked。capacity gate除去は反例。direct DO RPC + lease/alarm retryをremote接続し、ACK 20/20とauthority commit後のDuplicate回復を観測。無期限liveness/SLAはUnmet |
| producer/roster/quorum不足やexpiryでwitness collection/receiverが不正に進まない | TLA+ witness collection contract | 4 roster + 1 intruder、safety 30,720 / liveness 19,456 distinct states、2 broken gate | Bounded model checked、pull/local-sign/submit + source isolationは全mode Tested locally + remote E2E |
| hostile sourceのinvalid flood後もquorumが進む | Cloudflare transport admission | local別source 20/20、remote単一egress429回復後の並列quorum 100/100 | Tested locally + remote、異なるremote source間のglobal fairnessはUnmet |
| remote witness fanoutを並列化すると逐次よりquorum latencyを短縮する | apac-ne benchmark | 初回各20 run、並列mean/p50 1.093/0.940 s、逐次mean/p50 2.467/2.652 s。旧p95は集計不備で不採用 | Measured once、並列fanoutを実装要件に採用 |
| accepted-seal latencyはmode値と地域配置へ分解できる | clean-path benchmark | 全mode apac-ne + PvP wnam/weur各20 run。apac-ne clean mean 0.744〜0.865 s、wnam 1.555 s、weur 1.831 s | Measured baseline、単一client/hintのためSLAはUnmet |
| marketplace は finalized ancestry と current owner を要求する | market contract | proof/tamper/owner tests | Tested |
| Workerのcurrent-owner headはexact parent、epoch前進、owner/version整合を要求する | MoonBit + DO contract | 64-case proof predicate、real-crypto wrong-parent/version tests | Proven + Tested locally |
| current prototype の latency が面白さに十分である | design hypothesis | playtest 未実施 | Unmet |
| complete transcript を local DB から復元できる | storage contract | memory-only prototype | Unmet |
| full combat state が全 asset effect を正当化する | game-kernel contract | 一次元、複数攻撃、player HP/clearまで | Unmet |
| hash/signature が production secure である | deployment contract | FNV/mock + 未監査experimental SHA-256/Ed25519 | Unmet |
| aimbot と熟練者を正当 input だけで区別できる | non-goal | protocol evidence なし | Not guaranteed |

証明済みとは、モデル化した predicate/数学整数の範囲で prover が obligation を
discharge したことを意味する。暗号仮定、I/O、overflow、モデル外の game semantics
まで証明したことを意味しない。

## Roadmap

1. 複数攻撃kernelはphase分離したcooldown、player attack、boss HP、deterministic clearまで
   reference実装した。次はcanonical wire、central replay、checkpoint-bound lootへ接続する。
2. N:N のreferee + participant witness certificate、fault threshold commit、二teamの
   公開状態PvP replay kernel、replay後だけ署名する専用session、bounded bundleとCloudflare
   Queue検証とcheckpoint witnessの公開pull/ローカル署名submit、direct authority ACK、apac-ne remote E2Eは実装・実測済み。
   cooldown/capture objectiveの公開状態referenceも実装済み。player-local SQLite leaseとMoonBit policyを
   使うbounded HTTP pushもloopback接続した。次はprojectile/visibility、wire manifest v2、
   credential付きpersistent socket、NAT-aware fair queueへ拡張する。
3. open-world の indexed conflict、observer certificate、signing-store contract、anchor
   checkpoint 公開、head fork tracker、wire envelope と in-memory gap transport は実装済み。
   1:N PvE、N:N PvP、open-world eligible-set/observerのversioned central replay bundleも
   DO/Queueまで接続済み。plan/sealの外部transparency-log inclusionもv2で接続した。次は
   production durable/CAS adapter、persistent gossip/multi-peer transport、transparency headのremote witness、
   zone observer assignment、委任 keyを
   実装する。
4. player-local論理DBに加え、storage-neutral seal write-setとNode 24 SQLite参照adapterを実装した。
   event/equivocation/checkpoint/head/closure/outbox/ACK履歴、atomic seal、revision CAS、restart、
   ACK footprint検証を持つ。次はIndexedDB/mobile SQLite、proof/inventory node保存、複数assetを
   同じcheckpointでatomicに進めるlocal-first transactionへ接続する。
5. checkpoint より古い log の pruning と disputed epoch の recovery 規則を定義する。
6. 実測用experimental SHA-256/Ed25519 adapterは実装済み。監査済みproduction backend、
   key rotation、session manifestへのsuite bindingを実装する。
7. network impairment と playtest で telegraph duration、backdate bound、reconcile
   animation を測定する。
8. 初期TLA+ transport modelへbounded outbox/backpressureを追加し、gate除去の反例も固定した。
   次はwitness quorum、Byzantine sender、複数authority shard、pruning/appealを追加し、
   production DB/Queue actionと対応付ける。

## 関連文書

- [ゲーム表現と予兆設計](./telegraph-game-design-ja.md)
- [open-world の選択的監査](./open-world-audit-ja.md)
- [実装済み checkpoint/capability/benchmark](./game-audit-prototype.md)
- [wire protocol v1 / open-world replay v2 と実暗号adapter](./game-audit-wire-ja.md)
- [BFT-CRDT adapter の詳細](./bft-crdt-research.md)
- [TLA+配送・永続化モデル](../formal/tla/README.md)
