# 不規則 encounter の選択的アンチチート

更新日: 2026-08-04

## 結論

オープンワールドでは、全プレイヤーの全 encounter を中央で再実行しない。中央が
常時行う処理を checkpoint の署名、短い capability、Merkle proof の確認に寄せ、
高価な deterministic replay は次の場合だけに限定する。

- 遅延公開 seed で無作為抽出された encounter
- 正当に署名された challenge または equivocation がある encounter
- replay-witness certificate が不足した durable / tradable outcome
- rare drop、world-first、ranked result など、常時監査すると manifest が定めた結果

未抽出で challenge がなく、`n > 3f` の roster から `n-f` の replay witness を得た
通常結果は peer certificate で確定できる。見た目だけの結果は証人が足りなくても
provisional に表示できるが、永続進行や経済状態へは入れない。

この設計で減らすのは中央の「ゲーム状態再シミュレーション」である。署名、session、
checkpoint 親子関係、certificate、Merkle inclusion の軽量検証は省略しない。現在の
prototype は encounter checkpoint も同じ authority key で署名するため、中央署名自体を
なくすものではない。ただし登録については、plan に固定した observer roster の `n-f`
署名があれば、authority が encounter checkpoint を発行しなかった場合でも seal との
矛盾を検出できる。将来、zone/epoch ごとの委任 referee key を manifest に bind すれば
署名処理も edge へ分散できる。

## 脅威モデル

扱う攻撃は次である。

- client が存在しない encounter や、別 epoch の outcome を後付けする。
- 抽選 seed を見てから都合のよい encounter id を作り、監査対象を引き直す。
- 通常 checkpoint approval を「ゲームを再実行した」という witness 署名へ流用する。
- 別 checkpoint / 別 referee の certificate や central replay capability を流用する。
- witness 不足の rare item を local-first DB にだけ書き、marketplace へ持ち込む。
- encounter の一部参加者が challenge した事実を、他の peer が省いて確定する。
- authority が observer に受領された encounter 登録を close registry から省く。

条件付き保証は「witness roster の Byzantine 数が `f` 以下」「honest witness は
commit 済み deterministic kernel と完全 transcript を実行して一致したときだけ署名」
という仮定に依存する。Sybil account、端末改造、hidden information の漏洩を署名だけで
解決するものではない。

登録 observer についても別の条件付き保証を置く。plan-bound roster が `n > 3f` を満たし、
Byzantine observer が `f` 以下で、honest observer が正しい登録要求を受領・保存した場合だけ
一つの slot/digest に署名することを仮定する。registration receipt は「ゲーム結果が正しい」
という replay witness ではなく、「この登録が seal 前に観測された」という主張だけである。
prototype の observer signing ledger は同じ `(plan, slot)` の完全一致 retry には同じ
statement を再署名し、別 digest への二通目を拒否する。mock signer では receipt も同一に
なるが、production signer の署名 nonce まで同一になることは contract に含めない。

## 四段階 protocol

```text
1. Plan
   authority checkpoint:
     game manifest + sample rate p/q + H(world, epoch, secret seed)
     + observer roster/fault-policy manifest

2. Encounter
   irregular encounter checkpoints branch from the plan digest
   nearby peers / edge observers sign (plan, slot, encounter digest) receipts
   replay witnesses separately replay and sign exact checkpoint digests

3. Seal then reveal
   close checkpoint:
     previous = plan digest
     manifest = H(plan manifest, registered_count, indexed registry version)
     event_root = Merkle root(index || encounter checkpoint digest)
     public_state_root = authenticated map root(index -> encounter digest)
   only after the eligible set is closed, reveal the seed

4. Route and finalize
   verify inclusion -> derive sample(seed, encounter digest)
   -> peer finality / central replay / provisional / rejection
```

順序は重要である。seed の commit だけでは不十分で、対象集合を閉じる前に seed を
公開するとプレイヤーは encounter を作り直せる。現在の `open_world` package は、
plan と close checkpoint の authority、session、連続 epoch、parent、manifest を照合し、
close checkpoint の `event_root` を eligible-anchor root として capability 内に封じる。
encounter checkpoint の `epoch` は audit manifest が定める登録 slot として扱う。
`evaluate_open_world_encounter` は `slot || verified encounter digest` の Merkle inclusion、
proof の leaf index、close manifest の総登録数が一致しなければ routing に入れない。

