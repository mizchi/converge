///|
pub(all) enum InventoryListingCentralRefusal {
  InventoryListingWireRefused(@wire.InventoryListingWireError)
  InventoryExpectedSessionMismatch
  InventoryExpectedAuthorityMismatch
  InventoryExpectedCheckpointMismatch
  InventoryExpectedGameManifestMismatch
  InventoryCheckpointAuthenticationRefused(@checkpoint.CheckpointVerification)
  InventoryWitnessSessionRefused(String)
  InventoryWitnessEvidenceRefused(@attestation.EvidenceAlertKind)
  InventoryWitnessCheckpointMismatch
  InventoryWitnessAuthorityMismatch
  InventoryWitnessQuorumPending(Int, Int)
  InventoryWitnessFinalizationMismatch
  InventoryOriginMismatch
  InventoryCurrentOwnerProofRefused
} derive(Eq, Debug)

///|
/// Capability summary issued only after an authority checkpoint, n-f replay
/// witness certificate, origin receipt and current-state membership proof agree.
pub struct InventoryListingCentralVerified {
  session_id : String
  checkpoint_digest : @bft.Digest
  previous_checkpoint : @bft.Digest
  authority_key : @bft.PublicKey
  epoch : Int
  public_state_root : @bft.Digest
  asset_id : String
  current_owner_id : String
  version : Int
  last_event : @bft.Digest
  approval_count : Int
  required_approvals : Int
} derive(Eq, Debug)

///|
pub(all) enum InventoryListingCentralResult {
  InventoryListingVerified(InventoryListingCentralVerified)
  InventoryListingRefused(InventoryListingCentralRefusal)
} derive(Eq, Debug)

///|
pub fn InventoryListingCentralVerified::session_id(
  self : InventoryListingCentralVerified,
) -> String {
  self.session_id
}

///|
pub fn InventoryListingCentralVerified::checkpoint_digest(
  self : InventoryListingCentralVerified,
) -> @bft.Digest {
  self.checkpoint_digest
}

///|
pub fn InventoryListingCentralVerified::previous_checkpoint(
  self : InventoryListingCentralVerified,
) -> @bft.Digest {
  self.previous_checkpoint
}

///|
pub fn InventoryListingCentralVerified::authority_key(
  self : InventoryListingCentralVerified,
) -> @bft.PublicKey {
  self.authority_key
}

///|
pub fn InventoryListingCentralVerified::epoch(
  self : InventoryListingCentralVerified,
) -> Int {
  self.epoch
}

///|
pub fn InventoryListingCentralVerified::public_state_root(
  self : InventoryListingCentralVerified,
) -> @bft.Digest {
  self.public_state_root
}

///|
pub fn InventoryListingCentralVerified::asset_id(
  self : InventoryListingCentralVerified,
) -> String {
  self.asset_id
}

///|
pub fn InventoryListingCentralVerified::current_owner_id(
  self : InventoryListingCentralVerified,
) -> String {
  self.current_owner_id
}

///|
pub fn InventoryListingCentralVerified::version(
  self : InventoryListingCentralVerified,
) -> Int {
  self.version
}

///|
pub fn InventoryListingCentralVerified::last_event(
  self : InventoryListingCentralVerified,
) -> @bft.Digest {
  self.last_event
}

///|
pub fn InventoryListingCentralVerified::approval_count(
  self : InventoryListingCentralVerified,
) -> Int {
  self.approval_count
}

///|
pub fn InventoryListingCentralVerified::required_approvals(
  self : InventoryListingCentralVerified,
) -> Int {
  self.required_approvals
}

///|
fn inventory_listing_witnesses(
  bundle : @wire.InventoryListingProofBundle,
) -> Array[@attestation.Participant] {
  let participants : Array[@attestation.Participant] = []
  for witness in bundle.witnesses {
    participants.push({ id: witness.id, key: witness.key })
  }
  participants
}

///|
fn inventory_witness_build_refusal(
  result : @attestation.ReplayWitnessCollectorBuildResult,
) -> String {
  match result {
    WitnessCollectorReady(_) => "unexpected_ready"
    InvalidGameManifest => "invalid_game_manifest"
    InvalidRefereeKey => "invalid_authority_key"
    InvalidWitnessPolicy => "invalid_witness_policy"
    InvalidWitnessRoster => "invalid_witness_roster"
    RefereeIsWitness => "authority_is_witness"
    WitnessManifestMismatch => "witness_manifest_mismatch"
  }
}

