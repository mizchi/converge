# 公開状態 PvP epoch と N:N 相互検証

この文書は、`src/x/game_audit/replay` の公開状態 PvP kernel、
`src/x/game_audit/pvp_session` の replay witness、`wire` / `central_replay` / Cloudflare
Queue までの接続を記録する。対象は LoL や
Splatoon のゲーム全体ではなく、配送順に依存しない短い audit epoch の最小モデルである。

## Source of truth と不変条件

実行時仕様は `pvp_epoch.mbt`、論理 gate は `audit/pvp_epoch.mbt[p]`、外部から構築可能な
capability は生成済み `.mbti` を source of truth とする。v1 の主要不変条件は次である。

1. 受理コマンドは、生存中、epoch 内、referee receipt の期限内、移動上限内、arena 内である。
2. 同じ `(player, tick)` に異なる二つの authenticated command があれば、その player は
   epoch 全体で equivocator となり、全コマンドが不受理になる。
3. 各 tick は「全移動を同時適用」「移動後の位置で全攻撃を判定」「全 damage と team score
   を同時確定」の三相で処理する。入力配列やネットワーク配送順は勝敗を決めない。
4. 正の score は、敵の有効な攻撃によって target が `hp > 0` から `hp == 0` へ遷移した
   ときだけ、一撃破につき相手 team へ一度加算する。既に死亡した target は再得点にならない。
5. checkpoint は referee、session、epoch、parent、witness-policy manifest、event root、
   public-state root、no-asset root、hidden-state 不在のすべてに一致しなければならない。
6. honest witness 用 API は、上記 checkpoint と deterministic replay から得た
   `PvpEpochResolution` が一致する場合だけ replay-witness 署名を作る。

`CheckpointReplayMatch` と `PvpEpochResolution` は private field を持つ capability であり、
呼び出し側が単なる `true` を replay 成功として注入することはできない。一方、Byzantine
witness は自分の秘密鍵で虚偽へ署名できる。このため certificate の安全性は、commit 済み
witness roster に対する `n > 3f` と `n-f` quorum、および最大 `f` の故障仮定に依存する。

## Protocol

```text
player command ──player signature──▶ AuthenticatedEvent
      │                                    │
      └──────── referee receipt ───────────┘
                         │
              canonical transcript set
                         │
       simultaneous move → attack → damage/score
                         │
        game manifest + witness-policy manifest
                         │
             referee-signed exact checkpoint
                         │
              PvpEpochResolution / replay match
                         │
          n-f replay-witness signatures → certificate
```

player command は `match_id`、`epoch`、直前 checkpoint digest、tick、player、移動先、
任意の攻撃 target を署名対象に含む。移動と攻撃を一つの sampled command にしたため、
プレイヤーは「動くか攻撃するか」を監査形式の都合で選ばなくてよい。referee receipt は
入力 digest と受信 tick を署名し、client clock の完全同期ではなく公開 late window を
検証する。

完全 transcript は command/receipt digest の集合から Merkle root を作る。同じ完全集合なら
順序を変えても root と結果は同じである。欠落検出は checkpoint root と witness が保持・gossip
した receipt に依存するため、transport/storage が完全 transcript を復元する責務は別に残る。

中央検証用の version 1 bundle は referee peer id、署名済み checkpoint、PvP config、team/player
roster、witness roster と fault bound、署名済み command/receipt、replay-witness attestation を
canonical CBOR で運ぶ。受信側は信頼済み job の session、referee key、checkpoint digest と照合し、
全 event を BFT adapter で認証してから同じ kernel を再実行する。最後に commit 済み roster の
`n-f` 署名が集まった場合だけ `verified` を返す。bundle 自身から期待境界を推測しない。

## 面白さを毀損しにくい使い方

audit tick を render frame と同一にしない。クライアントは高頻度に prediction と補間を行い、
監査には粗い position sample、attack intent、objective event だけを残す。hit marker、塗り、
撃破演出は provisional に即時表示し、certificate 待ちで入力を止めない。監査不成立時に保留する
のは rank、報酬、market 移転など不可逆な結果である。

この kernel では移動が攻撃判定より先に確定する。したがって、FF14/Splatoon 型の予兆や射程表示
に対して、期限内にクライアントが回避入力を出せば移動後の位置で外れたことを再現できる。
相打ちは両 team の得点になり、ネットワークで先に届いた側を勝者にしない。

個人 last-hit は v1 に入れていない。同時 batch に人工的な全順序を入れると、同じ入力集合でも
tie-break がゲーム感覚に影響するためである。必要なら team objective、assist share、事前 commit
済み projectile impact tick など、配送順以外の規則を manifest に追加する。hidden state、fog of
war、未公開 projectile は peer へ配らず、visibility-filtering referee の責務に残す。

