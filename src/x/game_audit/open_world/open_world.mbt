///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
fn audit_policy_valid(numerator : Int, denominator : Int) -> Bool {
  denominator > 0 && numerator >= 0 && numerator <= denominator
}

///|
/// Commit the game rules and audit rate used for one world epoch.
pub fn open_world_audit_manifest(
  hasher : &@bft.Hasher,
  game_manifest_digest~ : @bft.Digest,
  observer_manifest_digest~ : @bft.Digest,
  sample_numerator~ : Int,
  sample_denominator~ : Int,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-audit-manifest-v3")
  append_field(buffer, game_manifest_digest.0)
  append_field(buffer, observer_manifest_digest.0)
  append_field(buffer, sample_numerator.to_string())
  append_field(buffer, sample_denominator.to_string())
  append_field(buffer, "indexed-encounter-digest-v1")
  hasher.hash_string(buffer.to_string())
}

///|
/// Bind a closed indexed encounter registry and its exact leaf count back to
/// the audit plan manifest.
pub fn open_world_anchor_seal_manifest(
  hasher : &@bft.Hasher,
  audit_manifest_digest~ : @bft.Digest,
  registered_count~ : Int,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-anchor-seal-manifest-v2")
  append_field(buffer, audit_manifest_digest.0)
  append_field(buffer, registered_count.to_string())
  append_field(buffer, "indexed-encounter-digest-v1")
  append_field(buffer, "authmap-slot-registry-v1")
  hasher.hash_string(buffer.to_string())
}

///|
/// Canonical Merkle payload for one encounter registration slot.
pub fn open_world_encounter_anchor_payload(
  registration_index : Int,
  encounter_digest : @bft.Digest,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-encounter-anchor-v1")
  append_field(buffer, registration_index.to_string())
  append_field(buffer, encounter_digest.0)
  buffer.to_string()
}

///|
/// Canonical authenticated-map key for one encounter registration slot.
pub fn open_world_encounter_registration_key(
  registration_index : Int,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-encounter-registration-v1")
  append_field(buffer, registration_index.to_string())
  buffer.to_string()
}

///|
/// Commit a secret audit seed before encounter anchors are fixed.
pub fn open_world_audit_seed_commitment(
  hasher : &@bft.Hasher,
  world_id~ : String,
  epoch~ : Int,
  seed~ : String,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-audit-seed-v1")
  append_field(buffer, world_id)
  append_field(buffer, epoch.to_string())
  append_field(buffer, seed)
  hasher.hash_string(buffer.to_string())
}

