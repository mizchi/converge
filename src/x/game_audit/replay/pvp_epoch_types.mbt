///|
/// Fixed public rules for one short adversarial PvP replay epoch.
pub(all) struct PvpEpochConfig {
  match_id : String
  epoch : Int
  previous_checkpoint : @bft.Digest
  player_max_hp : Int
  ticks_per_epoch : Int
  max_late_ticks : Int
  max_move_distance : Int
  arena_min_x : Int
  arena_max_x : Int
  attack_range : Int
  attack_damage : Int
  score_per_elimination : Int
} derive(Eq, Debug)

///|
/// v1 deliberately models exactly two public teams.
pub(all) struct PvpTeam {
  team_id : String
  initial_score : Int
} derive(Eq, Debug)

///|
/// Public player state at the beginning of an epoch.
pub(all) struct PvpPlayer {
  player_id : String
  public_key : @bft.PublicKey
  team_id : String
  initial_x : Int
  initial_hp : Int
} derive(Eq, Debug)

///|
/// One sampled client command. Movement and an optional attack are submitted
/// together so responsiveness does not require choosing between them.
pub(all) struct PvpCommandIntent {
  match_id : String
  epoch : Int
  base_checkpoint_digest : @bft.Digest
  tick : Int
  player_id : String
  move_to_x : Int
  attack_target_id : String?
} derive(Eq, Debug)

///|
/// Referee observation used only to enforce the public late-input window.
pub(all) struct PvpCommandReceipt {
  command_digest : @bft.Digest
  received_tick : Int
} derive(Eq, Debug)

///|
/// Exact authenticated command and referee receipt consumed by replay.
pub(all) struct PvpCommandEvidence {
  input : @bft.AuthenticatedEvent
  receipt : @bft.AuthenticatedEvent
  intent : PvpCommandIntent
  observed : PvpCommandReceipt
} derive(Eq, Debug)

///|
pub(all) struct PvpPlayerState {
  player_id : String
  team_id : String
  position_x : Int
  hp : Int
} derive(Eq, Debug)

///|
pub(all) struct PvpTeamState {
  team_id : String
  score : Int
} derive(Eq, Debug)

///|
/// Optional public capture zone. It is evaluated once per simulation tick
/// after movement and damage, and scores only uncontested occupation.
pub(all) struct PvpObjectiveRule {
  center_x : Int
  radius : Int
  score_per_tick : Int
} derive(Eq, Debug)

///|
pub(all) enum PvpEpochRefusal {
  InvalidEpochConfiguration
  InvalidTeamRoster
  InvalidPlayerRoster
  InvalidWitnessRoster
  TooManyCommands
  InvalidCommandEvidence(Int)
  ConflictingCommandReceipt(@bft.Digest)
  EmptyGameManifest
  CheckpointRefereeMismatch
  CheckpointSessionMismatch
  CheckpointEpochMismatch
  CheckpointParentMismatch
  CheckpointManifestMismatch
  CheckpointEventRootMismatch
  CheckpointPublicStateRootMismatch
  CheckpointAssetDeltaRootMismatch
  CheckpointHiddenStatePresent
} derive(Eq, Debug)

///|
/// Deterministic public-state replay before a referee checkpoint is attached.
pub struct PvpEpochCandidate {
  session : String
  referee : @bft.PublicKey
  config : PvpEpochConfig
  game_manifest : @bft.Digest
  manifest : @bft.Digest
  event_root : @bft.Digest
  public_state_root : @bft.Digest
  asset_delta_root : @bft.Digest
  player_states : Array[PvpPlayerState]
  team_states : Array[PvpTeamState]
  equivocators : Array[String]
  cooldown_violators : Array[String]
  accepted_commands : Int
} derive(Eq, Debug)

///|
pub(all) enum PvpEpochCandidateResult {
  PvpCandidateReady(PvpEpochCandidate)
  PvpCandidateRefused(PvpEpochRefusal)
} derive(Eq, Debug)

///|
pub struct PvpEpochResolution {
  candidate : PvpEpochCandidate
  checkpoint_digest : @bft.Digest
} derive(Eq, Debug)

///|
pub(all) enum PvpEpochFinalizeResult {
  PvpEpochFinalized(PvpEpochResolution)
  PvpFinalizeRefused(PvpEpochRefusal)
} derive(Eq, Debug)
