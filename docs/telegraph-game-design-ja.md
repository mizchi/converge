# 検証可能なリアルタイムゲームの設計

研究上の根拠と全体アーキテクチャは
[研究とアーキテクチャの統合サーベイ](./research-and-architecture-ja.md)にまとめている。
この文書は game feel とルール表現に焦点を当てる。

## 結論

監査対象を映像の全フレームにせず、勝敗・被弾・資産生成を変える離散的な
境界だけに絞る。操作感はクライアント予測、補間、アニメーション、音で即時に
返し、確定判定は整数 tick の小さな決定性 kernel で行う。

このリポジトリの PvE encounter kernel は次の文法を実装する。

```text
予兆を権威者が署名
  -> プレイヤーが予兆 digest に依存する回避入力を署名
  -> 権威者が入力 digest と受信 tick を署名
  -> manifest が時間順で非重複な複数攻撃の完全な計画を固定
  -> checkpoint がイベント集合と公開状態の root を固定
  -> 決定性 replay で攻撃間の位置・HP・死亡・clear を計算
  -> clear 時の生存者だけに決定的な loot effect を発行
  -> 既存の inventory/checkpoint/marketplace 検証へ接続
```

Valve のネットワーク解説も、サーバー simulation を tick に分けつつ、表示は
snapshot 間の補間、ローカル操作は client-side prediction、重要な hit 判定は
server-side lag compensation で扱う。この「表示の連続性と判定の離散性を
分離する」考えを、再実行可能なログ境界に移した設計である。

## 三つの時間を混ぜない

| 時間 | 用途 | ログ |
| --- | --- | --- |
| render clock | 60/120 fps の描画、VFX、カメラ、補間 | 原則保存しない |
| simulation tick | 移動意図、skill、予兆、被弾などの規則 | 経済・勝敗に効く入力だけ保存 |
| audit epoch | 入力集合、state root、asset delta の確定 | checkpoint と Merkle proof を保存 |

高い描画 fps と高い監査 tick rate は同じものではない。入力直後の dodge
animation はローカルで開始してよいが、被弾と loot は監査 tick で決める。

## 実装予算から逆算したencounter設計

旧PvE-v1 baselineでは、1 attack・1 player・1 dodgeの実暗号bundleが2,585 bytes、decode、4署名検証、
event graph認証、replay、checkpoint照合がlocal workerdのDO内で23 msだった。asset-effect eventと
receipt rootを加えたPvE-v2は短いsessionで3,145 bytes、open-world wrapperの実runで7,045 bytes、
完全検証52 msだった。
1 command・2 players・4 witness中3 approvalの公開状態PvP bundleは3,546 bytesで、同じくDO内の
event/checkpoint/witness署名検証、replay、quorum判定が36 msだった。
Queueの単発配送はbatch timeoutにより約1.04秒だが、これは操作応答経路ではない。したがってゲームは
次の二経路を明確に分けるのが望ましい。

```text
play path: input -> client prediction -> authority receipt -> provisional hit/clear演出
audit path: semantic checkpoint -> compact bundle -> peer/central replay -> tradable result unlock
```

### Remote witness実測をゲーム時間へ写す

初回の東京→`apac-ne` hint remote比較では、3 peerのapprovalを並列fanoutしたquorum wallが
mean 1.093秒 / p50 0.940秒、逐次fanoutがmean 2.467秒 / p50 2.652秒だったため逐次は採用しない。
旧p95列は旧floor-index計算で20 sampleのmaxになっていたため、tail設計には使わない。
通常settlementの比較には、敵対burstを除いたrun単位の
`collection start + parallel quorum + seal`を`clean_seal_path`として使う。

```text
操作応答       : 同じframe〜数tickでprovisional表示
checkpoint生成 : 2 s / 15 s / 30 sなどgame固有cadence
peer quorum     : checkpoint間で並列pipeline
economic seal  : quorum後に非同期commitし、rank・取引・高価値報酬だけ確定
```

平均accepted-seal到達を`macro/2 + clean mean`、保守的budgetを`macro + clean p95`と置くと、
東京→`apac-ne` hintの各mode 20 runと現在のpresetから次を得る。これはSLAでもrollback幅でもなく、
provisional結果を保持するengineering estimateである。

