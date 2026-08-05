# ゲーム監査 persistence / transport 実装契約

更新日: 2026-08-04

状態: 今後追加するruntime adapterに対する規範契約。現在の実装充足度は11節に示す。
「しなければならない」はMUST、「原則とする」はSHOULDとして扱う。

## 1. 位置付け

この文書は、player-local DB、同じ監査単位のpeer、権威サーバーを接続する
checkpoint runtimeの実装契約を定める。ゲームの戦闘規則ではなく、eventの永続化、
epoch close、checkpoint seal、outbox、ACK、head、gap recovery、crash recoveryを対象にする。

規範の担当は次のように分ける。

| 対象 | source of truth |
| --- | --- |
| 既存の公開型と純粋なhead/policy判定 | `src/audit/**/*.mbti`, `.mbtp`, runtime test |
| persistence/transportが今後満たすべき契約 | 本文書 |
| crash/drop/partitionを含む状態遷移 | `formal/tla/CheckpointDelivery.tla`, `formal/tla/WitnessQuorum.tla` |
| wire encoding、署名domain、decode budget | `docs/game-audit-wire-ja.md`とgame adapter |
| event完全性、合法手、報酬、asset生成 | 個別gameのmanifestとdeterministic kernel |

TLA+は本文書の一部を有限状態で検査するが、本文書全体の証明ではない。逆に、現在の
prototype実装が本文書を満たしていない箇所は、既成事実として仕様を弱めず`Pending`として扱う。

## 2. 責務分離

```text
converge/audit
  pure policy + commitment projection + head classification
  + persistence/transportの抽象contract
                 │
game adapter     │ epoch closure / expected frontier / replay rule
                 ▼
concrete runtime   local DB + peer transport + authority DB/Queue
```

### 2.1 converge汎用層

汎用層は次を所有する。

- checkpoint commitmentの必須field
- watermark、head、outbox、ACKの状態遷移と結果型
- exact-parent、historical duplicate、fork、gap、staleの分類
- transaction境界とidempotency規則
- retry schedulerが満たす順序・公平性契約

汎用層は、どのeventがゲーム上必要か、誰が勝ったか、lootを生成してよいかを決めない。

### 2.2 game adapter

game adapterは次を所有する。

- scopeとepochごとの固定rosterまたはeligible participant集合
- 各authorの連続counter frontierと、入力なしを表す認証済みclose/idle evidence
- `TrustedEpochClosure`を発行できるmode固有quorum
- checkpointへのgame manifest、state root、effect rootの射影
- timeout、challenge、under-quorumをcentral replayへ送るpolicy

### 2.3 concrete runtime

DB、Queue、WebSocket、P2P transportなどのadapterは、汎用状態遷移をatomicかつdurableに
実現する。transport成功をgameplay検証成功として扱ってはならない。
pureな分類・検証とDB mutationを分離し、transaction adapterは分類結果に従うだけにする。

## 3. 識別子と境界

すべてのevent、closure、checkpoint、ACK、outbox keyは最低でも次の境界へ拘束する。

- protocol versionとmessage purpose
- game/rule manifest digest
- scope/session ID
- coordination unit ID（party、match、zone、encounter）
- epoch
- sender/authority identity

別scope、別manifest、別purposeのdigestや署名を再利用してはならない。epochとcounterは
非負のbounded integerとしてdecode時に検査し、内部の加算前にもoverflowを拒否する。

## 4. 論理データ契約

以下は概念型であり、公開MoonBit API名は実装時に`.mbti`差分として確定する。

### 4.1 `AuthenticatedEvent`

最低field:

- boundary情報、author ID、author counter、audit time
- canonical payloadまたはpayload digest
- causal dependency commitment
- signature suite、key ID、signature

不変条件:

- `(scope, author, counter)`は一つのdigestにだけ対応する。
- 同じkeyと同digestは`Duplicate`、異digestは`Equivocation`であり、到着順で上書きしない。
- author counterにgapがあるeventは保存してよいが、適用・closure完了には使わない。
- client wall clockをそのままaudit timeとして信用しない。

### 4.2 `TrustedEpochClosure`

最低field:

- boundary情報とepoch
- roster/eligible-set digest
- authorごとの最終連続counter frontier
- close/idle evidenceまたはauthority receiptのcommitment
- closureを承認したidentity集合とcertificate digest

