# Game audit wire protocol v1 / open-world replay v2

## 目的と境界

`src/x/game_audit/wire` は、observer signing-anchor checkpoint を network/storage の
byte列へ変換する境界である。opaque な `PublishedOpenWorldObserverSigningAnchor` は送らない。
受信側は次の順序を必ず通す。

```text
raw bytes
  -> total-byte budget
  -> CBOR length/depth preflight
  -> CBOR decode
  -> deterministic re-encode equality
  -> version/shape/text/proof/item budgets
  -> untrusted envelope value
  -> authority signature + checkpoint digest
  -> session/manifest/exact membership proof
  -> opaque published-anchor capability
```

wire decoder の成功はゲーム上の正当性を意味しない。allocation-safeな構文として復元できた
ことだけを示す。checkpoint/open-world capability gate を通って初めてhead trackerへ渡せる。

## Encoding

RFC 8949 CBORのdefinite-length値だけを使う。mapは使わず、version付き固定長arrayでfield順を
固定する。decoderは一度decodeした値を再encodeし、元byte列と一致しない非最短整数表現等を
拒否する。

| 型 | CBOR array |
| --- | --- |
| envelope | `[1, signed_checkpoint, anchor, membership_proof]` |
| signed checkpoint | `[checkpoint, digest, signature, authority_key]` |
| checkpoint | `[session, epoch, previous, manifest, event_root, public_state_root, asset_delta_root, hidden_or_null]` |
| anchor | `[observer_id, signer_key, root, size]` |
| membership proof | `[key, value, left_digest, right_digest, entry_count, path]` |
| path step | `[direction(0/1), key, value, sibling_digest]` |
| gap request | `[1, session, publisher, after_epoch, after_digest, target_epoch, max_items]` |
| gap response | `[1, envelopes]` |

PvE central replay bundleはasset-effect evidenceを必須化したversion 2、PvP bundleはversion 1、
open-world replay bundleは外部transparency linkを必須化したversion 2 contractである。

| 型 | CBOR array |
| --- | --- |
| PvE bundle | `[2, authority_peer_id, signed_game_checkpoint, config, players, attacks, transcripts, asset_effects]` |
| player | `[player_id, public_key, initial_x]` |
| attack | `[attack_id, visible_tick, resolve_tick, center_x, radius, damage]` |
| attack transcript | `[attack_id, signed_telegraph, dodge_evidence]` |
| dodge evidence | `[signed_input, signed_receipt, intent, observed_receipt]` |
| signed event | `[session, digest, signature, author_key, dependency_digests, event]` |
| event | `[event_id, dependency_ids, lamport, row_op]` |
| asset-effect evidence | `[authority_signed_source_event, typed_asset_effect]` |
| create effect | `[0, asset_id, recipient_id, item_type, quantity, output_index]` |
| transfer effect | `[1, asset_id, from_owner, to_owner, expected_version]` |

| 型 | CBOR array |
| --- | --- |
| PvP bundle | `[1, referee_peer_id, signed_checkpoint, config, teams, players, witnesses, max_faults, commands, attestations]` |
| command evidence | `[signed_command, signed_receipt, command_intent, observed_receipt]` |
| witness | `[witness_id, public_key]` |
| signed attestation | `[[checkpoint_digest, participant_id, purpose, choice], digest, signature, signer_key]` |

| 型 | CBOR array |
| --- | --- |
| open-world PvE bundle | `[2, signed_audit_plan, signed_anchor_seal, transparency_envelope, game_manifest, sample_numerator, sample_denominator, registered_count, revealed_seed, observers, max_faults, signed_observations, eligibility_proof, pve_bundle]` |
| transparency envelope | `[signed_transparency_checkpoint, audit_membership_proof, seal_membership_proof]` |
| signed registration observation | `[[audit_digest, observer_id, registration_index, encounter_digest], digest, signature, signer_key]` |
| eligibility proof | `[leaf_index, leaf_count, merkle_path]` |
| Merkle step | `[direction(0/1), sibling_digest]` |

current-owner inventory listing bundleはversion 1で、ゲーム全体のtranscriptではなく、現在の
authenticated inventory rootに対する1 assetのmembershipと、そのrootを再実行したwitness quorumを
運ぶ。

| 型 | CBOR array |
| --- | --- |
| inventory listing bundle | `[1, signed_checkpoint, game_manifest_digest, witnesses, max_faults, attestations, inventory_proof]` |
| inventory proof | `[asset_record, authenticated_map_proof]` |
| asset record | `[asset_id, current_owner_id, item_type, quantity, origin_source_event, origin_output_index, origin_receipt_digest, version, last_event]` |