運用では二つの close root が「提出された都合のよい encounter だけ」でなく、epoch 中に
登録された全 encounter を含む必要がある。`event_root` は順序付き inclusion と抽選対象を、
`public_state_root` は slot registry の membership/non-membership を認証する。どちらも同じ
authority checkpoint の署名対象である。現在は三種類の omission evidence を実装した。

- authority-signed encounter の slot が `registered_count` 以上なら、registry 末尾の
  truncation capability を発行する。
- 範囲内の同じ slot に別 encounter digest が含まれる Merkle proof があれば、slot
  substitution capability を発行する。
- 範囲内の slot が authenticated map に存在しないという正しい non-membership proof が
  あれば、missing-slot capability を発行する。

通常の Merkle inclusion tree だけでは三番目の不在証明を作れないため、実装は検索経路が
認証済み empty child で終わる authenticated map proof を併用する。偽 proof、別 slot の
proof、単なる proof 不足、inclusion と non-membership の曖昧な同時提示から authority を
告発しない。authority-signed encounter または plan-bound `n-f` observer registration
certificate のどちらかを左辺の「登録されたはず」という evidence にできる。後者により、
authority が encounter checkpoint を発行せず、observer が受領済みの登録だけを隠すケースも
検出できる。

ただし observer 全員へ到達する前に遮断された要求、observer roster 自体の Sybil 支配、
honest observer の local receipt 消失は解かない。signing API は署名前に
`reserve(plan-slot, digest)` を呼ぶ persistence boundary を持ち、予約失敗時は signer を
一度も呼ばない。共有 store を使う ledger 間でも先着 digest だけが署名へ進む。実装付属の
in-memory store はこの compare-and-set の逐次参照実装であり、process restart や実並行実行を
保証しない。production store は `SigningSlotReserved` を返す前に予約を atomic かつ durable に
commit し、root/size snapshot を atomic に読む必要がある。

復元時は、信頼済みの `(observer id, signer key, Merkle root, size)` と store snapshot の
完全一致を要求できる。空 snapshot への巻き戻しと別 observer/key は拒否する。さらに authority
が署名した専用 checkpoint の `public_state_root` を
`(observer id, signer key) -> (Merkle root, size)` の authenticated map として検証し、正しい
membership proof からだけ opaque な published-anchor capability を発行する経路を実装した。
log session と domain manifest も一致しなければ capability は作られない。この capability を
復元 API に渡せるため、anchor を同じ巻き戻し可能な local DB だけから信頼する必要はない。

通常の Merkle list へ anchor を並べる案では、同じ observer/key の古い値と新しい値を同一 batch
へ二重掲載でき、どちらの inclusion proof も有効になる反例がある。そのため key-unique な
authenticated map を採用した。同じ key の再登録は一つの value を置換し、古い anchor の proof
は拒否される。

authority-signed fork については、published-anchor capability から log head tracker を初期化し、
peer から受け取った head を照合する経路も実装した。同じ session/publisher について、既知 epoch
の別 checkpoint digest、または現在 head の直後なのに parent が一致しない checkpoint が来ると
opaque fork evidence を作る。正しい `epoch + 1` と parent だけが head を進め、同一 digest は
duplicate にする。未来の epoch が飛んだ場合は gap、開始点より古く ancestry を知らない head は
stale とし、network partition や配送順序だけでは告発しない。

これにより二つの fork が同じ tracker へ到達すれば検出できるが、authority が partition ごとに
別 branch を配り続け、client 間に通信経路がなければ検出できない。現在の tracker は process-local
で、このtransparency headへ実ネットワークのfanout、durable head/envelope保存、remote witness
quorumを結ぶ経路は未実装である。汎用checkpoint witnessの公開pull/ローカル署名/submitは別の
Cloudflare referenceでremote E2E済みだが、このhead trackerへはまだ接続していない。
wire 形式は signed checkpoint、anchor、authenticated-map membership proof を持つ公開 envelope とし、
受信側が authority/digest/session/manifest/exact key-value/path をすべて再検証した場合だけ
published-anchor capability へ戻す。opaque capability 自体は network data として受け入れない。
version 1 は固定順 CBOR array とし、全体 byte 数、UTF-8 text、proof step、gap page 件数を
暗号検証前に制限する。巨大な宣言長による allocation を避けるため、依存 CBOR decoder の前に
bounded preflight を置き、decode 後の再 encode と byte 一致も要求する。wire が hash/signature
algorithm を選ぶ downgrade は許さず、suite と期待 key は信頼済み session/config で固定する。
schema と境界の詳細は [wire protocol v1](./game-audit-wire-ja.md) にまとめた。
また完全一致復元は正当に先へ進んだ store と古い anchor も拒否する
ため、運用では最新 anchor の取得または append-only extension proof が必要になる。