`TrustedEpochClosure`は、期待event集合がローカルDBに揃ったことを検査した後だけ構築できる
capabilityとする。単なる時刻経過、client申告、未認証watermarkから構築してはならない。

open rosterでは「世界中の全player」を期待集合にしない。match roster、party roster、
interest group、事前seal済みeligible setなど、有限でcommit済みの集合へscopeを切る。

### 4.3 `SealedCheckpoint`

共通commitmentとして次を拘束する。

- scope、epoch、previous checkpoint digest
- manifest digest
- event root、public state root、effect root
- hidden stateを使う場合のsealed-state commitment
- `TrustedEpochClosure` digest
- producer identityとsignature

checkpoint digestはcanonical bytesから一度だけ計算する。retryのたびに再生成してはならない。

### 4.4 `CheckpointAck`

ACKは少なくともscope、epoch、checkpoint digest、authority identity、decisionを認証する。
成功ACKは`Accepted`または`Duplicate`だけである。`Gap`、`Fork`、`StaleUnknown`、
`BoundaryMismatch`、timeoutを成功ACKとして扱ってはならない。

ACK channelが署名を使わない場合も、mTLSやsession-bound authenticated channelにより同等の
identity/boundary保証を持たせる。senderはACKを永続化してからoutbox entryを完了扱いにする。

### 4.5 `OutboxEntry`

最低field:

- `(scope, destination, epoch, checkpoint_digest)`から導くidempotency key
- 送信するcanonical envelope bytes
- `pending | in_flight | acknowledged`状態
- attempts、next retry time、last transport error
- created/acknowledged time

`queued`やsocket write成功は`acknowledged`ではない。outbox容量不足時はcheckpoint sealを
成功させず、gameplay結果をprovisionalに留める。

状態遷移は次に限定する。

```text
pending ──claim/lease──> in_flight ──valid success ACK──> acknowledged
   ▲                           │
   └── timeout/drop/restart ───┘
```

`in_flight`は期限付きleaseとし、process crash後に期限切れentryを`pending`へ戻せなければならない。

### 4.6 操作結果型

公開contractは単一の`Bool`で成功・不足・不正・障害を潰さない。少なくとも次を型で区別する。

```text
EventAdmission  = Stored | Duplicate | Equivocation | Refused
ClosureDecision = Ready(TrustedEpochClosure) | PendingEvidence | Conflict | Refused
SealDecision    = Sealed | AlreadySealed | PendingEvidence | Backpressured | Refused
AuthorityResult = Advance | Duplicate | SameEpochFork | ParentFork
                | Gap | StaleUnknown | BoundaryMismatch | Refused
DeliveryResult  = Acknowledged | PendingTransport | Rejected
```

`PendingEvidence`と`PendingTransport`はcheat判定ではない。`Refused`はdecode、boundary、容量、
内部整合性などのreason codeを持ち、retry可能性を呼出側が判定できる形にする。

## 5. 永続状態

実DBのtable名は自由だが、次の論理relationを復元できなければならない。

| relation | primary/unique key | 必須性質 |
| --- | --- | --- |
| authenticated events | scope + author + counter | digest不変、equivocation別保存 |
| epoch closures | scope + epoch | roster/frontier/certificateを固定 |
| checkpoint history | scope + epoch | digest、parent、canonical bytesを保持 |
| local head | scope singleton | historyのlatest exact chainを指す |
| checkpoint outbox | scope + destination + epoch + digest | sealと同じtransactionで作成 |
| authority ACK history | authority + scope + epoch + digest | historical duplicateを復元可能 |
| fork/challenge evidence | boundary + conflict key | 吸収的で上書き不能 |

同じscopeの`checkpoint history + local head + outbox`は同じtransaction domainに置く。
別DBへ分ける場合は、同等のrecoverable transaction protocolとcrash testを必須とする。

## 6. 操作契約

### IMPL-EVENT-001: event admission

事前条件:

- size/decode budget内のcanonical message
- boundary、key、digest、signatureが検証済み

事後条件:

- 新規eventはdurableに一度だけ保存する。
- 同一digestの再送は状態を変えず`Duplicate`を返す。
- 同一author/counterの異digestは既存値を変えずequivocation evidenceを追加する。
- DB失敗時はgame state、frontier、watermarkを進めない。

### IMPL-CLOSE-001: trusted closure admission

