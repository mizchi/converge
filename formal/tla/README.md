# Checkpoint delivery / witness quorum TLA+ model

このディレクトリは、ゲーム固有の戦闘規則ではなく、local-firstな監査ログを
peerから権威サーバーへ確定させる時間的protocolを有限モデルで検査する。
MoonBit/Why3が純粋な受理predicateを担当し、TLA+/TLCは配送順、再送、crash、
packet loss、partitionをまたぐ状態遷移を担当する。
実adapterが満たすtransaction/API契約は
[persistence / transport実装契約](../../docs/game-audit-implementation-contract-ja.md)に定める。

## モデル境界

`CheckpointDelivery.tla`は2 peer、2 epoch、3 eventを使う。epoch 1には別々のpeerが所有する
2 event、epoch 2には追加の1 eventがある。

| 実装上の概念 | TLA+での抽象化 |
| --- | --- |
| replica-local event DB | peerごとの単調な`accepted`集合 |
| trusted watermark | epochまでの全期待eventを受信したというseal条件 |
| Merkle checkpoint | epoch、parent digest、認証済みevent集合を持つrecord |
| durable local DB | `durableCheckpoints`。実装側ではMoonBit write-set + Node/Cloudflare SQLite transaction |
| at-least-once Queue/outbox | `durableOutbox`、network集合、再送action、容量上限 |
| replica-local peer route lease | process crash中の未配送を`durableOutbox`残留、期限後retryとして縮約 |
| authority checkpoint head | exact-parentな`headLog[Authority]` |
| process/network障害 | crash/restart、drop、partition/heal action |

Merkle木、hash衝突耐性、署名偽造困難性はモデル化しない。checkpointのevent集合を
canonical Merkle rootの抽象値として扱い、暗号とtree実装はMoonBit側のtest対象に残す。
micro checkpointも省略し、authorityへ送るmacro sealだけを扱う。

`WitnessQuorum.tla`はdestination-specificな署名収集を4 roster witness、1 intruder、3 approval
quorumへ縮約する。暗号検証結果を`response.valid`として抽象化し、producer認証、distinct roster count、
deadline expiry、ready collectionからreceiver更新までのgateを扱う。

## 検査する性質

正常設定は次の安全性を全到達状態で検査する。

- seal済みcheckpointは当該epochの全eventを含む。
- 同epochをsealした正直なpeerは同じdigestへ収束する。
- peerとauthorityのheadはgenesisから連続するexact-parent chainである。
- eventとseal済みcheckpointはcrashで消失しない。
- authorityはpeerが生成していないcheckpointを受理しない。
- 未ACK outboxが容量上限に達したpeerは次のcheckpointをsealしない。
- witness collectionは有効producer署名とdistinct roster quorumなしにreadyにならない。
- receiverはready collectionなしに進まず、expiryはinvalid判定にもreceiver更新にもならない。

活性は次の条件付き性質である。

```text
eventually always(unpartitioned and all nodes up)
  => eventually(authority head = latest epoch)
```

これは無条件の配送保証ではない。gossip、配送、seal、restart、heal、および最古の
未ACK checkpoint再送が、繰り返し可能なら永久には飢餓しないという公平性を置く。
通常送信の並べ替えは許すが、再試行schedulerは最古epochを優先する。authorityは
current headだけでなく履歴全体との一致をduplicate ACKとして扱うため、遅延した古い
retryもoutboxから除去できる。

witness収集の活性はdeadline expiryを無効にした構成で、未採用の正直なapprovalの送信と配送が
公平ならeventually readyになる、という条件付きである。最初のモデルは「何らかのresponse配送」だけを
公平にしたため、hostile senderがinvalid/既採用duplicateを再投入して正直な待機approvalを永久に
飢餓化する反例を出した。これは公平性を弱めて隠さず、production側にrate limitまたはfair queueを
要求する根拠として残す。

## Red設定

`check-counterexamples.sh`は、load-bearingな制約を一つずつ外した7設定が実際に
反例を生むことを確認する。

| 外す制約 | TLCが示す反例 |
| --- | --- |
| watermark完備後だけseal | epoch 1から相手peerのeventを欠落できる |
| durable outbox | seal直後のcrashで未送信checkpointを失う |
| authorityのexact-parent | epochを飛び越したheadを受理できる |
| packet loss後のretry | 一度dropしたcheckpointが再送されずfinalizeしない |
| outbox capacity gate | 未ACK checkpointを容量より多くsealできる |
| witness collectionのproducer署名gate | producer署名が不正でも3 approvalでreadyになる |
| witness roster gate | intruderをapproval countへ入れられる |

## 実行

```sh
just tla-check
just tla-counterexamples
```

checkpointモデルの正常設定は、安全性・活性とも55,849状態生成、11,340 distinct states、
深さ24で反例なしだった。witness collectionはsafety 336,897生成/30,720 distinct、
liveness 212,993生成/19,456 distinct、深さ18で反例なしだった。7つのRed設定はすべて期待した
反例を検出した。TLCの有限model checking結果であり、任意peer数・任意epoch数・任意roster数の
数学的証明やproduction transport実装の検証を意味しない。現モデルのcrash対象はreplica peerで、
authority process/storageのcrash recoveryもまだ範囲外である。

Node SQLite adapterの4障害点rollbackは実装受入テストであり、SQLite engineをTLCで検査したものではない。
TLA+のatomicなseal遷移を、history/head/outbox/closure/revisionを一transactionで更新する実装契約へ
対応付けている。peer HTTP adapterのdurable route lease/fair retry/fork隔離もNode受入テストであり、
HTTP stackや実credentialをTLCが検査したという意味ではない。

次の拡張候補は、複数authority shard、fork evidence、pruningとappeal windowである。
