# converge documentation

このディレクトリは、CRDT を基盤にしたリアルタイムゲーム監査について、
研究上の根拠、ゲーム設計、実装済み contract、測定結果を分離して記録する。
ゲーム非依存のcheckpoint contractは `src/audit/`、用途依存の実装は
`src/x/game_audit/` の実験的namespaceに分離する。

## 最初に読む文書

- [ライブラリとして一般化する境界](./library-boundary-ja.md)
  - mechanism / policy / game semanticsの分離、package昇格条件、保証しないこと
- [ゲーム監査prototypeの全体像](./game-audit-overview-ja.md)
  - 何を作ったか、三modeの違い、実装package、保証境界、残ロードマップ
- [実装が満たすべき要求仕様](./game-audit-requirements-ja.md)
  - MUST/SHOULD、信頼境界、mode別要件、受入条件、現在の充足状態
- [persistence / transport 実装契約](./game-audit-implementation-contract-ja.md)
  - DB relation、atomic seal、durable outbox、ACK、retry、gap recovery、crash consistency
- [TLA+配送・永続化モデル](../formal/tla/README.md)
  - crash、drop、partition、durable outbox、exact-parent、条件付きliveness
- [汎用 checkpoint audit 層](../src/audit/README.md)
  - cadence/retention、精度式、commitment adapter、head、Merkle/AuthMap、証明限界
- [研究とアーキテクチャの統合サーベイ](./research-and-architecture-ja.md)
  - 文献から採用した考え、全体構成、1:N/N:N の違い、保証と未保証、roadmap
- [検証可能なリアルタイムゲームの設計](./telegraph-game-design-ja.md)
  - 予兆、回避窓、client prediction、ゲームの面白さを損ねにくい表現
- [公開状態 PvP epoch と N:N 相互検証](./pvp-epoch-ja.md)
  - 同時移動/攻撃/score、equivocation、witness接続、計算量と実測
- [不規則 encounter の選択的アンチチート](./open-world-audit-ja.md)
  - open world の遅延抽選、Merkle anchor seal、peer finality、中央 replay budget
- [Multiplayer checkpoint audit prototype](./game-audit-prototype.md)
  - capability pipeline、形式証明、benchmark、contract reconciliation ledger
- [BFT-CRDT research summary](./bft-crdt-research.md)
  - CRDT/BFT 層に限定した背景と現在の adapter 境界
- [Experimental game-audit stack](../src/x/game_audit/README.md)
  - 実験的namespaceの責務、package構成、個別の検証コマンド
- [Game audit wire protocol v1 / open-world replay v2](./game-audit-wire-ja.md)
  - versioned canonical CBOR、decode budget、実暗号adapter、wire/crypto実測
- [Cloudflare Workers game-audit evaluation](./cloudflare-game-audit-ja.md)
  - 1:N、N:N、open-worldのSQLite-backed Durable Object実装とlocal workerd実測
- [Node player-local SQLite adapter](../examples/node-audit-runtime/README.md)
  - event/equivocation、atomic seal、outbox/ACK、peer route lease、bounded HTTP fanout、fork隔離の端末参照実装

## Source of truth

| 対象 | Source of truth | 確認方法 |
| --- | --- | --- |
| 公開 API と capability の構築可能性 | `src/**/pkg.generated.mbti` | `moon info` |
| 実行時の受理・拒否条件 | `src/**/*.mbt` | `moon test`, `moon check --target all` |
| 論理 predicate と不変条件 | `src/audit/*.mbtp`, `src/x/game_audit/audit/*.mbtp` | `just prove` |
| 配送・永続化の有限状態遷移 | `formal/tla/CheckpointDelivery.tla`, `formal/tla/WitnessQuorum.tla` | `just tla-check`, `just tla-counterexamples` |
| production runtimeの実装要件 | `docs/game-audit-implementation-contract-ja.md` | contract受入テスト、fault injection |
| 暗号・永続化・完全 transcript | `crypto`、三mode bundle verifier、Cloudflare DO/Queue | PvE/PvP/open-world prototype実装済み、production監査未達 |
| 性能値 | benchmark の当該実行結果 | `just bench` |
| 面白さ・知覚上の妥当性 | playtest と telemetry | 現在は設計仮説 |

文書とコードが食い違う場合、証明済み contract を無断で弱めない。実装を直すか、
仕様判断が必要なら最小の反例と未解決事項を ledger に残す。

## 現在の検証コマンド

```sh
just check-all
just check-audit-boundary
just test
just build
just prove
just test-audit-runtime
just tla-check
just tla-counterexamples
just test-audit-layered
just bench-audit-layered
just bench-game-pkg replay
just bench-game-pkg open_world
just test-cf-game-audit
just check-cf-game-audit
just test-node-audit-runtime
just check-node-audit-runtime
```

2026-08-05 時点で、汎用checkpoint policy/head/event-time/closure/ACK/atomic seal/delivery
authenticationとvote semilatticeに39 goals、central replay artifact、公開PvP gate、
open-world transparency/中央検証、marketplace生成記録の永続化gateとcurrent-owner inventory
head gate、cooldown/objective、raid clearを含むgame auditに161 goals、計200 proof goals。
FNV/mockに加えて
experimental SHA-256/Ed25519 adapterを実測するが、未監査なのでproduction securityの
根拠にはしない。test総数は実行時の`moon test`出力をsource of truthとする。