| mode | macro | clean mean / p95 | 平均event→seal | 保守値 | 表現 |
| --- | ---: | ---: | ---: | ---: | --- |
| N:N PvP | 2 s | 0.744 / 1.238 s | 1.744 s | 3.238 s | hit/塗りは即時、rankは約4秒のsettlement窓 |
| 1:N PvE | 15 s | 0.865 / 1.268 s | 8.365 s | 16.268 s | clear演出は即時、lootは鑑定・bind状態 |
| open world | 30 s | 0.756 / 1.348 s | 15.756 s | 31.348 s | encounter報酬は使用可、譲渡だけlock |

同じPvP workloadを東京clientから測ると、clean pathは`apac-ne` mean 0.744秒 / p95 1.238秒、
`wnam` mean 1.555秒 / p95 1.983秒、`weur` mean 1.831秒 / p95 2.472秒だった。2秒macroへ
合成した保守値はそれぞれ約3.238秒、3.983秒、4.472秒になる。session/party/matchのwitness collectionは
参加者の主地域に寄せる。同じunitを世界共通に固定して遠距離peer全員へ低latencyを期待しない。

この地域差はgame ruleを変える理由にはしない。地域ごとに変えてよいのはsettlement表示、未確定epoch
上限、authority fallback開始時間である。回避窓やhit判定を監査RTTに合わせて広げると、地域ごとに
ゲーム性が変わるため避ける。

quorumが次のmacro checkpointより遅くてもcheckpoint生成を止めない。collectionを複数in-flightにし、
未確定epoch数に上限を設ける。上限を超えたときも入力を止めるより、ranked/economic resultだけを
authority fallbackへ昇格する方が自然である。プレイヤーには秒数カウントを直接見せず、試合終了演出、
リザルト集計、宝箱の鑑定、trade settlement、extraction countdownのような既存の待ち時間へ重ねる。

この測定は単一client・単一egressであり、異なるpeer source間の公平性や世界全体のtailを示さない。
modeごとのproduction値は地域・回線クラス・quorum人数で再測定し、settlement窓だけを調整する。

長いraid全体を一つの巨大bundleにせず、phase移行、boss HP閾値、wipe、clearなど、ゲーム上も自然な
区切りでcheckpointを回す。一phase内では攻撃計画をcommitし、表示frame、particle、補間軌跡は捨てる。
これにより計算量と保存量を攻撃・意味のある入力数に比例させ、戦闘時間や描画fpsには比例させない。

- 通常dropとXPはpeer certificateで先に確定できる設計にし、中央Queueを全戦闘の必須latencyにしない。
- rare/tradable dropは入手演出を即時に出し、約定・譲渡だけをaudit完了までlockする。
- tradable dropにはencounter/playerから決まるasset idを使い、retryで別itemを増殖させない。
- loot tableの乱数はpull/wave開始時にcommitし、client固有乱数だけから経済資産を作らない。
- audit bundle上限へ近づいたら入力を捨てず、phase checkpointを早める。欠落bundleを「成功」と扱わない。
- 同じ操作を複数イベントへ重複記録せず、`telegraph -> player intent -> authority receipt`の因果鎖で表す。
- replay mismatchは即banではなく、報酬保留、追加witness、appeal用保存へ回す。通信切断とcheatを混同しない。

この構造なら予兆を長くして監査時間を稼ぐ必要はない。予兆長は人間の反応とnetwork jitterから決め、
監査は非同期にする。面白さに効く制約は「不可逆な結果に、短い決定性の説明が存在すること」であり、
画面表現を決定性kernelと同じ粒度へ落とすことではない。

## 回避窓

現在の実装は次をすべて要求する。

```text
visible_tick + min_reaction_ticks <= client_tick < resolve_tick
client_tick <= authority_received_tick
authority_received_tick - client_tick <= max_backdate_ticks
abs(destination - committed_start) <= max_dodge_distance
```

さらに入力 event は予兆 event を因果依存に持ち、receipt event は入力 event を
因果依存に持つ。`client_tick` 単体は信用しない。プレイヤーが任意に過去へ
戻せないよう、権威者の署名した受信 tick からの遡及幅を制限する。

