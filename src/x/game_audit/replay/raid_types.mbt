///|
/// Public rules for the deterministic damage phase following a telegraphed
/// defense phase. Separating phases makes the alive roster unambiguous.
pub(all) struct DungeonRaidRules {
  boss_max_hp : Int
  player_attack_damage : Int
  player_attack_cooldown_ticks : Int
  damage_phase_start_tick : Int
  enrage_tick : Int
} derive(Eq, Debug)

///|
pub(all) struct DungeonPlayerAttackIntent {
  encounter_id : String
  player_id : String
  tick : Int
} derive(Eq, Debug)

///|
pub(all) struct DungeonPlayerAttackReceipt {
  input_digest : @bft.Digest
  received_tick : Int
} derive(Eq, Debug)

///|
pub(all) struct DungeonPlayerAttackEvidence {
  input : @bft.AuthenticatedEvent
  receipt : @bft.AuthenticatedEvent
  intent : DungeonPlayerAttackIntent
  observed : DungeonPlayerAttackReceipt
} derive(Eq, Debug)

///|
pub(all) enum DungeonRaidRefusal {
  InvalidRaidRules
  DefensePhaseRefused(DungeonEncounterRefusal)
  InvalidPlayerAttackEvidence(Int)
  ConflictingPlayerAttackReceipt(@bft.Digest)
  EmptyRaidManifest
  RaidCheckpointAuthorityMismatch
  RaidCheckpointSessionMismatch
  RaidCheckpointManifestMismatch
  RaidCheckpointEventRootMismatch
  RaidCheckpointPublicStateRootMismatch
  RaidCheckpointHiddenStatePresent
} derive(Eq, Debug)

///|
pub struct DungeonRaidCandidate {
  defense : DungeonEncounterCandidate
  manifest : @bft.Digest
  event_root : @bft.Digest
  public_state_root : @bft.Digest
  boss_hp_value : Int
  accepted_player_attacks_value : Int
  cooldown_violators_value : Array[String]
  cleared_value : Bool
} derive(Eq, Debug)

///|
pub(all) enum DungeonRaidCandidateResult {
  RaidCandidateReady(DungeonRaidCandidate)
  RaidCandidateRefused(DungeonRaidRefusal)
} derive(Eq, Debug)

///|
pub struct DungeonRaidResolution {
  candidate : DungeonRaidCandidate
  checkpoint_digest : @bft.Digest
} derive(Eq, Debug)

///|
pub(all) enum DungeonRaidFinalizeResult {
  RaidFinalized(DungeonRaidResolution)
  RaidFinalizeRefused(DungeonRaidRefusal)
} derive(Eq, Debug)
