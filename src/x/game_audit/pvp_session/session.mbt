///|
/// Collector that is known to be linked to one completed public-state PvP
/// replay. Its fields are private so callers cannot bypass the link checks.
pub struct PvpReplayWitnessSession {
  collector : @attestation.ReplayWitnessCollector
}

///|
pub(all) enum PvpReplayWitnessSessionRefusal {
  ReplayCheckpointMismatch
  ReplayRefereeMismatch
  InvalidGameManifest
  InvalidRefereeKey
  InvalidWitnessPolicy
  InvalidWitnessRoster
  RefereeIsWitness
  WitnessManifestMismatch
} derive(Eq, Debug)

///|
pub(all) enum PvpReplayWitnessSessionBuildResult {
  PvpWitnessSessionReady(PvpReplayWitnessSession)
  PvpWitnessSessionRefused(PvpReplayWitnessSessionRefusal)
}

///|
pub(all) enum PvpReplayWitnessSigningResult {
  PvpReplayWitnessSigned(@attestation.SignedAttestation)
  PvpReplayWitnessCheckpointMismatch
  PvpReplayWitnessRefereeMismatch
} derive(Eq, Debug)

///|
fn map_collector_refusal(
  result : @attestation.ReplayWitnessCollectorBuildResult,
) -> PvpReplayWitnessSessionBuildResult {
  match result {
    WitnessCollectorReady(collector) =>
      PvpWitnessSessionReady(PvpReplayWitnessSession::{ collector, })
    InvalidGameManifest => PvpWitnessSessionRefused(InvalidGameManifest)
    InvalidRefereeKey => PvpWitnessSessionRefused(InvalidRefereeKey)
    InvalidWitnessPolicy => PvpWitnessSessionRefused(InvalidWitnessPolicy)
    InvalidWitnessRoster => PvpWitnessSessionRefused(InvalidWitnessRoster)
    RefereeIsWitness => PvpWitnessSessionRefused(RefereeIsWitness)
    WitnessManifestMismatch => PvpWitnessSessionRefused(WitnessManifestMismatch)
  }
}

///|
/// Construct the N:N witness collector only when the exact referee checkpoint
/// has already matched a deterministic PvP replay.
pub fn prepare_pvp_replay_witness_session(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  checkpoint : @checkpoint.PreparedCheckpoint,
  resolution : @replay.PvpEpochResolution,
  referee_key~ : @bft.PublicKey,
  witnesses~ : Array[@attestation.Participant],
  max_faults~ : Int,
) -> PvpReplayWitnessSessionBuildResult {
  let replay_match = resolution.replay_match()
  if replay_match.checkpoint_digest() != checkpoint.digest() {
    return PvpWitnessSessionRefused(ReplayCheckpointMismatch)
  }
  if replay_match.authority_key() != referee_key {
    return PvpWitnessSessionRefused(ReplayRefereeMismatch)
  }
  map_collector_refusal(
    @attestation.ReplayWitnessCollector::new(
      hasher,
      verifier,
      checkpoint,
      game_manifest_digest=resolution.game_manifest_digest(),
      referee_key~,
      witnesses~,
      max_faults~,
    ),
  )
}

///|
/// Honest-client signing path. A signature is returned only for the exact
/// checkpoint and referee matched by the local deterministic replay.
pub fn sign_pvp_replay_witness(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  checkpoint : @checkpoint.PreparedCheckpoint,
  resolution : @replay.PvpEpochResolution,
  referee_key~ : @bft.PublicKey,
  witness_id~ : String,
  choice~ : @attestation.AttestationChoice,
) -> PvpReplayWitnessSigningResult {
  let replay_match = resolution.replay_match()
  if replay_match.checkpoint_digest() != checkpoint.digest() {
    return PvpReplayWitnessCheckpointMismatch
  }
  if replay_match.authority_key() != referee_key {
    return PvpReplayWitnessRefereeMismatch
  }
  PvpReplayWitnessSigned(
    @attestation.sign_replay_witness_attestation(
      hasher, signer, checkpoint, witness_id, choice,
    ),
  )
}

///|
pub fn PvpReplayWitnessSession::deliver(
  self : PvpReplayWitnessSession,
  signed : @attestation.SignedAttestation,
) -> @attestation.EvidenceDeliveryResult {
  self.collector.deliver(signed)
}

///|
pub fn PvpReplayWitnessSession::required_approvals(
  self : PvpReplayWitnessSession,
) -> Int {
  self.collector.required_approvals()
}

///|
pub fn PvpReplayWitnessSession::certify(
  self : PvpReplayWitnessSession,
  checkpoint : @checkpoint.VerifiedCheckpoint,
) -> @attestation.ReplayWitnessCertificationResult {
  self.collector.certify(checkpoint)
}