中央verifierはauthority署名と期待session/checkpoint/game manifest、`n > 3f` roster、`n-f` replay
witness、origin `ItemReceipt`、`public_state_root` membership、seller=current ownerを一体で検証する。
bundleが自己申告するcheckpointをlatest headとしては信用しない。Durable Objectがassetごとに保持する
headに対し、exact parent、epoch前進、owner変更時のversion前進を満たす場合だけCAS更新する。

`intent`と`observed_receipt`は署名event payloadから独立に信用しない。replay kernelがcanonical
payloadと完全一致することを再確認する。署名eventはdecode後に`BFTAdapter`へ渡し、session、hash、
roster、signature、equivocation、causal dependencyをすべて通った`AuthenticatedEvent`だけをkernelへ
渡す。同じdigestをbundle内で再利用した場合も曖昧性として拒否する。

`Digest/PublicKey/Signature` は現在の汎用BFT型に合わせてlower-hexを含められるCBOR textとして
運ぶ。algorithm suiteは攻撃者が指定するwire fieldにしない。期待するhash/verifier/keyと
suite versionはsession manifestまたは信頼済み接続設定で固定する。将来binary-onlyのsuiteへ
移る場合はwire versionを上げる。

## Checkpoint delivery authentication v1

`src/audit/delivery_auth`はCBOR bundleとは独立した、application非依存かつdestinationごとの配送認証境界である。
producerとwitnessが署名するstatementは、可変長fieldを`decimal MoonBit String length:value`で連結し、
先頭domainを`checkpoint-delivery-auth-v1`に固定する。field順は次の通り。

```text
protocol_version, purpose, manifest_digest, scope_id, unit_id,
destination_id, epoch, previous_checkpoint, checkpoint_digest,
canonical_envelope
```

`created_order`、lease、attempts、created timeはtransport metadataなのでproducer署名へ含めない。
これらはsource durable outboxとの完全一致で認証する。各witnessは
`checkpoint-delivery-approval-v1 + statement_digest + witness_id`を署名する。receiverはcontrol planeで
固定したproducer identity/key、重複のないwitness roster、必要approval数に対し、producer署名と全approvalを
検証した後だけopaque `AuthenticatedCheckpointDelivery`を生成できる。

Cloudflare referenceの外側JSONは署名対象のcanonical encodingではなく搬送表現にすぎない。Workerは
producer/witness IDを各256文字、roster/approvalを各32件、SHA-256 digest/public keyを64 lower-hex、
Ed25519 signatureを128 lower-hexへ制限してからMoonBit verifierへ渡す。game adapterはmodeのfault
assumptionに従って必要quorumを設定する。既定fixtureは4 witness中3 approvalだが、fixture秘密seedは
benchmark/test専用である。

remote collectionの`collection_id`はdomain、boundary、destination、epoch、checkpoint digestから
sourceが決定するlookup keyであり、単独では認証情報ではない。公開GETは署名対象statementとpolicy、
公開POSTはcollection IDと1件の署名approvalだけを運ぶ。sourceは保存済みstatementへapprovalを再結合して
MoonBit verifierを通す。collection開始deadlineは現在時刻より後かつ最大24時間、IDは1,024文字、
roster/approvalは各32件までに制限する。ready collectionからsealする際も、seal requestのexact
statementと再照合する。peer clientは公開policyのroster keyとローカルseed由来keyを照合し、seedを
authorityへ送らず1 approvalだけをPOSTする。Cloudflare referenceは`CF-Connecting-IP`のraw値を保存せず、
server secret付きHMAC-SHA-256 bucketへ変換してcollectionごとに1秒8件へ制限する。client指定の内部bucketは
入口で除去する。このrate metadataは署名対象ではなくtransport admissionであり、NAT/botnet間の公平性を
保証しない。

## Default receive budgets

| 制約 | v1 default |
| --- | ---: |
| single envelope | 65,536 bytes |
| gap request | 16,384 bytes |
| gap response | 1,048,576 bytes |
| one text field | 4,096 UTF-8 bytes |
| authenticated-map path | 64 steps |
| gap request `max_items` / gap response | 256 envelopes |
| CBOR nesting | 64 |

PvE bundle v2の既定上限は次の通りである。

| 制約 | v1 default |
| --- | ---: |
| bundle | 1,048,576 bytes |
| one text field | 4,096 UTF-8 bytes |
| players | 64 |
| attacks / transcripts | 各256 |
| total dodge evidence | 4,096 |
| asset effects | 256 |
| dependencies per event | 64 |
| values per row operation | 16 |

PvP bundle v1は同じ1 MiB/text/dependency/operation上限に加え、2 teams、64 players、64 witnesses、
4,096 commands、64 attestationsを上限とする。decoder成功後も、expected session/referee/checkpoint、
player/referee roster境界、全event graph、deterministic replay、witness manifest、`n-f` quorumを
中央verifierが別々に検査する。