///|
/// Reveal an audit seed only when both the sampling policy and seed opening
/// exactly match the authority-authenticated epoch checkpoint.
pub fn reveal_open_world_audit_epoch(
  hasher : &@bft.Hasher,
  verified : @checkpoint.VerifiedCheckpoint,
  anchor_seal : @checkpoint.VerifiedCheckpoint,
  game_manifest_digest~ : @bft.Digest,
  observer_manifest_digest~ : @bft.Digest,
  sample_numerator~ : Int,
  sample_denominator~ : Int,
  registered_count~ : Int,
  seed~ : String,
) -> OpenWorldAuditEpochRevealResult {
  if !audit_policy_valid(sample_numerator, sample_denominator) {
    return AuditEpochRefused(InvalidAuditPolicy)
  }
  if game_manifest_digest.0 == "" {
    return AuditEpochRefused(InvalidGameManifest)
  }
  if observer_manifest_digest.0 == "" {
    return AuditEpochRefused(InvalidObserverManifest)
  }
  if seed == "" {
    return AuditEpochRefused(InvalidAuditSeed)
  }
  if registered_count < 0 {
    return AuditEpochRefused(InvalidRegisteredCount)
  }
  let checkpoint = verified.checkpoint()
  let expected_manifest = open_world_audit_manifest(
    hasher,
    game_manifest_digest~,
    observer_manifest_digest~,
    sample_numerator~,
    sample_denominator~,
  )
  if checkpoint.manifest_digest != expected_manifest {
    return AuditEpochRefused(AuditManifestMismatch)
  }
  let seal = anchor_seal.checkpoint()
  if anchor_seal.authority_key() != verified.authority_key() {
    return AuditEpochRefused(AuditSealAuthorityMismatch)
  }
  if seal.session_id != checkpoint.session_id {
    return AuditEpochRefused(AuditSealSessionMismatch)
  }
  if seal.epoch != checkpoint.epoch + 1 {
    return AuditEpochRefused(AuditSealEpochMismatch)
  }
  if seal.previous_checkpoint != verified.digest() {
    return AuditEpochRefused(AuditSealParentMismatch)
  }
  let expected_seal_manifest = open_world_anchor_seal_manifest(
    hasher,
    audit_manifest_digest=checkpoint.manifest_digest,
    registered_count~,
  )
  if seal.manifest_digest != expected_seal_manifest {
    return AuditEpochRefused(AuditSealManifestMismatch)
  }
  if seal.event_root.0 == "" {
    return AuditEpochRefused(InvalidEligibleAnchorRoot)
  }
  if seal.public_state_root.0 == "" {
    return AuditEpochRefused(InvalidEligibleRegistryRoot)
  }
  let expected_commitment = open_world_audit_seed_commitment(
    hasher,
    world_id=checkpoint.session_id,
    epoch=checkpoint.epoch,
    seed~,
  )
  match checkpoint.hidden_state_commitment {
    None => AuditEpochRefused(MissingAuditSeedCommitment)
    Some(commitment) =>
      if commitment != expected_commitment {
        AuditEpochRefused(AuditSeedCommitmentMismatch)
      } else {
        AuditEpochRevealed(RevealedOpenWorldAuditEpoch::{
          hasher,
          audit_checkpoint_digest: verified.digest(),
          anchor_seal_checkpoint_digest: anchor_seal.digest(),
          eligible_anchor_root: seal.event_root,
          eligible_registry_root: seal.public_state_root,
          observer_manifest_digest,
          registered_count,
          authority_key: verified.authority_key(),
          world_id: checkpoint.session_id,
          epoch: checkpoint.epoch,
          seed,
          sample_numerator,
          sample_denominator,
        })
      }
  }
}

///|
pub fn RevealedOpenWorldAuditEpoch::audit_checkpoint_digest(
  self : RevealedOpenWorldAuditEpoch,
) -> @bft.Digest {
  self.audit_checkpoint_digest
}

///|
pub fn RevealedOpenWorldAuditEpoch::authority_key(
  self : RevealedOpenWorldAuditEpoch,
) -> @bft.PublicKey {
  self.authority_key
}

///|
pub fn RevealedOpenWorldAuditEpoch::anchor_seal_checkpoint_digest(
  self : RevealedOpenWorldAuditEpoch,
) -> @bft.Digest {
  self.anchor_seal_checkpoint_digest
}

///|
pub fn RevealedOpenWorldAuditEpoch::eligible_anchor_root(
  self : RevealedOpenWorldAuditEpoch,
) -> @bft.Digest {
  self.eligible_anchor_root
}

///|
pub fn RevealedOpenWorldAuditEpoch::eligible_registry_root(
  self : RevealedOpenWorldAuditEpoch,
) -> @bft.Digest {
  self.eligible_registry_root
}

///|
pub fn RevealedOpenWorldAuditEpoch::observer_manifest_digest(
  self : RevealedOpenWorldAuditEpoch,
) -> @bft.Digest {
  self.observer_manifest_digest
}

///|
pub fn RevealedOpenWorldAuditEpoch::registered_count(
  self : RevealedOpenWorldAuditEpoch,
) -> Int {
  self.registered_count
}

///|
/// Deterministically select an already anchored encounter for central replay.
///
/// Production must provide a cryptographic `Hasher` and keep `seed` secret
/// until all eligible anchors for this audit epoch have been authenticated.
pub fn RevealedOpenWorldAuditEpoch::selects_encounter(
  self : RevealedOpenWorldAuditEpoch,
  encounter_anchor : @bft.Digest,
) -> Bool {
  if encounter_anchor.0 == "" || self.sample_numerator == 0 {
    return false
  }
  if self.sample_numerator == self.sample_denominator {
    return true
  }
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-audit-sample-v1")
  append_field(buffer, self.seed)
  append_field(buffer, self.world_id)
  append_field(buffer, self.epoch.to_string())
  append_field(buffer, self.authority_key.0)
  append_field(buffer, encounter_anchor.0)
  let digest = self.hasher.hash_string(buffer.to_string()).0
  let mut bucket = 0
  for index in 0..<digest.length() {
    bucket = (bucket * 33 + digest[index].to_int()) % self.sample_denominator
  }
  bucket < self.sample_numerator
}