事前条件:

- roster/eligible setがmanifestへ拘束されている。
- frontierまでの全counterが連続し、該当eventが認証済みDBに存在する。
- equivocation、未解決gap、必要quorum不足がない。

事後条件:

- 条件を満たす場合だけopaqueな`TrustedEpochClosure`を返す。
- 不足は`PendingEvidence`、矛盾は`Conflict`として分離する。
- timeoutだけでcheat確定または完全closureにしない。

### IMPL-SEAL-001: seal and enqueue

一つのtransactionで次を行う。

1. `TrustedEpochClosure`のboundary/epochと未消費性を確認する。
2. local headに対して`epoch = current + 1`とparent一致を確認する。
3. canonical event集合からcheckpointを生成してhistoryへinsertする。
4. local headを進める。
5. 必要な各destinationのdurable outbox entryをinsertする。
6. closure/watermarkを消費済みにする。

どれか一つでも失敗した場合は全変更をrollbackする。特に「headだけ進んだ」「checkpointはあるが
outboxがない」「watermarkだけ進んだ」という状態を作ってはならない。

汎用層の`prepare_atomic_checkpoint_seal`は、transaction内で読んだstorage snapshotから上記4種類の
変更を含むopaque write-set planを生成する。既知digestの再実行は、history/head/必要outbox/closure消費が
すべて存在すると確認できる場合だけ`AlreadyCommitted`である。一部だけ存在する既知checkpointは
`SealIncompleteKnownCommit`としてfail-closedにする。plan生成自体はcommitではなく、adapterは
expected snapshotのCASと全write-setを一transactionで行わなければならない。

### IMPL-PROVISION-001: authority boundary provisioning

- authorityのboundary、destination identity、initial epoch/digestは、最初のcheckpoint受信より前に
  認証済みcontrol planeからdurableに設定する。
- 未設定receiverはcheckpointから設定を作らず、fail-closedにする。
- 設定後のboundary/initial headは上書きしない。同一設定の再実行だけをduplicateとして許す。
- sourceは必要destinationすべてのprovision完了をdurableに確認するまでsealしない。

### IMPL-AUTH-001: checkpoint delivery authentication

- transport上で自己整合するidempotency keyは認証ではない。
- receiverを更新する前に、jobがsourceのdurable outbox entryとboundary、destination、epoch、digest、
  canonical bytes、created orderまで一致することを認証する。
- 同一trust domainでは認証済みinternal RPCを使ってよい。敵対的peer transportではproducer signature、
  roster/quorum capabilityを検証し、同じ認証済みdelivery境界へ変換する。
- unknown、改ざん、未認証jobはreceiver history/head/fork evidenceを一切変更しない。

### IMPL-COLLECT-001: remote witness collection

- collection開始時にexact delivery statement、producer署名、provision済みpolicy、deadlineをdurableに固定する。
- witness approval endpointは管理tokenではなく署名を認証情報とし、unknown collection、非roster、
  statement/key/digest/signature不一致を永続状態へ入れない。
- exact duplicateは承認数を増やさない。同じwitnessの異なる応答は、競合応答自体の署名検証に成功した
  場合だけequivocation evidenceとして保存する。
- distinct roster approvalが必要数へ達した時だけ`ready`へ一方向遷移する。`ready`後のbundleは凍結する。
- deadlineまでにquorumへ達しなければ`expired/pending`とし、cheat確定にしない。
- sealは`ready` collectionと自身のboundary、destination、epoch、parent、digest、canonical bytesが
  完全一致した場合だけauthentication bundleを取り出す。
- 活性保証には、未採用の正直な応答がhostile duplicate/invalid floodに永久に飢餓化されない公平な
  queueingまたはrate limitを仮定する。
- 公開入口はtransportが認証した送信元をserver secret付きHMACのpseudonymous bucketへ写像し、
  raw sourceを保存せず、clientが指定した内部bucketを信用しない。secret欠落時はfail-closedにする。
  少なくともcollection・bucket単位の有限rate limitにより、あるbucketのfloodが別bucketの
  quotaを消費しないことを回帰検査する。NAT、IP churn、botnetを独立故障とみなせるとは仮定しない。
- witness秘密鍵はpeer processからauthorityへ送らない。peerは公開collectionのroster、deadline、
  statement digestを検査し、ローカル署名した1 approvalだけを提出する。