同じ attack に二つの異なる正当な入力を出したプレイヤーは、到着順で片方を
選ばず equivocation とする。この状態は吸収的なので、各 replica が異なる順で
受け取っても同じ結果になる。checkpoint が既に commit した証拠を replay 入力
から省けないよう、公開 API は authority-verified checkpoint の `event_root` と
渡された transcript の Merkle root の一致を要求する。authority が不完全な集合
自体へ署名する問題は、1:N では authority の信頼境界、N:N では participant
attestation/challenge の境界で扱う。

予兆時間は少なくとも一つ有効な入力 tick を含まなければならない。実ゲームの
初期値は次の予算から決め、地域・回線クラスごとの実測で調整する。

```text
telegraph duration
  >= intended human reaction budget
   + p95 uplink/jitter budget
   + tick quantization margin
```

`max_backdate_ticks` はクライアント申告 ping ではなく、権威者側の観測と
matchmaking policy から決める。上限を超えた通信不良は cheat と断定せず、
入力保留、再接続、非経済モードへの降格などで扱う。

## 面白さを保ちやすい表現

監査可能性と相性がよいのは、操作を遅くするゲームではなく、不可逆な判断の
前に意味のある予告があるゲームである。

- 予兆 AoE: 形・中心・発動 tick を先に固定し、表示の膨張や震えは自由に補間する。
- projectile: 発射 intent を固定し、飛翔時間を反応窓として使う。着弾だけを監査する。
- charge/release: 溜め開始で威力・範囲を commit し、release tick で解決する。
- rhythm/beat: beat 内は滑らかに動かし、parry、回避、combo 成否を beat 境界で決める。
- capture/hold: 一瞬の接触ではなく複数 tick の占有を積算し、単発の遅延差を薄める。
- shield/poise: 一回の境界誤差を即死にせず、回復可能な resource に吸収する。
- provisional feedback: 命中音や drop 演出は即時に出し、取引可能化だけを checkpoint 後にする。

反対に、chaotic rigid-body physics、連続 body blocking、1 frame の差で高価値資産が
決まる last hit、クライアントだけが知る hidden information は監査 kernel と相性が
悪い。必要なら当たり判定を固定小数点の capsule/grid/navmesh に射影し、経済結果を
離散イベントへ寄せる。

## ゲームモード別

### 1:N の FF14 型 PvE

権威サーバーが boss script、予兆、input receipt を署名する。boss の乱数 seed は
pull 時に commit し、使った後に reveal する。クライアントは移動と animation を
即時予測する。被弾、clear、loot entitlement だけを replay する。現在の最小 kernel
はこの形で、一次元 arena の時間順で非重複な複数 AoE、攻撃間の位置、player HP、
死亡を扱う。さらに防御phase終了後へdamage phaseを切り、そこで生存者の署名済みattack、
cooldown、boss HP、enrage、boss clearを再生するreferenceを追加した。

phaseを分けるのは監査都合だけではない。FF14の履行技後の攻撃可能時間、break/stagger、
add処理後のburn phaseのように見せれば、どのplayerが攻撃可能だったかが明確で、通信順の
tie-breakをゲーム内の区切りへ変換できる。cooldown違反はparty全体のreplayを失敗させず、
その攻撃damageだけを抑止して違反playerをrootへ残す。これにより一人のspamで全員の報酬を
巻き戻すgriefを避ける。重なる予兆とphaseをまたぐ継続damageは次の拡張対象である。

### 1:N の Vampire Survivors 型 co-op

大量の敵を一体ずつ署名しない。wave seed、spawn schedule、skill intent、定期的な
player keyframe をログにし、雑魚の補間と VFX はローカルに置く。checkpoint ごとに
aggregate damage、alive/dead、drop entitlement を再計算する。共有 pickup は
deterministic recipient rule を先に manifest へ入れる。

### N:N の LoL / Splatoon 型対戦

プレイヤーだけの完全 P2P は、全員へ hidden state を配る限り wallhack を防げない。
visibility filtering と最終 hit 判定には referee/authority を残すのが現実的である。
peer は署名済み intent、receipt、公開 state transition を相互検証し、authority の
矛盾を challenge できる。