## 計算量と resource bound

player 数を `P`、witness 数を `W`、epoch tick 数を `T`、command evidence 数を `A` とすると、
現在の replay は概ね `O(A log A + P log P + W log W + T*P)` 時間、
`O(A + P + W)` メモリである。`A log A` は canonical transcript digest の整列を含む。
kernel 内で `P <= 64`、`W <= 64`、`T <= 256`、`A <= 4096`、識別子256文字、座標・HP・score
の上限を検査する。arena 外の座標は差分を計算する前に拒否し、整数 overflow を避ける。

2026-08-04 のローカル MoonBit benchmark（FNV/mock、署名済み capability の生成は測定外）:

| workload | benchmark batch | 1 epoch換算 |
| --- | ---: | ---: |
| 8 players × 16 ticks = 128 commands | 20 replay / 10.79 ms | 約 0.540 ms |
| 64 players × 16 ticks = 1024 commands | 5 replay / 22.62 ms | 約 4.524 ms |

これは production SHA-256/Ed25519、wire decode、DB、network、Queue を含まない kernel 値である。

同日の local workerd 小規模 run（8 heads、4 contenders、2 DO × 2 heads）では、3,546-byteの
実署名 bundleが`verified`へ到達し、Queue待ちを除くDO内decode・署名検証・replay・3/4 quorumは
36 msだった。enqueueは6.370 ms、deliveryは1,045.876 msで、後者は1秒のQueue batch timeoutに
ほぼ支配される。単発runなので分布値ではない。

2026-08-05の初回東京→`apac-ne` hint比較では、3 peerの公開pull・端末内署名・submitを並列化した
quorum wallがmean 1,093.013 ms / p50 940.130 ms、逐次版がmean 2,467.038 ms /
p50 2,651.699 msだった。したがってquorum fanoutは並列にする。旧p95列は旧floor-index計算で
20 sampleのmaxになっていたため、tail設計には使わない。

比較条件を揃えた後続20 runでは、collection開始から並列quorum、sealまでのclean pathが
`apac-ne` mean 744.074 ms / p95 1,238.188 ms、`wnam` mean 1,554.724 ms /
p95 1,983.401 ms、`weur` mean 1,830.777 ms / p95 2,472.400 msだった。2秒macro epochと
pipelineした東京→`apac-ne`のevent→accepted-sealは、一様到着近似でmean約1.744秒、
`macro + measured p95`で約3.238秒である。これはrank/報酬のsettlement budgetであり、hit markerや
次epochの入力を待たせる時間ではない。単一client・単一egress、各20 sampleなので、異なる実peer間の
source fairnessや全地域SLAは未保証である。

## Reconciliation ledger

| Claim | Authority | 状態 |
| --- | --- | --- |
| 受理コマンドは公開 tick/move/receipt 制約を満たす | MoonBit proof contract | Proven |
| 正の score は敵対 damage による alive-to-defeated 遷移を要求する | MoonBit proof contract | Proven |
| cooldown内の再攻撃はdamageを発生せず、違反player IDがpublic state rootへ入る | MoonBit proof + replay regression | Proven + Tested |
| capture objectiveは生存teamが単独占拠したtickだけ加点する | MoonBit proof + replay regression | Proven + Tested |
| 同じ transcript 集合の配送順で public state/root が変わらない | replay regression tests | Tested |
| 同一 player/tick の異なる command は epoch 全体で無効 | replay regression tests | Tested |
| replay 前に honest witness 署名を作れない | private capability + session tests | Tested boundary |
| `n > 3f`, `n-f` certificate は故障上限内で honest witness を含む | witness proof contract | Proven |
| bounded bundleの全event、checkpoint、witness署名を中央で再検証する | wire/central replay/real-crypto tests | Tested locally |
| PvP Queue jobがreplayと`n-f` certificate後だけ`verified`になる | workerd Queue integration | Tested locally |
| hidden information cheat を peer replay だけで防げる | 対象外 | Not guaranteed |
| LoL/Splatoon の完全な物理・projectile・visibilityを検証する | cooldown/capture objectiveの公開状態referenceは実装、projectile/visibilityは未実装 | Partially met |
| remote peerからwitness署名を収集して失効を管理する | 公開pull、端末ローカル署名submit、durable collection、deadline、per-source rate limit、apac-ne/wnam/weur各20-run benchmark | Tested locally + remote E2E / push・端末retry・global fairnessはPending |

次は projectile/visibilityとwire manifest v2を拡張し、remote witnessへのoutbound push/global fair queue、
appeal windowまでのtranscript保持、監査済み暗号backendを接続する。
