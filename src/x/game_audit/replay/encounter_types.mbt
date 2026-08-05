///|
/// Rules that remain fixed for a complete multi-attack PvE encounter.
pub(all) struct DungeonEncounterConfig {
  encounter_id : String
  player_max_hp : Int
  attack_rules : TelegraphDungeonConfig
} derive(Eq, Debug)

///|
/// One authority-authored attack in the precommitted encounter plan.
pub(all) struct DungeonEncounterAttack {
  attack : TelegraphedAttack
  damage : Int
} derive(Eq, Debug)

///|
/// Exact authenticated evidence consumed for one planned attack.
pub(all) struct DungeonAttackTranscript {
  attack_id : String
  telegraph : @bft.AuthenticatedEvent
  dodge_evidence : Array[DodgeEvidence]
} derive(Eq, Debug)

///|
/// Public player state committed by the encounter checkpoint.
pub(all) struct DungeonEncounterPlayerState {
  player_id : String
  position_x : Int
  hp : Int
} derive(Eq, Debug)

///|
pub(all) enum DungeonEncounterRefusal {
  InvalidEncounterConfiguration
  InvalidAttackPlan
  DuplicateAttackTranscript(String)
  UnknownAttackTranscript(String)
  MissingAttackTranscript(String)
  InvalidAttackTelegraph(String)
  EmptyEncounterManifest
  CheckpointAuthorityMismatch
  CheckpointSessionMismatch
  CheckpointManifestMismatch
  CheckpointEventRootMismatch
  CheckpointPublicStateRootMismatch
} derive(Eq, Debug)

///|
/// Deterministic replay result before an authority checkpoint is attached.
/// Private fields prevent callers from forging its committed roots.
pub struct DungeonEncounterCandidate {
  session : String
  authority : @bft.PublicKey
  encounter_id : String
  loot_item_type : String
  manifest : @bft.Digest
  event_root : @bft.Digest
  public_state_root : @bft.Digest
  player_states : Array[DungeonEncounterPlayerState]
  survivors : Array[String]
  defeated : Array[String]
  equivocators : Array[String]
  accepted_dodges : Int
  cleared : Bool
} derive(Eq, Debug)

///|
pub(all) enum DungeonEncounterCandidateResult {
  CandidateReady(DungeonEncounterCandidate)
  Refused(DungeonEncounterRefusal)
} derive(Eq, Debug)

///|
/// Checkpoint-bound capability. Loot authorization can only be derived from
/// this type, never from an unfinalized candidate.
pub struct DungeonEncounterResolution {
  candidate : DungeonEncounterCandidate
  checkpoint_digest : @bft.Digest
} derive(Eq, Debug)

///|
/// Unforgeable evidence that a complete deterministic replay matched one
/// verified checkpoint. The private field prevents callers from asserting a
/// match with an unchecked Boolean.
pub struct CheckpointReplayMatch {
  checkpoint_digest : @bft.Digest
  authority_key : @bft.PublicKey
} derive(Eq, Debug)

///|
pub(all) enum DungeonEncounterFinalizeResult {
  EncounterFinalized(DungeonEncounterResolution)
  Refused(DungeonEncounterRefusal)
} derive(Eq, Debug)

///|
/// Sealed asset kernel constructed only from a finalized encounter.
pub struct DungeonEncounterLootKernel {
  session : String
  authority : @bft.PublicKey
  encounter_id : String
  loot_item_type : String
  manifest : @bft.Digest
  eligible : Map[String, Bool]
}

///|
priv struct DungeonAttackStep {
  positions : Map[String, Int]
  hit : Array[String]
  equivocators : Array[String]
  accepted_dodges : Int
}