gap が見つかった場合に peer/authority から `[current epoch + 1 ... target epoch]` を取得して
埋める atomic batch API も実装した。batch は証明済み single-head classifier を各要素へ適用するが、
検査中は tracker を変更しない。全 session/publisher/epoch/parent が通った後だけ planned history と
head を一括反映する。途中の fork、再度の gap、stale、foreign boundary は失敗 index とともに返し、
先頭で正しかった checkpoint も commit しない。これは process-memory 上の atomicity であり、
production DB では head と history を同一 transaction に保存する必要がある。bounded request は
認証済み `(session, publisher, current epoch, current digest)`、target epoch、max items を持つ。
参照 in-memory transport は cursor index から連続 page を返し、未整列保存と pagination を扱う。
receiver は page 全件を capability に戻してから batch API を呼ぶため、不正署名、membership
substitution、件数超過では head を変更しない。複数候補を返す source ambiguity は、候補をまだ
独立に認証していないため authority fork evidence とは区別する。

## 判定表

| 条件 | 結果 | 永続・経済状態 |
| --- | --- | --- |
| central replay capability が存在し exact match | `CentralAccepted` | 確定可 |
| central replay capability が存在するが不一致 | `Rejected` | 拒否 |
| sample 対象 | `CentralReplayRequired` | replay まで保留 |
| signed challenge あり | `CentralReplayRequired` | replay まで保留 |
| `HighValue` | `CentralReplayRequired` | replay まで保留 |
| `Durable` / `Tradable` で peer certificate なし | `CentralReplayRequired` | replay まで保留 |
| 未抽出・challenge なし・matching peer certificate | `PeerAccepted` | 確定可 |
| `Ephemeral` かつ certificate なし | `Provisional` | 表示だけ、確定不可 |

中央 replay の概算件数は、重複集合を無視した上限として次で予算化できる。

```text
central_replays
  <= eligible_encounters * p / q
   + challenged_encounters
   + high_value_encounters
   + unwitnessed_economic_encounters
```

seal conflict capability は game replay queue ではなく、authority/registry の中央調査
queue へ送る。proof のない inclusion failure をすべて中央へ送らないことで、偽の
omission complaint による負荷増大を避ける。

実際には同じ encounter が複数条件に入るため集合の和で deduplicate する。`p/q` は
固定値ではなく、risk tier、直近の challenge rate、witness diversity、item value、
異常検知 score に応じて次 epoch の manifest で上げ下げする。個々の encounter を
見てから rate を変えると恣意的な狙い撃ちになるため、変更は次の plan checkpoint へ
commit する。

## ゲームの面白さを損ねにくい表現

不規則 encounter でもプレイヤーの操作を certificate 待ちにしない。次の二つを分ける。

- 知覚上の現在: 移動、hit stop、効果音、塗り、damage number、drop 演出は即時に出す。
- 不可逆な現在: HP の監査境界、rank、rare item の trade unlock、world state は
  checkpoint 後に確定する。

registration receipt は encounter 開始または報酬予約時に background で集める。`n-f` が
揃わなくても戦闘・移動・演出は止めず、rare drop の trade unlock や ranked result だけを
保留する。observer は同じ party だけから選ばず、zone edge、近傍の非参加者、運営 observer
を cell/epoch から決定的に混ぜると、ゲーム上の待ち時間を増やさず collusion を難しくできる。

具体的な表現は次が扱いやすい。

- FF14 型 FATE / hunt: 予兆と攻撃 plan を seed から生成し、参加者の入退場は離散 tick
  で記録する。報酬箱はすぐ見せ、trade 可否だけ後で unlock する。