現在のcertificate層では、game manifest、独立referee key、witness roster、fault上限
`f` をcheckpointのsession manifestへcommitする。`n > 3f` のとき `n - f` 人が
domain-separatedなreplay一致証言へ署名すれば、referee checkpointと組み合わせて
challengeを解決できる。challengeまたはequivocationしたwitnessはapprovalに数えない
が、最大`f`人の妨害だけではcertificateを停止できない。

この計算はゲーム人数をそのまま安全性と同一視しない。Splatoon型の8人なら`f=2`、
quorum=6までは設定できるが、4人チーム全体のcollusionには耐えない。LoL型の10人なら
`f=3`、quorum=7までであり、5人チーム全体をfault domainとみなす場合はplayerだけで
条件を満たせない。その脅威を扱うranked matchでは、複数運営regionのobserver、
tournament referee、遅延replay workerなど、playerと独立したwitnessをrosterへ加える。
account数だけを増やすSybil witnessは独立故障として数えない。

witness署名はrender frameごとではなくaudit epochの公開結果へだけ行う。試合中の
hit marker、塗り、score演出はprovisionalに即時表示し、certificate待ちで操作を止めない。
certificateが不足したepochはcheat確定ではなく、rank反映・報酬・market移転だけを
保留し、referee replayまたは追加observerへ回す。これにより監査遅延をゲームフィール
から切り離せる。

固定 round の commit/reveal は先読みを防げる一方、全 action に使うと操作感を
損ねる。対象は draft、同時選択、ult の target commit、loot roll など、元から
wind-up が許される判断に限定する。通常移動や aim は client prediction と bounded
rewind を使う。少人数で Byzantine quorum 条件を満たせない場合は authority fallback
を必須にする。

実装済みの最小kernelは、各tickを移動・攻撃判定・damage/score確定の三相に分ける。
移動と任意攻撃を同じsampled commandへ入れるため、監査都合で操作を二者択一にしない。
相打ちは両teamへ得点し、同じplayer/tickの異なるcommandはepoch全体のequivocationとして
無効化する。checkpoint一致後に得たopaqueなreplay結果だけがhonest witness署名APIへ進む。
manifestでcooldownを有効にした場合、早すぎる再攻撃は移動commandまで取り消さずattackだけを
抑止し、違反playerをpublic state rootへ残す。capture objectiveは移動とdamageの後に評価し、
生存teamが単独占拠したtickだけ加点する。これは一frameのlast touchではなくhold時間を価値に
変えるため、100--200 ms級の入力揺れを面白さを壊さず吸収しやすい。
仕様、resource bound、benchmarkは
[公開状態 PvP epoch と N:N 相互検証](./pvp-epoch-ja.md)に記録する。

### オープンワールドの不規則 encounter

固定 match と違い、近くに誰がいるかを事前には決められない。そこで encounter 開始時に
interest cell、party、近傍 observer から一時的な witness roster を作り、通常の小さな
戦闘は peer replay certificate で確定する。証人が不足した durable result、rare drop、
signed challenge、遅延抽選に当たった encounter だけを中央 replay へ送る。

抽選は encounter 後でもよいが、抽選対象の Merkle root を閉じてから seed を公開する。
先に seed を見せると、プレイヤーが encounter id や開始時刻を変えて監査を引き直せる。
見た目の戦闘はこの close/reveal を待たず進め、次のように結果の重さで UX を変える。

| Outcome | 即時表現 | 監査待ちの扱い |
| --- | --- | --- |
| `Ephemeral` | VFX、damage number、雑魚消滅 | provisional のまま許可 |
| `Durable` | XP/quest 演出 | account 反映を保留可能 |
| `Tradable` | drop 箱と入手演出 | bind 状態で保持し trade を lock |
| `HighValue` | 特別演出 | 常に中央 replay 後に unlock |

現在のWorkerは`Tradable/HighValue`生成を、authority署名asset event、loot kernel、Merkle receipt、
finalized encounterの一致後だけ保存する。game UIでは検証前も箱や獲得toastを消さず、
「鑑定中」「取引ロック」のような既存のゲーム語彙で状態を見せるのがよい。検証失敗時はitemを
突然消すより、隔離inventoryへ移して再検証・appealを案内する。transfer後の出品ではcurrent-owner
inventory proofを提示し、Workerのper-asset checkpoint headをexact parentで進める経路まで実装した。
proofがない場合も、最後に検証・保存したcurrent owner以外は許可しない。残る課題は、後から祖先
checkpointがrejectされた場合の隔離伝播とappeal中のUIである。