///|
fn peer_certificate_matches(
  certificate : @attestation.WitnessReplayCertificate?,
  encounter : @checkpoint.VerifiedCheckpoint,
) -> Bool {
  match certificate {
    None => false
    Some(value) =>
      value.checkpoint_digest() == encounter.digest() &&
      value.referee_key() == encounter.authority_key()
  }
}

///|
fn central_replay_matches(
  replay : @replay.CheckpointReplayMatch?,
  encounter : @checkpoint.VerifiedCheckpoint,
) -> Bool {
  match replay {
    None => false
    Some(value) =>
      value.checkpoint_digest() == encounter.digest() &&
      value.authority_key() == encounter.authority_key()
  }
}

///|
fn encounter_evidence_collector(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  encounter : @checkpoint.VerifiedCheckpoint,
  participant_evidence : @attestation.EvidenceCollector?,
) -> @attestation.EvidenceCollector {
  match participant_evidence {
    Some(value) => value
    None =>
      @attestation.EvidenceCollector::new(
        hasher,
        verifier,
        @checkpoint.prepare_checkpoint(hasher, encounter.checkpoint()),
        [],
      )
  }
}

///|
/// Evaluate an irregular open-world encounter through peer fast-path and
/// selectively escalated central replay.
///
/// Visual-only effects may remain provisional. Durable or tradable effects
/// require a matching replay-witness certificate when not centrally replayed.
pub fn evaluate_open_world_encounter(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  audit_epoch : RevealedOpenWorldAuditEpoch,
  encounter : @checkpoint.VerifiedCheckpoint,
  eligibility_proof~ : @merkle.MerkleProof,
  outcome_class~ : @audit.OpenWorldOutcomeClass,
  peer_certificate? : @attestation.WitnessReplayCertificate,
  central_replay? : @replay.CheckpointReplayMatch,
  participant_evidence? : @attestation.EvidenceCollector,
) -> OpenWorldEncounterGateResult {
  let encounter_anchor = encounter.digest()
  if encounter_anchor.0 == "" {
    return EncounterInvalidAnchor
  }
  if encounter.authority_key() != audit_epoch.authority_key {
    return EncounterEpochAuthorityMismatch
  }
  if encounter.checkpoint().previous_checkpoint !=
    audit_epoch.audit_checkpoint_digest {
    return EncounterEpochParentMismatch
  }
  let registration_index = encounter.checkpoint().epoch
  if registration_index < 0 ||
    registration_index >= audit_epoch.registered_count {
    return EncounterInvalidRegistrationIndex
  }
  if eligibility_proof.leaf_index != registration_index ||
    eligibility_proof.leaf_count != audit_epoch.registered_count {
    return EncounterAnchorNotCommitted
  }
  if !@merkle.verify_inclusion(
      hasher,
      open_world_encounter_anchor_payload(registration_index, encounter_anchor),
      audit_epoch.eligible_anchor_root,
      eligibility_proof,
    ) {
    return EncounterAnchorNotCommitted
  }
  let participant_evidence_option = participant_evidence
  let challenge_present = match participant_evidence_option {
    None => false
    Some(evidence) => {
      if evidence.checkpoint_digest() != encounter.digest() {
        return EncounterEvidenceMismatch
      }
      evidence.evidence().challenged
    }
  }
  let peer_matches = peer_certificate_matches(peer_certificate, encounter)
  let central_present = central_replay is Some(_)
  let central_matches = central_replay_matches(central_replay, encounter)
  let decision = @audit.route_open_world_audit(
    outcome_class,
    peer_certificate_matches=peer_matches,
    challenge_present~,
    sample_selected=audit_epoch.selects_encounter(encounter_anchor),
    central_replay_present=central_present,
    central_replay_matches=central_matches,
  )
  let evidence = encounter_evidence_collector(
    hasher, verifier, encounter, participant_evidence_option,
  )
  match decision {
    @audit.OpenWorldAuditDecision::PeerAccepted =>
      match peer_certificate {
        Some(certificate) =>
          match
            evidence.finalize(
              encounter,
              0,
              replay_match=None,
              witness_certificate=certificate,
            ) {
            @attestation.CheckpointFinalizationResult::Ready(finalized) =>
              EncounterPeerFinalized(finalized)
            _ => EncounterRejected
          }
        None => EncounterRejected
      }
    @audit.OpenWorldAuditDecision::CentralAccepted =>
      match central_replay {
        Some(replay) =>
          match evidence.finalize(encounter, 0, replay_match=Some(replay)) {
            @attestation.CheckpointFinalizationResult::Ready(finalized) =>
              EncounterCentralFinalized(finalized)
            _ => EncounterRejected
          }
        None => EncounterRejected
      }
    @audit.OpenWorldAuditDecision::Provisional => EncounterProvisional
    @audit.OpenWorldAuditDecision::CentralReplayRequired =>
      EncounterCentralReplayRequired
    @audit.OpenWorldAuditDecision::Rejected => EncounterRejected
  }
}