- Vampire Survivors 型 roaming co-op: 雑魚一体ごとの位置を保存せず、wave seed、
  player keyframe、skill intent、集約 kill/drop counter を checkpoint 化する。
- Splatoon 型 open zone: 塗りの VFX は即時、地面を粗い tile + tick の可換な claim へ
  射影し、score に効く tile root だけを監査する。
- LoL 型 skirmish: projectile 発射、dash 開始、CC 適用、death、objective last-hit を
  離散 event にする。細かな animation path は保存しない。
- 探索・採集: spawn cell と time bucket から deterministic に資源を生成し、採取権の
  消費を一意な asset/event id にする。rare node だけ `HighValue` に分類する。

相性が悪いのは、自由物理の一瞬の接触が高価値 item を直接作る設計、client だけが
知る state で報酬を決める設計、任意の過去 tick へ戻せる入力である。完全に禁止する
必要はないが、見た目の自由物理から監査用の capsule/grid/ownership event へ射影する。

## Local-first DB と pruning

player DB は少なくとも次を分けて保存する。

| 状態 | 保持期間 |
| --- | --- |
| raw encounter transcript と receipt | anchor seal、seed reveal、routing 完了まで |
| challenge / equivocation evidence | 中央解決と appeal window 終了まで |
| observer signing ledger と receipt / certificate | key rotation 後も appeal window 終了まで。署名返却前に durable commit |
| witness certificate / central replay capability | checkpoint ancestry と同期間 |
| plan / close / encounter checkpoint、Merkle proof | asset または進行が生きる間 |
| render-only prediction | 原則永続化しない |

seed reveal 前に transcript を prune してはいけない。`PeerAccepted` でも、抜き打ち監査の
appeal window までは witness が transcript を再提供できる必要がある。長期保存は全ログ
ではなく、checkpoint、certificate、必要な Merkle path、現在資産から辿れる ancestry に
縮約する。

## 先行研究との対応

