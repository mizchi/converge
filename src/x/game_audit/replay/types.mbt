///|
/// Typed durable effect produced by deterministic game replay.
pub(all) enum AssetEffect {
  Create(
    asset_id~ : String,
    recipient_id~ : String,
    item_type~ : String,
    quantity~ : Int,
    output_index~ : Int
  )
  Transfer(
    asset_id~ : String,
    from_owner~ : String,
    to_owner~ : String,
    expected_version~ : Int
  )
} derive(Eq, Debug)

///|
pub(all) enum AssetEffectValidation {
  EffectValid
  MissingAssetId
  MissingRecipient
  MissingItemType
  InvalidQuantity
  InvalidOutputIndex
  MissingOwner
  SameOwner
  InvalidExpectedVersion
} derive(Eq, Debug)

///|
pub trait AssetReplayKernel {
  fn manifest_digest(Self) -> @bft.Digest
  fn replay(Self, @bft.AuthenticatedEvent, AssetEffect) -> Bool
}

///|
/// Reference deterministic kernel. It accepts only an authenticated event whose
/// canonical payload declares the exact requested asset effect.
pub struct CanonicalAssetKernel {
  manifest : @bft.Digest
  effect_author : @bft.PublicKey
}

///|
pub struct ReplayEngine {
  session : String
  kernel : &AssetReplayKernel
}

///|
/// Capability minted only after the configured replay kernel accepts an exact
/// typed effect for an authenticated source event.
pub struct ReplayedAssetEffect {
  source : @bft.AuthenticatedEvent
  manifest : @bft.Digest
  effect : AssetEffect
} derive(Eq, Debug)

///|
pub(all) enum ReplayRefusal {
  SessionMismatch
  InvalidEffect
  InvalidManifest
  KernelRejected
} derive(Eq, Debug)

///|
pub(all) enum ReplayResult {
  Replayed(ReplayedAssetEffect)
  Refused(ReplayRefusal)
} derive(Eq, Debug)

///|
/// Integer-tick rules for the minimal telegraphed-attack replay kernel.
/// Rendering frame rate and interpolation are intentionally outside this type.
pub(all) struct TelegraphDungeonConfig {
  min_reaction_ticks : Int
  max_backdate_ticks : Int
  max_dodge_distance : Int
  arena_min_x : Int
  arena_max_x : Int
  loot_item_type : String
} derive(Eq, Debug)

///|
/// Roster-bound player and the position committed at encounter start.
pub(all) struct DungeonPlayer {
  player_id : String
  public_key : @bft.PublicKey
  initial_x : Int
} derive(Eq, Debug)

///|
/// Authority-authored attack whose response window is visible before resolve.
pub(all) struct TelegraphedAttack {
  attack_id : String
  visible_tick : Int
  resolve_tick : Int
  center_x : Int
  radius : Int
} derive(Eq, Debug)

///|
/// Player-authored input. `client_tick` is never trusted on its own: replay
/// also requires an authority receipt with a bounded later tick.
pub(all) struct DodgeIntent {
  attack_id : String
  player_id : String
  telegraph_digest : @bft.Digest
  client_tick : Int
  to_x : Int
} derive(Eq, Debug)

///|
/// Authority observation of a particular authenticated input.
pub(all) struct DodgeReceipt {
  input_digest : @bft.Digest
  received_tick : Int
} derive(Eq, Debug)

///|
/// Complete evidence for one dodge: player input plus authority receipt.
pub(all) struct DodgeEvidence {
  input : @bft.AuthenticatedEvent
  receipt : @bft.AuthenticatedEvent
  intent : DodgeIntent
  observed : DodgeReceipt
} derive(Eq, Debug)

///|
pub(all) enum DungeonReplayRefusal {
  InvalidConfiguration
  InvalidRoster
  InvalidTelegraph
  EmptyManifest
  CheckpointAuthorityMismatch
  CheckpointSessionMismatch
  CheckpointManifestMismatch
  CheckpointEventRootMismatch
} derive(Eq, Debug)

///|
/// Replay output is a capability: its fields are private, so only the replay
/// function can produce a resolution that can later construct a loot kernel.
pub struct DungeonResolution {
  session : String
  authority : @bft.PublicKey
  attack_id : String
  loot_item_type : String
  manifest : @bft.Digest
  survivors : Array[String]
  hit : Array[String]
  equivocators : Array[String]
  accepted_dodges : Int
} derive(Eq, Debug)

///|
pub(all) enum DungeonReplayResult {
  Resolved(DungeonResolution)
  Refused(DungeonReplayRefusal)
} derive(Eq, Debug)

///|
/// Sealed asset kernel constructed only from a replay-produced resolution.
pub struct DungeonLootKernel {
  session : String
  authority : @bft.PublicKey
  attack_id : String
  loot_item_type : String
  manifest : @bft.Digest
  eligible : Map[String, Bool]
}