open-world v2 wrapperも1 MiBを上限とし、64 observers、64 signed observations、64 Merkle steps、
各64 stepsのtransparency map proofs、および
内包するPvE bundleの全上限を適用する。decoder後はexpected world/encounter session、authority、
audit/seal/encounterと独立transparencyの4 checkpoint digest、plan/sealのexact map membership、
遅延seed commitment、`n > 3f` observer policy、`n-f`
registration certificate、eligible root inclusion、PvE replay三root、loot kernel、receiptを含む
`asset_delta_root`を順に検査する。

inventory listing v1は262,144 bytes、text 4,096 bytes、64 witnesses、64 attestations、
authenticated-map path 64 stepsを既定上限とする。今回のreal-crypto single-asset fixtureは
3,141 bytesだった。

総byte数はCBOR parserより先に確認する。ただし総byte上限だけでは、短い入力に巨大な宣言長を
埋めた場合のinteger overflowや巨大allocationを防げない。protocol側preflight scannerが
declared byte length、array/map count、nestingを実際のremaining bytesと照合してから外部CBOR
decoderを呼ぶ。`0x7a 0x7fffffff`型の短い巨大text宣言をregression testに固定した。

## Cryptography adapter

`src/x/game_audit/crypto` は `mizchi/experimental_crypto@0.0.2` のSHA-256とEd25519を
`@bft.Hasher/Signer/Verifier`へ接続する。RFC 8032 empty-message vectorとSHA-256 `abc` vector、
real-hash signed envelopeのwire round-tripをテストする。

これは実暗号コストを測るadapterであり、production認定ではない。依存リポジトリ自身が未監査、
end-to-end constant-time未保証と明記している。本番では監査済みnative/host cryptoへの差し替えを
優先する。監査ログの完全性に必要なのはhash/signatureであり、payload confidentialityは別contract
である。秘密情報を配送する場合はAEAD/HPKEを別envelopeとして設計する。

## 2026-08-04 baseline

Apple M5、MoonBit `0.1.20260724`、wasm-gc benchmark:

| 操作 | Mean |
| --- | ---: |
| 16-step envelope encode × 1,000 | 7.50 ms |
| 16-step envelope decode × 1,000 | 20.23 ms |
| 64-envelope gap page decode | 1.74 ms |
| SHA-256 short checkpoint text × 1,000 | 1.52 ms |
| experimental Ed25519 sign | 3.99 ms |
| experimental Ed25519 verify | 2.36 ms |
| real-crypto envelope decode + capability open | 2.29 ms |
| 旧2,585-byte PvE-v1 bundle decode + 4 Ed25519 verify + replay + checkpoint match（workerd DO内） | 23 ms |
| 3,546-byte PvP bundle decode + event/checkpoint/witness Ed25519 verify + replay + 3/4 quorum（workerd DO内） | 36 ms |
| 7,045-byte open-world v2/PvE-v2 bundle + asset receiptを完全検証（workerd DO内、小規模再測定） | 52 ms |
| 検証済みitem生成のSQLite照会 × 20 | mean 2.096 ms / p95 4.095 ms |
| 3,141-byte current-owner bundle検証 + per-asset head更新（local workerd） | 26.527 ms |
| 更新後のcurrent-owner出品照会 × 20（local workerd） | mean 2.931 ms / p95 5.901 ms |

single-leaf mock envelopeは400 bytes、SHA-256/Ed25519 envelopeは1,064 bytesだった。実暗号経路は
Ed25519が支配的である。checkpoint頻度、duplicate verification cache、edge/peer間の検証分担、
監査済み高速backendを実測対象にする必要がある。

## Guarantee status

| Claim | 状態 |
| --- | --- |
| byte/canonical/version/shape/text/proof/itemの一条件でも偽ならadmitしない | MoonBit 9 goals Proven |
| round-trip、非canonical、unsupported version、truncation、request/responseを含む各budget | Tested |
| 巨大declared lengthを外部decoder前に拒否する | Tested |
| SHA-256/Ed25519 known vectors | Tested |
| PvE bundle canonical round-trip、version、byte/player/evidence/asset/dependency budgets | Tested |
| PvE bundleの全署名event認証、game checkpoint三root、loot receipt root一致 | Tested |
| PvP bundle canonical round-trip、version、byte/player/command/attestation/dependency budgets | Tested |
| PvP bundleの全署名event、checkpoint、replay、`n-f` witness certificate | Tested locally + remote benchmark |
| open-world v2 bundleの4 checkpoint、2 publication proofs、遅延seed、`n-f` observer、eligible inclusion、PvE replay | Tested locally + remote benchmark |
| inventory listing v1のcanonical round-trip、byte/witness/attestation/proof budgets | Tested |
| current-owner verifierのauthority/checkpoint/manifest/witness/origin/root/owner binding | Tested locally + remote benchmark |
| dependencyがproduction secure/constant-timeである | Unmet |
| socket、retry、multi-peer response selection | Unmet |