- [PeerReview](https://haeberlen.cis.upenn.edu/papers/peerreview-tr.pdf) の
  tamper-evident record と deterministic replay を、session-bound event、checkpoint、
  replay witness capability に分割して採用した。
- [SelectAudit](https://people.cs.vt.edu/~danfeng/papers/nve.pdf) の Merkle tree を使う
  probabilistic verification から、中央が全状態を再計算せず一部を抽出する方向を採用した。
  本設計の「plan で seed commitment、anchor 集合を seal、その後 reveal」は、抽選対象を
  client が後から grind しないために追加した protocol 上の推論である。
- [A Peer Auditing Scheme for Cheat Elimination in MMOGs](https://citeseerx.ist.psu.edu/document?doi=57f6fb0dc6b7ab61d395de7c0d5e5b5e71179e45&repid=rep1&type=pdf)
  の hybrid central-authority / peer-audit という分担を参考にした。ただし論文の評価値を
  現在の実装性能へ外挿しない。
- [Cheat-Proof Playout for Centralized and Peer-to-Peer Gaming](https://people.cs.umass.edu/~liberato/home/publication/cheat-proof-playout-for-centralized-and/)
  が扱う cell/cluster 的な大規模 game の分割は、zone/interest group ごとに witness roster
  と audit epoch を作る今後の設計候補である。

## 現在の実装と測定

実装は `src/x/game_audit/open_world/`、純粋な routing/conflict policy と証明は
`src/x/game_audit/audit/open_world_*.{mbt,mbtp}` にある。

現在テストしている境界:

- policy/seed commitment と anchor seal の照合
- close manifest の登録数と indexed Merkle leaf の照合
- seed 公開後の偽 anchor inclusion の拒否
- registry truncation / slot substitution / authenticated missing-slot capability
- non-membership proof の key/root/count/path 改ざんと曖昧な二重 evidence の拒否
- observer manifest の roster 順序非依存性、plan/slot/digest/signature の cross-use 拒否
- `n > 3f`, `n-f` registration certificate と observer 起点 missing-slot conflict
- signing ledger の exact retry、別 digest 拒否、root/size 不変、plan/slot 分離
- store の CAS、共有 ledger 間の競合拒否、store failure-before-signature
- trusted anchor の完全一致復元と empty/foreign snapshot の拒否
- authority checkpoint の session/manifest/authenticated-map membership からの anchor 公開
- 同一 observer/key の batch 内置換と、古い anchor proof の拒否
- linear head advance、history duplicate、gap/stale/cross-boundary の非告発
- same-epoch digest fork と next-epoch wrong-parent fork の evidence
- ordered gap batch の一括回復、再送 no-op、途中失敗時の全 planned advance rollback
- signed checkpoint + anchor + membership proof の wire envelope 再認証
- canonical CBOR/version/shape と byte/text/proof/page budget の fail-closed admission
- gap request の `max_items` と gap response 件数への同一 page 上限
- 非 canonical encoding、truncation、巨大な CBOR 宣言長の allocation 前拒否
- cursor-bound gap request、未整列 source の pagination、件数超過・不正 page の無変更拒否
- authority、parent epoch、participant evidence の cross-use 拒否
- signed challenge、sample、sparse economic、high-value の中央昇格
- witness certificate の peer finalization
- genuine deterministic replay capability の central finalization

Apple M5 arm64、MoonBit `0.1.20260724`、FNV/mock signature の構造コスト:

| Benchmark batch | Mean |
| --- | ---: |
| delayed sample selection × 1,000 | 666.31 µs |
| Merkle-eligible provisional gate × 1,000 | 3.01 ms |
| valid inclusion による偽 conflict 拒否 × 1,000 | 1.16 ms |
| 10,000-entry map の non-membership 検証 × 1,000 | 13.90 ms |
| 4 observer (`f=1`) registration certificate × 1,000 | 6.01 ms |
| 10,000-slot observer omission 検出 × 1,000 | 28.36 ms |
| observer ledger の新規登録署名 × 1,000 | 15.10 ms |
| conflicting observer 署名拒否 × 1,000 | 561.21 µs |
| trusted signing anchor 検証 × 1,000 | 660.84 µs |
| rolled-back signing store 拒否 × 1,000 | 524.94 µs |
| 1,024-observer anchor map の publication 検証 × 1,000 | 12.45 ms |
| signing anchor head の連続更新 × 1,000 | 141.55 µs |
| signing anchor gap の atomic batch 回復 × 1,000 | 231.21 µs |
| wire anchor head の fetch + 再認証 + atomic 回復 × 1,000 | 4.42 ms |
| same-epoch checkpoint fork evidence × 1,000 | 119.79 µs |

provisional gate は単一-leaf proof、checkpoint/capability 比較、空 evidence collector の
構築を含む。conflict 拒否は同じ slot/digest の inclusion を検証して告発しない経路である。
non-membership は authenticated treap の検索経路を再構成し、entry count を含む root と
照合する。この実装での検証は expected `O(log registered slots)` であり、最悪計算量の
保証ではない。observer certificate は roster canonicalization と三つの mock signature
検証を含む。observer omission は certificate capability の境界比較、key 照合、10,000-slot
non-membership path の再構成を含むが、game replay は含まない。
新規署名は in-memory CAS 予約、mock signature、authenticated-map root 更新を含む。conflict
拒否は予約済み digest の検索だけで、署名も root 更新も行わない。anchor の二つの測定は
cached root/size の完全一致または不一致判定であり、disk I/O や remote anchor 取得を含まない。
publication 検証は 1,024-entry authenticated map の一つの membership path、session、manifest、
checkpoint capability の比較を含み、authority 署名検証自体は事前に完了している。
head の二つの測定も published capability 作成と署名検証を setup で完了しており、Map lookup、
親子比較、accepted history 更新または opaque evidence 作成だけを測る。
batch 回復は 1,000 step の非破壊 planning と一括 history commit を含み、約 0.231 µs/head だった。
wire 回復は cursor index lookup、checkpoint 再hash、mock署名検証、membership proof 検証、
capability 構築、同じ atomic commit を含み、約 4.42 µs/head だった。source index 構築、
serialization、socket、disk I/O は benchmark loop 外で、production 暗号も含まない。
network、storage、完全 game replay の測定ではない。実際に
FNV はテスト作成中に異なる単一-leaf payload の root collision を起こしたため、本番の
安全性判断には一切使えない。

同じ環境で versioned codec と `experimental_crypto@0.0.2` adapter を分離して測った。

| Benchmark batch | Mean |
| --- | ---: |
| canonical envelope encode × 1,000（16 proof steps） | 7.50 ms |
| bounded/canonical envelope decode × 1,000（16 proof steps） | 20.23 ms |
| 64-envelope gap page decode | 1.74 ms |
| experimental SHA-256 × 1,000（短い文字列） | 1.52 ms |
| experimental Ed25519 sign | 3.99 ms |
| experimental Ed25519 verify | 2.36 ms |
| 実暗号 envelope decode + capability open | 2.29 ms |
| 6,178-byte中央v2 bundleのtransparency/plan/seal/encounter/observer署名、2 map inclusion、Merkle inclusion、PvE replay（workerd DO） | 96 ms |

single-leaf envelope は mock で 400 bytes、SHA-256/Ed25519 で 1,064 bytes だった。
pure MoonBit の実暗号経路では Ed25519 が codec より支配的なので、checkpoint 頻度、同一
checkpoint の検証 cache、edge/peer との検証分担を先に設計する価値がある。ただし、この依存は
未監査かつ end-to-end constant-time 未保証を明記しており、これは相互運用と構造コストの測定で
あって production security の主張ではない。

## 未実装

- 監査済み・side-channel 要件を満たす SHA-256/BLAKE3 と Ed25519 の production adapter
- zone/epoch 委任 key と key rotation
- 動的 zone/interest-group observer assignment と observer key rotation
- `OpenWorldObserverSigningStore` の production durable/CAS adapter と crash/concurrency test
- anchor checkpoint head gossip の production transport / fanout / remote witness quorumへの接続
- head history と signed checkpoint envelope の durable 保存、pruning、外部 fork alert
- gap transport の socket adapter、再試行/backpressure、複数 peer の応答選択
- 複数 epoch の compact append-only consistency proof
- local-first DB の transactional persistence、appeal window、pruning worker
- risk-adaptive sampling controller と中央 replay queue の backpressure
- encounter ごとの witness assignment、離脱、NAT/partition 時の再構成
- open-world 固有のboss/objective/cooldown/PvP deterministic kernel（現在は共通PvE参照kernel）

## Cloudflare中央fallbackの現在地

version 2 open-world bundleは、署名済みaudit planとanchor seal、独立publisherのtransparency checkpoint、
plan/sealの2本のauthenticated-map proof、遅延公開seed、observer rosterと`n-f` registration signatures、
eligible-set Merkle proof、完全PvE encounter bundleを運ぶ。中央jobはworld/session、authority、audit plan、
seal、encounterに加え、transparency log session、publisher key、checkpoint digestをbundle外から固定する。これにより、
seed公開後に同じauthorityが後付けで別plan/sealを署名しても受理しない。全event graphとgame checkpoint
三rootまで再生し、observer quorumとeligible inclusionも一致した場合だけ`verified`になる。

2026-08-04のlocal workerd小規模runでは、6,178-byte bundle、enqueue 16.131 ms、Queue delivery
1,136.114 ms、Queue待ちを除くDO内検証96 msだった。8 heads、4 contenders、2 DO × 2 headsの単発runで
あり分布値ではない。Queueの約1秒はbatch timeoutで、play pathには置かない。

東京→`apac-ne` hintのremote benchmarkでは、7,112-byte bundleが5,177.180 msでdeliveryされ
`verified`になった。eligible itemを保存し、3,141-byte current-owner proofの検証とhead更新は
216.444 ms、更新後のmarketplace照会20回はmean 29.781 ms / p95 102.303 msだった。これは単一地域
hintの1 runであり、全地域SLAではない。

汎用checkpoint witness collectionをopen-world modeへ接続した別の20 runでは、公開pull、端末内署名、
3/4 quorum、collection-backed sealが20/20成立した。敵対burstを除くclean pathはmean 755.969 ms /
p95 1,347.831 msだった。ただしこれはencounter checkpointの収集経路であり、上記transparency head
trackerへのremote fanoutを完成させた意味ではない。

plan/sealが独立publisherの署名済みtransparency checkpointへ含まれることまで検証する。2本のmap keyは
world/epochへ固定し、seal valueはaudit digestとseal digestを同時にcommitする。現時点ではtrusted
transparency headを認証済み管理APIが固定するため、そのheadを複数remote witnessへfanoutしてfork/rollbackを
検知するproduction transportは引き続き必要である。
