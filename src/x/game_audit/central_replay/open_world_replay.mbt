///|
pub(all) enum OpenWorldPveCentralReplayRefusal {
  OpenWorldWireReplayRefused(@wire.OpenWorldPveReplayWireError)
  OpenWorldExpectedWorldMismatch
  OpenWorldExpectedAuthorityMismatch
  OpenWorldExpectedAuditCheckpointMismatch
  OpenWorldExpectedSealCheckpointMismatch
  OpenWorldExpectedEncounterCheckpointMismatch
  OpenWorldAuditCheckpointAuthenticationRefused(
    @checkpoint.CheckpointVerification
  )
  OpenWorldSealCheckpointAuthenticationRefused(
    @checkpoint.CheckpointVerification
  )
  OpenWorldAuditTransparencyRefused(
    @open_world.OpenWorldAuditTransparencyRefusal
  )
  OpenWorldAuditEpochRefused(@open_world.OpenWorldAuditEpochRefusal)
  OpenWorldEncounterReplayRefused(PveCentralReplayRefusal)
  OpenWorldObserverPolicyRefused
  OpenWorldObserverEvidenceRefused(@open_world.OpenWorldObservationAlertKind)
  OpenWorldObserverQuorumPending(Int, Int)
  OpenWorldEncounterGateRefused(String)
  OpenWorldAssetListingGateRefused(String)
} derive(Eq, Debug)

///|
/// Public summary of an item creation whose signed source event, deterministic
/// loot kernel, receipt inclusion proof, and finalized encounter checkpoint
/// were checked together. This is evidence of legitimate creation, not a
/// substitute for a later current-owner inventory proof.
pub(all) struct VerifiedItemCreation {
  asset_id : String
  initial_owner_id : String
  item_type : String
  quantity : Int
  output_index : Int
  source_event : @bft.Digest
  checkpoint_digest : @bft.Digest
  inventory_session_id : String
  checkpoint_epoch : Int
} derive(Eq, Debug)