### IMPL-SEND-001: ordered retry

- 通常の初回送信は複数epochをpipelineしてよい。
- retry schedulerは各`(scope, destination)`について最古epochの未ACK entryを優先する。
- 同epochではcreated time、digestのような公開されたdeterministic tie-breakを使う。
- retryは同じcanonical bytesとidempotency keyを再利用する。
- backoff/jitterは許すが、entryを永久に飢餓させてはならない。
- transport timeout、drop、partitionは不正判定にせず`pending`へ戻す。

### IMPL-PEER-SEND-001: player-local bounded peer fanout

- peer endpointはaudit boundaryと同じlocal DBへ事前provisionし、同一identityのendpoint差替えを
  通常data pathから許可しない。
- fanout選択、backoff、成功reset、複数response分類は汎用MoonBit policyをsource of truthとする。
- route claimはSQLite leaseと単調なattempt orderを一transactionで保存し、process memoryだけの
  in-flight countに依存しない。crash後はlease期限までbackpressureし、その後retry可能にする。
- senderの最大試行時間はlease以下でなければならない。これを満たさない構成は送信前に拒否する。
- response bodyへbyte上限を設け、peer identityとapplication固有signature/certificateを検証した後だけ
  successまたはfork判定へ入れる。未認証の異digestはfork evidenceにしない。
- 認証済み異digestはcanonical responseと共にdurableに保存し、同じtransactionで当該routeを
  quarantineする。正常responseが先に届いてもforkを隠さない。
- timeout、oversize、未認証、到達不能、lease中はcheat確定にしない。
- `now_ms`はaudit unitの永続化されたclock originからの32-bit相対時刻とする。Unix epoch millisecondsを
  MoonBit `Int`へ直接渡さず、長寿命unitはclock範囲内でrotationする。

### IMPL-RECV-001: authority checkpoint admission

authorityはdecode budget、signature、boundaryを検査してから、同じtransaction内でhistoryと
headを分類・更新する。

| decision | authority mutation | senderへの結果 |
| --- | --- | --- |
| initial/exact `Advance` | history insert + head advance | success ACK |
| historical exact `Duplicate` | head不変 | success ACK |
| `SameEpochFork` | head不変、fork evidence追加 | reject/escalate |
| exact-next `ParentFork` | head不変、fork evidence追加 | reject/escalate |
| `Gap` | head不変 | expected headを返しgap recovery |
| `StaleUnknown` | head不変 | reject/resync |
| `BoundaryMismatch` | head不変 | reject、告発には使わない |

history lookupはcurrent head比較より先に行う。authorityがepoch 2まで進んだ後にepoch 1の
正しいretryを受けても`Stale`ではなく`Duplicate` ACKを返し、senderのoutboxを解放する。

### IMPL-ACK-001: acknowledge outbox

- ACKのauthority identity、boundary、epoch、digestを元entryと照合する。
- `Accepted`と`Duplicate`だけが`acknowledged`へ遷移できる。
- ACK更新はdurableにcommitする。
- unknown ACKは無視または監査記録へ送り、別entryを完了させない。
- acknowledged tombstoneは少なくともretry/appealの重複期間中保持する。

### IMPL-GAP-001: atomic gap recovery

gap responseは開始head、target epoch、最大件数を拘束し、連続するcanonical checkpoint列を返す。
receiverは全要素のsignature、boundary、epoch、parentを検査した後だけ一括commitする。一要素でも
不正なら正しいprefixを含めてheadを変更しない。

### IMPL-PRUNE-001: evidence pruning

- 未ACK checkpointとoutbox entryをpruneしない。
- unresolved fork/challenge/appealが参照するevent、proof、checkpointをpruneしない。
- event leafを消した後に返せる精度をmicro/macro精度より細かく表示しない。
- authority historyはhistorical duplicate判定とappeal windowを満たす期間保持する。
- prune watermark自体をdurableにし、crash後に保持期限を巻き戻さない。

## 7. crash consistency

最低限、次のcrash pointをfault-injection testで固定する。

