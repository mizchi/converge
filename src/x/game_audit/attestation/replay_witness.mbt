///|
/// Commit the game kernel, referee, complete witness roster, and Byzantine
/// fault bound into one canonical session manifest.
pub fn replay_witness_session_manifest(
  hasher : &@bft.Hasher,
  game_manifest_digest~ : @bft.Digest,
  referee_key~ : @bft.PublicKey,
  witnesses~ : Array[Participant],
  max_faults~ : Int,
) -> @bft.Digest {
  let identities : Array[@witness_manifest.ReplayWitnessIdentity] = []
  for witness in witnesses {
    identities.push({ id: witness.id, key: witness.key })
  }
  @witness_manifest.replay_witness_session_manifest(
    hasher,
    game_manifest_digest~,
    referee_key~,
    witnesses=identities,
    max_faults~,
  )
}

///|
pub fn ReplayWitnessCollector::new(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  checkpoint : @checkpoint.PreparedCheckpoint,
  game_manifest_digest~ : @bft.Digest,
  referee_key~ : @bft.PublicKey,
  witnesses~ : Array[Participant],
  max_faults~ : Int,
) -> ReplayWitnessCollectorBuildResult {
  if game_manifest_digest.0 == "" {
    return InvalidGameManifest
  }
  if referee_key.0 == "" {
    return InvalidRefereeKey
  }
  let evidence = evidence_collector_for_purpose(
    hasher,
    verifier,
    checkpoint,
    witnesses,
    AttestationPurpose::ReplayWitness,
  )
  if !evidence.is_roster_valid() {
    return InvalidWitnessRoster
  }
  if !@audit.replay_witness_policy_valid(witnesses.length(), max_faults) {
    return InvalidWitnessPolicy
  }
  for witness in witnesses {
    if witness.key == referee_key {
      return RefereeIsWitness
    }
  }
  let expected_manifest = replay_witness_session_manifest(
    hasher,
    game_manifest_digest~,
    referee_key~,
    witnesses~,
    max_faults~,
  )
  if checkpoint.checkpoint().manifest_digest != expected_manifest {
    return WitnessManifestMismatch
  }
  WitnessCollectorReady(ReplayWitnessCollector::{
    evidence,
    witness_count: witnesses.length(),
    max_faults,
    referee_key,
  })
}

///|
pub fn ReplayWitnessCollector::deliver(
  self : ReplayWitnessCollector,
  signed : SignedAttestation,
) -> EvidenceDeliveryResult {
  self.evidence.deliver(signed)
}

///|
pub fn ReplayWitnessCollector::required_approvals(
  self : ReplayWitnessCollector,
) -> Int {
  @audit.replay_witness_quorum_size(self.witness_count, self.max_faults)
}

///|
/// Issue a checkpoint- and referee-bound certificate after `n - f` clean
/// replay approvals. Challenges and equivocations remain non-approvals but up
/// to `f` such witnesses cannot veto the certificate.
pub fn ReplayWitnessCollector::certify(
  self : ReplayWitnessCollector,
  verified : @checkpoint.VerifiedCheckpoint,
) -> ReplayWitnessCertificationResult {
  if verified.digest() != self.evidence.checkpoint_digest() {
    return WitnessCheckpointMismatch
  }
  if verified.authority_key() != self.referee_key {
    return WitnessRefereeMismatch
  }
  let evidence = self.evidence.evidence()
  let approval_count = @audit.count_approvals(evidence.approvals)
  let required = self.required_approvals()
  if !@audit.replay_witness_certificate_allowed(
      witness_count=self.witness_count,
      max_faults=self.max_faults,
      approval_count~,
    ) {
    return WitnessQuorumPending(approval_count, required)
  }
  WitnessCertified(WitnessReplayCertificate::{
    checkpoint_digest: verified.digest(),
    referee_key: verified.authority_key(),
    witness_count: self.witness_count,
    max_faults: self.max_faults,
    approval_count,
  })
}

///|
pub fn WitnessReplayCertificate::checkpoint_digest(
  self : WitnessReplayCertificate,
) -> @bft.Digest {
  self.checkpoint_digest
}

///|
pub fn WitnessReplayCertificate::referee_key(
  self : WitnessReplayCertificate,
) -> @bft.PublicKey {
  self.referee_key
}

///|
pub fn WitnessReplayCertificate::witness_count(
  self : WitnessReplayCertificate,
) -> Int {
  self.witness_count
}

///|
pub fn WitnessReplayCertificate::max_faults(
  self : WitnessReplayCertificate,
) -> Int {
  self.max_faults
}

///|
pub fn WitnessReplayCertificate::approval_count(
  self : WitnessReplayCertificate,
) -> Int {
  self.approval_count
}

///|
pub fn WitnessReplayCertificate::required_approvals(
  self : WitnessReplayCertificate,
) -> Int {
  @audit.replay_witness_quorum_size(self.witness_count, self.max_faults)
}

///|
/// Turn an opaque `n - f` replay-witness certificate into the same finality
/// capability consumed by inventory and marketplace gates. The certificate is
/// useful only for the exact authority-authenticated checkpoint it certified.
pub fn finalize_witnessed_checkpoint(
  verified : @checkpoint.VerifiedCheckpoint,
  certificate : WitnessReplayCertificate,
) -> CheckpointFinalizationResult {
  let matches = @audit.checkpoint_replay_capability_matches(
    capability_present=true,
    checkpoint_digest_matches=certificate.checkpoint_digest() ==
      verified.digest(),
    authority_key_matches=certificate.referee_key() == verified.authority_key(),
  )
  if !matches {
    return CheckpointMismatch
  }
  Ready(FinalizedCheckpoint::{ verified, })
}