///|
pub fn OpenWorldSealConflict::kind(
  self : OpenWorldSealConflict,
) -> OpenWorldSealConflictKind {
  self.kind
}

///|
pub fn OpenWorldSealConflict::source(
  self : OpenWorldSealConflict,
) -> OpenWorldSealConflictSource {
  self.source
}

///|
pub fn OpenWorldSealConflict::audit_checkpoint_digest(
  self : OpenWorldSealConflict,
) -> @bft.Digest {
  self.audit_checkpoint_digest
}

///|
pub fn OpenWorldSealConflict::seal_checkpoint_digest(
  self : OpenWorldSealConflict,
) -> @bft.Digest {
  self.seal_checkpoint_digest
}

///|
pub fn OpenWorldSealConflict::encounter_digest(
  self : OpenWorldSealConflict,
) -> @bft.Digest {
  self.encounter_digest
}

///|
pub fn OpenWorldSealConflict::registration_index(
  self : OpenWorldSealConflict,
) -> Int {
  self.registration_index
}

///|
pub fn OpenWorldSealConflict::sealed_encounter_digest(
  self : OpenWorldSealConflict,
) -> @bft.Digest? {
  self.sealed_encounter_digest
}

///|
pub fn OpenWorldSealConflict::observer_approval_count(
  self : OpenWorldSealConflict,
) -> Int? {
  self.observer_approval_count
}