| crash point | restart後に許される状態 |
| --- | --- |
| event transaction commit前 | event/frontierとも未反映 |
| event commit後 | eventが再送なしでも復元可能 |
| seal transaction途中 | history/head/outbox/watermarkがすべて旧状態 |
| seal transaction commit後・send前 | checkpointとoutboxが復元され再送可能 |
| send後・ACK前 | 同じbytesを安全に再送可能 |
| authority commit後・ACK消失 | historical `Duplicate` ACKで回復可能 |
| ACK受信後・local commit前 | ACK再受信またはcheckpoint再送で回復可能 |

authority process/storageのcrash recoveryは現在のTLA+モデル外だが、productionではhistory、head、
fork evidence、ACK結果をdurable transactionから復元しなければならない。

## 8. 活性契約と非保証

次をすべて仮定したとき、閉じた最新epochは最終的にauthority headへ到達しなければならない。

1. epochのroster/eligible setとfrontierが有限で固定される。
2. 必要eventまたは正当なclose/idle evidenceが最終的に正直なreplicaへ届く。
3. crashしたnodeが最終的にrestartし、partitionが最終的に解消する。
4. retry workerが継続稼働し、最古未ACK entryを永久に飢餓させない。
5. 繰り返し送信したmessageの少なくとも一つが最終的に配送・処理される。
6. authorityのexact-parent historyが失われない。

いずれかが満たされない場合、finalityは保証しない。withholding、長期partition、under-quorumは
`Pending`またはcentral escalationであり、それだけでcheat確定にしない。

TLA+で検査済みの性質は、2 peer・2 epoch・3 eventにおける上記の有限抽象である。

## 9. mode別のclosure adapter

| mode | 有限な期待集合 | closureに最低限必要な根拠 |
| --- | --- | --- |
| 1:N PvE | encounter開始時party roster | authority receipt + participant frontier、または独立witness |
| N:N PvP | match rosterとteam assignment | 全authorの連続frontier + cross-team/referee certificate |
| open world | seal済みinterest group/eligible encounter set | plan/seal publication + assigned observer certificate |

party全員または同一teamだけの署名は、取引可能assetやrankのeconomic finalityには十分でない。
game adapterは既存の`n > 3f`、`n-f` quorumとcentral escalation policyを適用する。

## 10. resourceと運用契約

- event、checkpoint、gap page、outbox batchには件数・byte数・proof depth上限を設ける。
- outbox high-water mark到達時はsealをfail-closedにし、provisional表示とbackpressureを返す。
- retry回数上限は配送停止ではなく、alarm/escalation levelの変更に使う。
- metricは最低でもoldest pending age、pending count、attempts、ACK latency、gap/fork数、
  seal拒否数、prune backlogをscope別に持つ。
- logへprivate payloadやkey materialを出さず、digest/idempotency keyで追跡する。

## 11. 現在の実装との対応

| 契約 | 現状 | 判定 |
| --- | --- | --- |
| policy、commitment、head pure classifier | `src/audit`、Why3、runtime test | Implemented / Proven scope |
| closure/ACK/atomic seal/delivery authenticationとvote mergeのfail-closed gate | `src/audit`の39 proof goals + `src/audit/runtime` | Implemented / Proven scope |
| opaque atomic seal plan/outbox、lease、release、最古retry選択 | `src/audit/runtime` | pure contractはImplemented + Tested |
| watermark駆動micro/macro builder | `src/audit/layered` | in-memoryはImplemented、mode固有closure検証adapterはPending |
| player-local authenticated event DB | 公開row DTO + Node 24 SQLite relation、event/equivocation/checkpoint/head/closure/outbox/ACK履歴、revision CAS、起動時全image検証 | Reference Implemented + Tested / IndexedDB・production端末統合はPending |
| seal + local head + checkpoint outboxのatomic transaction | opaque planから公開write-setを導出し、player-local Node SQLiteとCloudflare SQLiteで一括適用、各4 fault rollback | Tested locally / production player DBはPending |
| authority boundary/initial headの事前provision | 管理API → destination DO、source側provision ledger、未設定receiver拒否 | Tested locally |
| Queue jobのsource outbox認証 | receiver mutation前のsource DO exact-match | Tested locally |
| producer署名 + provision済みwitness quorum | `src/audit/delivery_auth`のopaque capability、実Ed25519 Worker bridge、source/receiver二重gate | Proven gate + Tested locally |
| remote witness collection | 公開pull/ローカル署名submit、pure bounded fanout/指数retry/backpressure/複数response選択、SQLite collection、deadline | remote E2E + pure scheduler Tested / socket push・global fair queueはPending |
| player-local peer checkpoint fanout | MoonBit JS policy、SQLite route/lease/attempt/backoff/fork quarantine、bounded HTTP POST、restart lease | loopback 7 tests / 実credential・WebSocket/WebTransportはPending |
| 最古未ACK checkpoint retry worker | direct DO RPC、SQLite lease、DO alarm + pure選択契約 | Tested locally + remote E2E |
| authority exact-parent + historical duplicate | 専用receiver history/head transaction + generic classifier | Tested locally + remote ACK-loss recovery |
| authenticated success ACK | internal DO channel + opaque MoonBit ACK gate + SQLite tombstone | Proven core + remote 20/20 |
| atomic gap batch | in-memory transportとCloudflare gap API | Partial |
| server-side central replay outbox | Cloudflare `replay_outbox` | Tested locally |
| checkpoint transportの有限safety/liveness | TLA+/TLC、bounded outbox込み11,340 distinct states | Model checked、capacity gate除去で反例 |
| witness collectionの有限safety/liveness | TLA+/TLC、4 roster + 1 intruder、safety 30,720 / liveness 19,456 distinct states | Model checked |
| authority DB crash/restore | Durable Object local testのみ、TLA+範囲外 | Partial |