この制約は「報酬を遅く見せる」のではなく、「結果はすぐ感じさせ、不可逆な利用だけを
遅らせる」ためのものになる。FF14 型 FATE/hunt なら参加・攻撃・離脱を離散 tick にし、
Vampire Survivors 型なら雑魚位置を捨てて wave seed と集約 counter を監査する。
Splatoon 型なら塗りの見た目を即時反映し、score に効く粗い tile claim を epoch root に
する。LoL 型の roaming skirmish では projectile、dash、CC、death、objective last-hit を
監査 event にし、animation path 全体は残さない。

所有権移転も毎frameの戦闘入力と同じlatency要求にしない。ゲーム上は`Offer/Reserve`を即時に見せ、
交換演出や入手toastを出したまま、短い`Settlement`で両者のversion付きtransferとinventory rootを
checkpoint化する。settlement前は装備previewやparty内利用まで許し、再transfer・消費・market出品の
ような二重使用可能な操作だけをlockする。MMOのtrade window、dungeon clear chest、extraction、
match終了報酬はこの境界を自然に置ける。これにより26 ms級のproof検証やWAN round tripをcombat
loopへ混ぜず、プレイヤーには「交換が成立した瞬間」が明確に見える。

詳細な脅威モデル、四段階 protocol、中央 replay budget は
[不規則 encounter の選択的アンチチート](./open-world-audit-ja.md)に分離した。

## 保証と未保証

| Claim | Authority | 状態 |
| --- | --- | --- |
| dodge 受理には六つの検証条件がすべて必要 | MoonBit prove contract | Proven |
| 異なる dodge の到着順で結果が変わらない | replay tests | Tested |
| checkpoint に含まれる入力を replay から省くと拒否される | Merkle-root binding test | Tested |
| 生存者以外の loot effect は kernel が拒否する | sealed replay test | Tested |
| loot eventとreceipt rootが一致しないitemは中央replayを通らない | central replay tests | Tested |
| Workerへ保存するには5個の永続化条件がすべて必要 | MoonBit prove contract | Proven |
| 人間の反応時間に対して現在値が最適 | 実機 playtest | Unmet |
| aimbot と熟練者を正当な入力だけから識別できる | 対象外 | Not guaranteed |
| hidden-information cheat を peer replay だけで防げる | 対象外 | Not guaranteed |
| N:N certificate は通常approval署名をreplay証言として流用できない | attestation tests | Tested |
| PvP commandの配送順を変えても同時KO、team score、rootが一致する | replay tests | Tested |
| 正のPvP scoreは敵対damageによるalive-to-defeated遷移を要求する | MoonBit prove contract | Proven |
| cooldown内の再攻撃はdamageを発生させない | MoonBit prove + replay tests | Proven + Tested |
| contested objectiveまたは非占拠teamは加点されない | MoonBit prove + replay tests | Proven + Tested |
| raid clearは防御phase成功とboss HP 0を同時に要求する | MoonBit prove + replay tests | Proven + Tested |
| honest PvP witness署名はcheckpoint一致済みreplay resultを要求する | capability/session tests | Tested boundary |
| `n > 3f` なら二つの `n-f` quorum の交差は `f` を超える | MoonBit prove contract | Proven |
| open-world の sample/challenge/high-value は中央 replay へ進む | MoonBit prove contract | Proven |
| seed reveal 後の偽 encounter anchor は確定できない | Merkle seal integration tests | Tested |
| FNV/mock signature が production security を持つ | 対象外 | Not guaranteed |
| experimental SHA-256/Ed25519 adapter が監査済み・constant-time である | upstream の対象外 | Unmet |

MoonBit の proof は論理的な受理 gate を検証する。暗号の安全性、hash collision、
decoder の allocation 安全性、整数 overflow、完全 transcript を作る transport/storage の
正しさは別境界である。wire decoder の allocation/整数境界は preflight と回帰 test で管理し、
proof 済みと混同しない。

## 参考資料

注釈付き文献一覧と、各文献から採用した点・採用していない点は
[統合サーベイの文献マップ](./research-and-architecture-ja.md#文献マップ)を参照する。