///|
/// Verify a compact current-owner listing proof against caller-supplied trust
/// boundaries. The expected checkpoint and game manifest must come from the
/// server's monotonic inventory head, never from an untrusted player alone.
pub fn verify_inventory_listing_proof_bundle(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  bundle_bytes : Bytes,
  expected_session_id~ : String,
  expected_authority_key~ : @bft.PublicKey,
  expected_checkpoint_digest~ : @bft.Digest,
  expected_game_manifest_digest~ : @bft.Digest,
  expected_origin~ : @market.ItemReceipt,
  expected_seller_id~ : String,
  rejected_ancestor~ : Bool,
  limits~ : @wire.InventoryListingWireLimits,
) -> InventoryListingCentralResult {
  let bundle = match
    @wire.decode_inventory_listing_proof_bundle(bundle_bytes, limits~) {
    Ok(value) => value
    Err(reason) =>
      return InventoryListingRefused(InventoryListingWireRefused(reason))
  }
  let signed_checkpoint = bundle.signed_checkpoint
  if signed_checkpoint.checkpoint.session_id != expected_session_id {
    return InventoryListingRefused(InventoryExpectedSessionMismatch)
  }
  if signed_checkpoint.authority_key != expected_authority_key {
    return InventoryListingRefused(InventoryExpectedAuthorityMismatch)
  }
  if signed_checkpoint.digest != expected_checkpoint_digest {
    return InventoryListingRefused(InventoryExpectedCheckpointMismatch)
  }
  if bundle.game_manifest_digest != expected_game_manifest_digest {
    return InventoryListingRefused(InventoryExpectedGameManifestMismatch)
  }
  let verified = match
    @checkpoint.open_checkpoint(
      hasher, verifier, expected_authority_key, signed_checkpoint,
    ) {
    Opened(value) => value
    Refused(reason) =>
      return InventoryListingRefused(
        InventoryCheckpointAuthenticationRefused(reason),
      )
  }
  let prepared = @checkpoint.prepare_checkpoint(
    hasher,
    signed_checkpoint.checkpoint,
  )
  let witness_build = @attestation.ReplayWitnessCollector::new(
    hasher,
    verifier,
    prepared,
    game_manifest_digest=expected_game_manifest_digest,
    referee_key=expected_authority_key,
    witnesses=inventory_listing_witnesses(bundle),
    max_faults=bundle.max_faults,
  )
  let witnesses = match witness_build {
    WitnessCollectorReady(value) => value
    other =>
      return InventoryListingRefused(
        InventoryWitnessSessionRefused(inventory_witness_build_refusal(other)),
      )
  }
  for signed in bundle.attestations {
    match witnesses.deliver(signed) {
      Accepted | Duplicate => ()
      Rejected(alert) =>
        return InventoryListingRefused(
          InventoryWitnessEvidenceRefused(alert.kind),
        )
    }
  }
  let certificate = match witnesses.certify(verified) {
    WitnessCertified(value) => value
    WitnessCheckpointMismatch =>
      return InventoryListingRefused(InventoryWitnessCheckpointMismatch)
    WitnessRefereeMismatch =>
      return InventoryListingRefused(InventoryWitnessAuthorityMismatch)
    WitnessQuorumPending(actual, required) =>
      return InventoryListingRefused(
        InventoryWitnessQuorumPending(actual, required),
      )
  }
  let finalized = match
    @attestation.finalize_witnessed_checkpoint(verified, certificate) {
    Ready(value) => value
    _ => return InventoryListingRefused(InventoryWitnessFinalizationMismatch)
  }
  if !@inventory.inventory_proof_matches_origin_receipt(
      hasher,
      bundle.proof,
      expected_origin,
    ) {
    return InventoryListingRefused(InventoryOriginMismatch)
  }
  if !@inventory.market_accepts_inventory_listing(
      hasher,
      finalized,
      bundle.proof,
      seller_id=expected_seller_id,
      rejected_ancestor~,
    ) {
    return InventoryListingRefused(InventoryCurrentOwnerProofRefused)
  }
  let checkpoint = finalized.checkpoint()
  let record = bundle.proof.record
  InventoryListingVerified(InventoryListingCentralVerified::{
    session_id: checkpoint.session_id,
    checkpoint_digest: finalized.digest(),
    previous_checkpoint: checkpoint.previous_checkpoint,
    authority_key: expected_authority_key,
    epoch: checkpoint.epoch,
    public_state_root: checkpoint.public_state_root,
    asset_id: record.asset_id,
    current_owner_id: record.owner_id,
    version: record.version,
    last_event: record.last_event,
    approval_count: certificate.approval_count(),
    required_approvals: certificate.required_approvals(),
  })
}