管理者限定の`x-audit-checkpoint-dispatch: deferred`はfault injectionとQueue互換試験だけに使う。
これは初回direct RPCを保留するが、entryはlease付き`in_flight`へ進み、30秒後のalarmはdirect retryする。
省略時のproduction契約は`direct`である。

Cloudflareの`replay_outbox`は中央replay job用、`checkpoint_outbox`は汎用checkpoint seal用である。
後者もCloudflare reference adapterではtransport/lease/retry/ACKまで接続した。さらにcheckpointの
exact statementをproducerとprovision済みwitness quorumが署名し、source seal前とreceiver mutation前の
両方で検証する。署名収集は公開pull/ローカル署名/submit型referenceとper-source rate limitまで接続し、
東京clientから全modeの`apac-ne`、PvPの`wnam`/`weur` hintを各20 run測り、並列3/4 quorumとsealを
100/100 E2E確認した。さらにPvP `apac-ne`でauthority ACKまで20/20確認し、seal開始からACKは
mean 0.729秒 / p95 1.003秒だった。ただしoutbound push、global/roster-aware fair queue、production端末DB統合、
監査済みproduction cryptoは未接続である。単一client・単一egressのremote実測をproduction P2Pの
source独立性や全地域SLAと同一視してはならない。

形式仕様とのreconciliation ledger:

| 項目 | 内容 |
| --- | --- |
| source | TLA+ `SendCheckpoint`は`checkpoint \in AvailableOutbox(peer)`を要求する |
| implementation observation | 以前のQueue consumerは自己整合した未知jobをreceiverへ先に渡せた |
| model question | source outboxにないjobでauthority headを更新できるか |
| machine result | workerd反例で偽造jobが先にacceptedされ、後続の正規jobがsame-epoch forkになった |
| decision | 実装bug。receiver mutation前にsource outbox exact-matchを必須化した |
| lock | unprovisioned receiver拒否とforged-consistent job後の正規delivery成功test |

| 項目 | 内容 |
| --- | --- |
| source | `IMPL-AUTH-001`は敵対的peerでproducer署名とroster/quorum capabilityを要求する |
| implementation observation | internal outbox exact-matchだけでは、peer由来checkpointの生成主体と相互承認を証明しない |
| model question | 認証Booleanを呼出側が偽装せず、完全なtrust factsを通過した値だけreceiverへ渡せるか |
| machine result | MoonBit lemmaはstatement/policy/producer identity/signature/roster/quorumの全条件を要求し、opaque capability以外から受理値を生成できない |
| decision | game固有の署名bundleを汎用transport前段へ追加し、transport順序はsource outbox完全一致へ分離した |
| lock | source under-quorum無変更、receiver署名改ざん・foreign witness・under-quorum無変更後の正規delivery成功test |