///|
/// Summary issued only after all four trusted checkpoint boundaries,
/// delayed-seed reveal, eligible-set inclusion, n-f registration observation,
/// and the complete PvE replay have passed.
pub struct OpenWorldPveCentralReplayVerified {
  world_id : String
  encounter_session_id : String
  authority_key : @bft.PublicKey
  transparency_checkpoint_digest : @bft.Digest
  audit_checkpoint_digest : @bft.Digest
  seal_checkpoint_digest : @bft.Digest
  encounter_checkpoint_digest : @bft.Digest
  observer_approvals : Int
  required_observer_approvals : Int
  cleared : Bool
  accepted_dodges : Int
  survivors : Array[String]
  defeated : Array[String]
  item_creations : Array[VerifiedItemCreation]
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldPveCentralReplayResult {
  OpenWorldPveReplayVerified(OpenWorldPveCentralReplayVerified)
  OpenWorldPveReplayRefused(OpenWorldPveCentralReplayRefusal)
} derive(Eq, Debug)

///|
pub fn OpenWorldPveCentralReplayVerified::world_id(
  self : OpenWorldPveCentralReplayVerified,
) -> String {
  self.world_id
}

///|
pub fn OpenWorldPveCentralReplayVerified::encounter_session_id(
  self : OpenWorldPveCentralReplayVerified,
) -> String {
  self.encounter_session_id
}

///|
pub fn OpenWorldPveCentralReplayVerified::authority_key(
  self : OpenWorldPveCentralReplayVerified,
) -> @bft.PublicKey {
  self.authority_key
}

///|
pub fn OpenWorldPveCentralReplayVerified::transparency_checkpoint_digest(
  self : OpenWorldPveCentralReplayVerified,
) -> @bft.Digest {
  self.transparency_checkpoint_digest
}

///|
pub fn OpenWorldPveCentralReplayVerified::audit_checkpoint_digest(
  self : OpenWorldPveCentralReplayVerified,
) -> @bft.Digest {
  self.audit_checkpoint_digest
}

///|
pub fn OpenWorldPveCentralReplayVerified::seal_checkpoint_digest(
  self : OpenWorldPveCentralReplayVerified,
) -> @bft.Digest {
  self.seal_checkpoint_digest
}

///|
pub fn OpenWorldPveCentralReplayVerified::encounter_checkpoint_digest(
  self : OpenWorldPveCentralReplayVerified,
) -> @bft.Digest {
  self.encounter_checkpoint_digest
}

///|
pub fn OpenWorldPveCentralReplayVerified::observer_approval_count(
  self : OpenWorldPveCentralReplayVerified,
) -> Int {
  self.observer_approvals
}

///|
pub fn OpenWorldPveCentralReplayVerified::required_observer_approvals(
  self : OpenWorldPveCentralReplayVerified,
) -> Int {
  self.required_observer_approvals
}

///|
pub fn OpenWorldPveCentralReplayVerified::cleared(
  self : OpenWorldPveCentralReplayVerified,
) -> Bool {
  self.cleared
}

///|
pub fn OpenWorldPveCentralReplayVerified::accepted_dodge_count(
  self : OpenWorldPveCentralReplayVerified,
) -> Int {
  self.accepted_dodges
}

///|
pub fn OpenWorldPveCentralReplayVerified::survivor_ids(
  self : OpenWorldPveCentralReplayVerified,
) -> Array[String] {
  self.survivors.copy()
}

///|
pub fn OpenWorldPveCentralReplayVerified::defeated_ids(
  self : OpenWorldPveCentralReplayVerified,
) -> Array[String] {
  self.defeated.copy()
}

///|
pub fn OpenWorldPveCentralReplayVerified::verified_item_creations(
  self : OpenWorldPveCentralReplayVerified,
) -> Array[VerifiedItemCreation] {
  self.item_creations.copy()
}

///|
pub fn OpenWorldPveCentralReplayVerified::verified_item_creation_count(
  self : OpenWorldPveCentralReplayVerified,
) -> Int {
  self.item_creations.length()
}

///|
fn open_world_verified_item_creations(
  hasher : &@bft.Hasher,
  finalized : @attestation.FinalizedCheckpoint,
  opened : Array[OpenedPveAssetReceipt],
) -> Result[Array[VerifiedItemCreation], String] {
  let creations : Array[VerifiedItemCreation] = []
  for item in opened {
    let receipt = item.proof.receipt
    if !@market.market_accepts_listing(
        hasher,
        finalized,
        item.proof,
        replayed=item.replayed,
        seller_id=receipt.recipient_id,
        rejected_ancestor=false,
      ) {
      return Err(receipt.asset_id)
    }
    creations.push({
      asset_id: receipt.asset_id,
      initial_owner_id: receipt.recipient_id,
      item_type: receipt.item_type,
      quantity: receipt.quantity,
      output_index: receipt.output_index,
      source_event: receipt.source_event,
      checkpoint_digest: finalized.digest(),
      inventory_session_id: finalized.checkpoint().session_id,
      checkpoint_epoch: finalized.checkpoint().epoch,
    })
  }
  Ok(creations)
}

///|
fn open_world_gate_refusal_code(
  result : @open_world.OpenWorldEncounterGateResult,
) -> String {
  match result {
    EncounterPeerFinalized(_) => "unexpected_peer_finality"
    EncounterCentralFinalized(_) => "unexpected_central_finality"
    EncounterProvisional => "encounter_provisional"
    EncounterCentralReplayRequired => "central_replay_still_required"
    EncounterRejected => "encounter_rejected"
    EncounterInvalidAnchor => "invalid_encounter_anchor"
    EncounterAnchorNotCommitted => "encounter_anchor_not_committed"
    EncounterEpochAuthorityMismatch => "encounter_authority_mismatch"
    EncounterEpochParentMismatch => "encounter_parent_mismatch"
    EncounterEvidenceMismatch => "encounter_evidence_mismatch"
    EncounterInvalidRegistrationIndex => "invalid_registration_index"
  }
}

///|
/// Verify an irregular open-world encounter without trusting any checkpoint
/// identifier carried by its bundle. Plan, seal, and encounter digests are
/// supplied by the job boundary and all must be anchored externally.
pub fn verify_open_world_pve_replay_bundle(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  bundle_bytes : Bytes,
  expected_world_id~ : String,
  expected_encounter_session_id~ : String,
  expected_authority_key~ : @bft.PublicKey,
  expected_transparency_log_session_id~ : String,
  expected_transparency_publisher_key~ : @bft.PublicKey,
  expected_transparency_checkpoint_digest~ : @bft.Digest,
  expected_audit_checkpoint_digest~ : @bft.Digest,
  expected_seal_checkpoint_digest~ : @bft.Digest,
  expected_encounter_checkpoint_digest~ : @bft.Digest,
  limits~ : @wire.OpenWorldPveReplayWireLimits,
) -> OpenWorldPveCentralReplayResult {
  let bundle = match
    @wire.decode_open_world_pve_replay_bundle(bundle_bytes, limits~) {
    Ok(value) => value
    Err(reason) =>
      return OpenWorldPveReplayRefused(OpenWorldWireReplayRefused(reason))
  }
  let signed_audit = bundle.signed_audit_checkpoint
  let signed_seal = bundle.signed_anchor_seal_checkpoint
  let signed_encounter = bundle.encounter.signed_checkpoint
  if signed_audit.checkpoint.session_id != expected_world_id {
    return OpenWorldPveReplayRefused(OpenWorldExpectedWorldMismatch)
  }
  if signed_audit.authority_key != expected_authority_key ||
    signed_seal.authority_key != expected_authority_key ||
    signed_encounter.authority_key != expected_authority_key {
    return OpenWorldPveReplayRefused(OpenWorldExpectedAuthorityMismatch)
  }
  if signed_audit.digest != expected_audit_checkpoint_digest {
    return OpenWorldPveReplayRefused(OpenWorldExpectedAuditCheckpointMismatch)
  }
  if signed_seal.digest != expected_seal_checkpoint_digest {
    return OpenWorldPveReplayRefused(OpenWorldExpectedSealCheckpointMismatch)
  }
  if signed_encounter.digest != expected_encounter_checkpoint_digest {
    return OpenWorldPveReplayRefused(
      OpenWorldExpectedEncounterCheckpointMismatch,
    )
  }
  let audit_checkpoint = match
    @checkpoint.open_checkpoint(
      hasher, verifier, expected_authority_key, signed_audit,
    ) {
    Opened(value) => value
    Refused(reason) =>
      return OpenWorldPveReplayRefused(
        OpenWorldAuditCheckpointAuthenticationRefused(reason),
      )
  }
  let seal_checkpoint = match
    @checkpoint.open_checkpoint(
      hasher, verifier, expected_authority_key, signed_seal,
    ) {
    Opened(value) => value
    Refused(reason) =>
      return OpenWorldPveReplayRefused(
        OpenWorldSealCheckpointAuthenticationRefused(reason),
      )
  }
  let transparency = match
    @open_world.open_open_world_audit_transparency_envelope(
      hasher,
      verifier,
      expected_publisher_key=expected_transparency_publisher_key,
      expected_publication_checkpoint_digest=expected_transparency_checkpoint_digest,
      log_session_id=expected_transparency_log_session_id,
      world_id=expected_world_id,
      audit_checkpoint~,
      seal_checkpoint~,
      envelope=bundle.audit_transparency,
    ) {
    AuditTransparencyOpened(value) => value
    AuditTransparencyRefused(reason) =>
      return OpenWorldPveReplayRefused(
        OpenWorldAuditTransparencyRefused(reason),
      )
  }
  let observer_manifest_digest = @open_world.open_world_observer_manifest(
    hasher,
    observers=bundle.observers,
    max_faults=bundle.max_faults,
  )
  let audit_epoch = match
    @open_world.reveal_open_world_audit_epoch(
      hasher,
      audit_checkpoint,
      seal_checkpoint,
      game_manifest_digest=bundle.game_manifest_digest,
      observer_manifest_digest~,
      sample_numerator=bundle.sample_numerator,
      sample_denominator=bundle.sample_denominator,
      registered_count=bundle.registered_count,
      seed=bundle.seed,
    ) {
    AuditEpochRevealed(value) => value
    AuditEpochRefused(reason) =>
      return OpenWorldPveReplayRefused(OpenWorldAuditEpochRefused(reason))
  }
  let opened_encounter = match
    open_decoded_pve_replay_bundle(
      hasher,
      verifier,
      bundle.encounter,
      expected_session_id=expected_encounter_session_id,
      expected_authority_key~,
      expected_checkpoint_digest=expected_encounter_checkpoint_digest,
    ) {
    Ok(value) => value
    Err(reason) =>
      return OpenWorldPveReplayRefused(OpenWorldEncounterReplayRefused(reason))
  }
  let registration_index = opened_encounter.checkpoint.checkpoint().epoch
  let collector = match
    @open_world.OpenWorldRegistrationObserverCollector::new(
      hasher,
      verifier,
      audit_checkpoint,
      game_manifest_digest=bundle.game_manifest_digest,
      sample_numerator=bundle.sample_numerator,
      sample_denominator=bundle.sample_denominator,
      observers=bundle.observers,
      max_faults=bundle.max_faults,
      registration_index~,
      encounter_digest=expected_encounter_checkpoint_digest,
    ) {
    RegistrationObserverCollectorReady(value) => value
    _ => return OpenWorldPveReplayRefused(OpenWorldObserverPolicyRefused)
  }
  for observation in bundle.observations {
    match collector.deliver(observation) {
      ObservationAccepted | ObservationDuplicate => ()
      ObservationRejected(alert) =>
        return OpenWorldPveReplayRefused(
          OpenWorldObserverEvidenceRefused(alert.kind),
        )
    }
  }
  let registration = match collector.certify() {
    RegistrationObserved(value) => value
    RegistrationObservationPending(actual, required) =>
      return OpenWorldPveReplayRefused(
        OpenWorldObserverQuorumPending(actual, required),
      )
  }
  if registration.encounter_digest() != expected_encounter_checkpoint_digest {
    return OpenWorldPveReplayRefused(OpenWorldObserverPolicyRefused)
  }
  let resolution = opened_encounter.resolution
  let gate = @open_world.evaluate_open_world_encounter(
    hasher,
    verifier,
    audit_epoch,
    opened_encounter.checkpoint,
    eligibility_proof=bundle.eligibility_proof,
    outcome_class=@audit.OpenWorldOutcomeClass::HighValue,
    central_replay=resolution.replay_match(),
  )
  match gate {
    EncounterCentralFinalized(finalized) => {
      let item_creations = match
        open_world_verified_item_creations(
          hasher,
          finalized,
          opened_encounter.asset_receipts,
        ) {
        Ok(value) => value
        Err(asset_id) =>
          return OpenWorldPveReplayRefused(
            OpenWorldAssetListingGateRefused(asset_id),
          )
      }
      OpenWorldPveReplayVerified(OpenWorldPveCentralReplayVerified::{
        world_id: expected_world_id,
        encounter_session_id: expected_encounter_session_id,
        authority_key: expected_authority_key,
        transparency_checkpoint_digest: transparency.publication_checkpoint_digest(),
        audit_checkpoint_digest: expected_audit_checkpoint_digest,
        seal_checkpoint_digest: expected_seal_checkpoint_digest,
        encounter_checkpoint_digest: expected_encounter_checkpoint_digest,
        observer_approvals: registration.approval_count(),
        required_observer_approvals: registration.required_approvals(),
        cleared: resolution.cleared(),
        accepted_dodges: resolution.accepted_dodge_count(),
        survivors: resolution.survivor_ids(),
        defeated: resolution.defeated_ids(),
        item_creations,
      })
    }
    refused =>
      OpenWorldPveReplayRefused(
        OpenWorldEncounterGateRefused(open_world_gate_refusal_code(refused)),
      )
  }
}