///|
fn detect_open_world_seal_conflict_facts(
  hasher : &@bft.Hasher,
  audit_epoch : RevealedOpenWorldAuditEpoch,
  encounter_digest : @bft.Digest,
  registration_index : Int,
  boundary_matches : Bool,
  source : OpenWorldSealConflictSource,
  observer_approval_count : Int?,
  missing_registration : @authmap.AuthMapAbsenceProof?,
  sealed_encounter_digest : @bft.Digest?,
  conflicting_inclusion : @merkle.MerkleProof?,
) -> OpenWorldSealConflictDetection {
  if !boundary_matches {
    return SealConflictBoundaryMismatch
  }
  let missing_option = missing_registration
  let sealed_digest_option = sealed_encounter_digest
  let inclusion_option = conflicting_inclusion
  let inclusion_present = sealed_digest_option is Some(_) &&
    inclusion_option is Some(_)
  let missing_present = missing_option is Some(_)
  let missing_matches = match missing_option {
    Some(proof) =>
      proof.key == open_world_encounter_registration_key(registration_index) &&
      @authmap.verify_non_membership(
        hasher,
        audit_epoch.eligible_registry_root,
        proof,
      )
    None => false
  }
  let inclusion_matches = match (sealed_digest_option, inclusion_option) {
    (Some(sealed_digest), Some(proof)) =>
      proof.leaf_index == registration_index &&
      proof.leaf_count == audit_epoch.registered_count &&
      @merkle.verify_inclusion(
        hasher,
        open_world_encounter_anchor_payload(registration_index, sealed_digest),
        audit_epoch.eligible_anchor_root,
        proof,
      )
    _ => false
  }
  let sealed_digest_matches = match sealed_digest_option {
    Some(value) => value == encounter_digest
    None => false
  }
  match
    @audit.classify_open_world_seal_conflict(
      encounter_boundary_matches=boundary_matches,
      registration_index~,
      registered_count=audit_epoch.registered_count,
      missing_registration_present=missing_present,
      missing_registration_matches=missing_matches,
      conflicting_inclusion_present=inclusion_present,
      conflicting_inclusion_matches=inclusion_matches,
      sealed_digest_matches~,
    ) {
    @audit.OpenWorldSealConflictDecision::RegistryTruncated =>
      SealConflictDetected(OpenWorldSealConflict::{
        kind: TruncatedRegistry,
        source,
        audit_checkpoint_digest: audit_epoch.audit_checkpoint_digest,
        seal_checkpoint_digest: audit_epoch.anchor_seal_checkpoint_digest,
        encounter_digest,
        registration_index,
        sealed_encounter_digest: None,
        observer_approval_count,
      })
    @audit.OpenWorldSealConflictDecision::SlotSubstituted =>
      SealConflictDetected(OpenWorldSealConflict::{
        kind: SubstitutedSlot,
        source,
        audit_checkpoint_digest: audit_epoch.audit_checkpoint_digest,
        seal_checkpoint_digest: audit_epoch.anchor_seal_checkpoint_digest,
        encounter_digest,
        registration_index,
        sealed_encounter_digest: sealed_digest_option,
        observer_approval_count,
      })
    @audit.OpenWorldSealConflictDecision::SlotMissing =>
      SealConflictDetected(OpenWorldSealConflict::{
        kind: MissingSlot,
        source,
        audit_checkpoint_digest: audit_epoch.audit_checkpoint_digest,
        seal_checkpoint_digest: audit_epoch.anchor_seal_checkpoint_digest,
        encounter_digest,
        registration_index,
        sealed_encounter_digest: None,
        observer_approval_count,
      })
    @audit.OpenWorldSealConflictDecision::NoConflict => SealConflictNotFound
    @audit.OpenWorldSealConflictDecision::InvalidEvidence =>
      SealConflictEvidenceInvalid
  }
}

///|
/// Open cryptographic evidence that a sealed indexed registry truncated,
/// omitted, or substituted an authority-signed encounter.
///
/// Invalid or missing Merkle evidence never produces an accusation capability.
pub fn detect_open_world_seal_conflict(
  hasher : &@bft.Hasher,
  audit_epoch : RevealedOpenWorldAuditEpoch,
  encounter : @checkpoint.VerifiedCheckpoint,
  missing_registration? : @authmap.AuthMapAbsenceProof,
  sealed_encounter_digest? : @bft.Digest,
  conflicting_inclusion? : @merkle.MerkleProof,
) -> OpenWorldSealConflictDetection {
  let boundary_matches = encounter.authority_key() == audit_epoch.authority_key &&
    encounter.checkpoint().previous_checkpoint ==
    audit_epoch.audit_checkpoint_digest
  detect_open_world_seal_conflict_facts(
    hasher,
    audit_epoch,
    encounter.digest(),
    encounter.checkpoint().epoch,
    boundary_matches,
    OpenWorldSealConflictSource::AuthoritySignedEncounter,
    None,
    missing_registration,
    sealed_encounter_digest,
    conflicting_inclusion,
  )
}

///|
/// Open conflict evidence from a plan-bound observer quorum even when the
/// sealing authority never issued an encounter checkpoint of its own.
pub fn detect_observed_open_world_seal_conflict(
  hasher : &@bft.Hasher,
  audit_epoch : RevealedOpenWorldAuditEpoch,
  registration : OpenWorldRegistrationCertificate,
  missing_registration? : @authmap.AuthMapAbsenceProof,
  sealed_encounter_digest? : @bft.Digest,
  conflicting_inclusion? : @merkle.MerkleProof,
) -> OpenWorldSealConflictDetection {
  let boundary_matches = registration.audit_checkpoint_digest ==
    audit_epoch.audit_checkpoint_digest &&
    registration.observer_manifest_digest ==
    audit_epoch.observer_manifest_digest
  detect_open_world_seal_conflict_facts(
    hasher,
    audit_epoch,
    registration.encounter_digest,
    registration.registration_index,
    boundary_matches,
    OpenWorldSealConflictSource::ObserverQuorum,
    Some(registration.approval_count),
    missing_registration,
    sealed_encounter_digest,
    conflicting_inclusion,
  )
}