| 項目 | 内容 |
| --- | --- |
| source | `AUD-TRUST-003`と`IMPL-COLLECT-001`はtimeout/under-quorumをcheat確定せず、正直なquorum到達時の活性を条件付きで要求する |
| implementation observation | 「何らかの応答を公平に処理する」だけではhostile duplicateを処理し続け、未採用の正直な応答を飢餓化できる |
| model question | foreign/duplicate/timeout下で不正なready/receiver advanceを防ぎ、正直な未採用応答が公平ならeventually readyになるか |
| machine result | safety 30,720、liveness 19,456 distinct statesで反例なし。弱い公平性ではhostile duplicate starvation反例を検出した |
| decision | 活性仮定を「未採用の正直な応答が公平に処理される」へ限定する。reference adapterではhashed sourceごとのfixed windowを入れ、global fairnessはproduction要件として残す |
| lock | `WitnessQuorum.tla`、producer/roster gateを外す2 broken config、workerd foreign/invalid/duplicate/quorum/expiry/source-isolation test、20-run local flood benchmark |

| 項目 | 内容 |
| --- | --- |
| source | conditional livenessはcrash/restart後も未ACK outboxを再送し、authority ACKをdurableに保存することを要求する |
| implementation observation | 本番の新規isolateでalarmがMoonBit runtimeをロードせずACK gateを呼び、authority commit後もsource entryが`in_flight`へ残った |
| model question | process-local runtimeを失った状態から、durable outboxだけでhistorical Duplicate ACKを回収できるか |
| machine result | production tailで未初期化例外を観測。dispatch入口へruntime loadを移した後、同一entryはattempt 4の`Duplicate`で自動回復し、続くremote 20 runは20/20 `Accepted` |
| decision | runtime初期化はHTTP handlerではなく、alarmを含む全checkpoint dispatchのpreconditionにする。ロード関数が返すbranded `LoadedCheckpointRuntime` capabilityをseal、receiver認証、witness収集、ACK gateの必須引数にする |
| lock | TypeScript capability contract、偽造tokenを3同期gateで拒否するtest、direct dispatch integration test、42 Worker tests、remote direct/deferred ACK artifacts |

| 項目 | 内容 |
| --- | --- |
| source | `IMPL-EVENT-001`、`IMPL-SEAL-001`、`AUD-OPS-004`はevent/equivocationとseal/ACKのatomic永続化・restart復元を要求する |
| implementation observation | opaque outbox値だけのmemory snapshotでは、実プロセス再起動後にSQLite/IndexedDB行から安全に再構築できない |
| model question | 公開row DTOを改ざん・欠損させたimageからorphan headやACK履歴なしのacknowledged outboxを復元できるか |
| machine result | MoonBit正常imageはevent/equivocation/head/outbox/ACKを復元し、orphan headとACK footprint欠損を拒否した。Node SQLiteでもrestart後の同値image、stale CAS、容量超過、ACK footprint欠損を検査し、history/head/outbox/closure各書込み直後の例外は全旧状態へrollbackした |
| decision | `PlayerLocalAuditStore`を汎用reference transaction、`PlayerLocalSealPlan::write_set()`をstorage-neutral境界とし、物理adapterは公開DTOを同一transactionで保存・再構築する。未認証network payloadからwrite-set/ACKを直接構築してはならない |
| lock | MoonBit local store 22 tests、Node SQLite 9 tests、`just test-node-audit-runtime`。TLA+のatomic `SealNextCheckpoint`を実装へ対応付けるが、SQLite engine自体をmodel checkedしたとは主張しない |

| 項目 | 内容 |
| --- | --- |
| source | `AUD-EVENT-002`は同一slotのequivocationを吸収的かつrestart可能に保持し、同一digestのcanonical bytes衝突をfail-closedにする |
| implementation observation | accepted event側のdigest collisionは拒否していたが、既知のconflicting digestを別canonical bytesで再投入すると2件目のevidenceを追加できた |
| model question | runtime自身が、restore validatorのdigest一意制約に違反するdurable imageを生成できるか |
| machine result | broken testは`LocalEventEquivocation`を返した直後に同一conflict keyが重複し、restart拒否となる経路を再現した。修正後はMoonBit/Node SQLiteとも`digest_collision`で無変更拒否し、全testが通った |
| decision | accepted branchだけでなくequivocation branchでも、同一digest・異canonical bytesをcollisionとして扱う |
| lock | `player-local store refuses a canonical collision on a known fork digest`とNode同形test |

| 項目 | 内容 |
| --- | --- |
| source | `IMPL-PEER-SEND-001`とTLA+ retry抽象は、bounded fanout、crash後の再試行、未認証応答の無害化、認証済みforkの吸収を要求する |
| implementation observation | pure schedulerだけではprocess再起動時のin-flight数を復元できず、送信timeoutがleaseより長い構成では正常稼働中にも同じrouteを再claimできる |
| model question | durable lease中のrestart、1成功+1未認証/失敗、1成功+1署名済みforkで、backpressure・fair retry・fork evidenceは期待どおり残るか |
| machine result | Node loopback 7 testsでMoonBit JS選択、2並列上限、restart lease、期限後retry、success/failure永続化、oversize拒否、署名済みfork quarantineを確認した。`timeout > lease`は構築時拒否に固定し、fork evidenceとquarantineの不一致はrestart時に破損として拒否した |
| decision | route/lease/evidenceをSQLite state、選択/遷移をMoonBit policy、HTTPを交換可能I/Oへ分離する。HTTP到達や未認証bytesだけでcheat判定しない |
| lock | `peer-checkpoint-transport.node-test.ts` 7 tests、Node package合計16 tests、`just test-node-audit-runtime`。既存TLA+抽象への実装refinement testでありHTTP stack自体のmodel checkではない |

| 項目 | 内容 |
| --- | --- |
| source | resource契約はoutbox high-water mark到達時にcheckpoint sealをfail-closedにする |
| implementation observation | capacityをruntime validationだけに置くと、時間的modelがbackpressureなしのseal列を許す可能性が残る |
| model question | 未ACK outboxが容量1の間に次epochをsealできるか。network安定後のlatest finalityを壊さないか |
| machine result | 正常設定は55,849 generated / 11,340 distinct statesで安全性・活性とも反例なし。capacity gate除去設定は`OutboxWithinCapacity`違反を検出した |
| decision | capacity checkを`SealNextCheckpoint`のload-bearing guardとしてTLA+へ固定する |
| lock | `CheckpointDeliveryBrokenBackpressure.cfg`を含む7 broken configsと`just tla-check` |

## 12. 受入テスト

production adapterは最低限、次を自動検査する。

1. frontier中のeventが一つ欠けるとclosure/sealできない。
2. seal commit前のcrashでは何も進まず、commit後のcrashではcheckpointとoutboxを復元できる。
3. 最初のN回をdropしても、network回復後に同じcheckpointがACKされる。
4. epoch 2を先に送信しても、retryはepoch 1を飢餓させない。
5. authority commit後にACKを失っても、再送へhistorical `Duplicate` ACKを返す。
6. same-epoch fork、wrong parent、gap、foreign boundaryでheadが変わらない。
7. gap batchの最後だけ不正でもprefixをcommitしない。
8. timeout、partition、under-quorumだけではcheat確定にならない。
9. outbox満杯時にhead/watermarkだけが進まない。
10. prune/restart後も必要なduplicate、appeal、fork evidenceを復元できる。
11. 未provision receiverとsource outboxに存在しない自己整合jobでauthority stateが変わらない。
12. producer署名改ざん、非roster witness、duplicate witness、under-quorumでsource/receiver stateが変わらない。
13. collectionのforeign/invalid応答は承認数を増やさず、deadline expiryはcheatにせずsealを拒否する。
14. 同一送信元がclient指定bucketを変えてもrate limitを回避できず、別送信元の正当quorumは進行する。
15. peer clientは秘密seedとroster keyが一致しない場合、approvalをnetworkへ送らない。
16. quorumに必要なpeer approvalを並列fanoutし、収集待ちでrender/inputを停止しない。

回帰入口:

```sh
just tla-check
just tla-counterexamples
just prove-audit-core
just test-audit-layered
just test-audit-runtime
just test-node-audit-runtime
just check-node-audit-runtime
moon test
```

DB fault injection、checkpoint outbox配送、通常ACK、authority commit後のACK lossとhistorical
`Duplicate`回復、実暗号producer/witness認証のfail-closed回帰はCloudflare workerd testへ追加済み。
per-source fixed-window rate limitと別source progressはlocal workerdで検査し、remoteでは単一egressの
429と`Retry-After`後の並列quorumを全mode・3 hintで100/100確認した。複数回drop、partition、実時間lease expiry、
異なるremote source間の公平性、NAT/botnetを含むglobal fair queueは引き続き受入テストが必要である。
