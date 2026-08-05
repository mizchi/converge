///|
priv struct InventoryListingCentralFixture {
  session_id : String
  authority_key : @bft.PublicKey
  checkpoint_digest : @bft.Digest
  origin : @market.ItemReceipt
  bundle : @wire.InventoryListingProofBundle
}

///|
fn inventory_listing_central_fixture() -> InventoryListingCentralFixture raise Error {
  let hasher = @bft.FnvHasher::new()
  let authority = @bft.MockSigner::new("inventory-authority")
  let origin = @market.ItemReceipt::{
    asset_id: "asset-1",
    recipient_id: "alice",
    item_type: "raid-token",
    quantity: 1,
    source_event: @bft.Digest("loot-event"),
    output_index: 0,
  }
  let record = @inventory.AssetRecord::{
    asset_id: origin.asset_id,
    owner_id: "bob",
    item_type: origin.item_type,
    quantity: origin.quantity,
    origin_source_event: origin.source_event,
    origin_output_index: origin.output_index,
    origin_receipt_digest: @inventory.inventory_origin_receipt_digest(
      hasher, origin,
    ),
    version: 1,
    last_event: @bft.Digest("transfer-event"),
  }
  let state = @authmap.AuthenticatedMap::new(hasher)
  ignore(state.put(record.asset_id, @inventory.serialize_asset_record(record)))
  let map_proof = match state.proof(record.asset_id) {
    Some(value) => value
    None => fail("expected inventory proof")
  }
  let witness_signers : Array[@bft.MockSigner] = []
  let witnesses : Array[@witness_manifest.ReplayWitnessIdentity] = []
  let participants : Array[@attestation.Participant] = []
  for index in 0..<4 {
    let id = "inventory-witness-" + index.to_string()
    let signer = @bft.MockSigner::new(id)
    witness_signers.push(signer)
    witnesses.push({ id, key: signer.public_key() })
    participants.push({ id, key: signer.public_key() })
  }
  let game_manifest_digest = @bft.Digest("canonical-asset-kernel-v1")
  let session_id = "inventory-session"
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id,
    epoch: 1,
    previous_checkpoint: @bft.Digest("creation-checkpoint"),
    manifest_digest: @attestation.replay_witness_session_manifest(
      hasher,
      game_manifest_digest~,
      referee_key=authority.public_key(),
      witnesses=participants,
      max_faults=1,
    ),
    event_root: @bft.Digest("inventory-events"),
    public_state_root: state.root(),
    asset_delta_root: @bft.Digest("no-new-assets"),
    hidden_state_commitment: None,
  })
  let signed_checkpoint = @checkpoint.sign_prepared_checkpoint(
    authority, prepared,
  )
  let attestations : Array[@attestation.SignedAttestation] = []
  for index in 0..<3 {
    attestations.push(
      @attestation.sign_replay_witness_attestation(
        hasher,
        witness_signers[index],
        prepared,
        witnesses[index].id,
        @attestation.AttestationChoice::Approve,
      ),
    )
  }
  {
    session_id,
    authority_key: authority.public_key(),
    checkpoint_digest: signed_checkpoint.digest,
    origin,
    bundle: {
      signed_checkpoint,
      game_manifest_digest,
      witnesses,
      max_faults: 1,
      attestations,
      proof: { record, map_proof },
    },
  }
}

///|
fn verify_inventory_listing_fixture(
  fixture : InventoryListingCentralFixture,
  bundle : @wire.InventoryListingProofBundle,
  seller_id? : String = "bob",
  origin? : @market.ItemReceipt = fixture.origin,
) -> InventoryListingCentralResult {
  verify_inventory_listing_proof_bundle(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    @wire.encode_inventory_listing_proof_bundle(bundle),
    expected_session_id=fixture.session_id,
    expected_authority_key=fixture.authority_key,
    expected_checkpoint_digest=fixture.checkpoint_digest,
    expected_game_manifest_digest=bundle.game_manifest_digest,
    expected_origin=origin,
    expected_seller_id=seller_id,
    rejected_ancestor=false,
    limits=@wire.InventoryListingWireLimits::default(),
  )
}

///|
test "central inventory proof accepts only the current owner and exact origin" {
  let fixture = inventory_listing_central_fixture()
  match verify_inventory_listing_fixture(fixture, fixture.bundle) {
    InventoryListingVerified(verified) => {
      assert_eq(verified.asset_id(), "asset-1")
      assert_eq(verified.current_owner_id(), "bob")
      assert_eq(verified.version(), 1)
      assert_eq(verified.epoch(), 1)
      assert_eq(
        verified.previous_checkpoint(),
        @bft.Digest("creation-checkpoint"),
      )
      assert_eq(verified.approval_count(), 3)
      assert_eq(verified.required_approvals(), 3)
    }
    _ => fail("expected current-owner listing verification")
  }
  match
    verify_inventory_listing_fixture(fixture, fixture.bundle, seller_id="alice") {
    InventoryListingRefused(InventoryCurrentOwnerProofRefused) => ()
    _ => fail("stale initial owner was accepted")
  }
  match
    verify_inventory_listing_fixture(fixture, fixture.bundle, origin={
      ..fixture.origin,
      recipient_id: "mallory",
    }) {
    InventoryListingRefused(InventoryOriginMismatch) => ()
    _ => fail("foreign origin receipt was accepted")
  }
}

///|
test "central inventory proof fails closed on stale boundary quorum and tampering" {
  let fixture = inventory_listing_central_fixture()
  assert_eq(
    verify_inventory_listing_proof_bundle(
      @bft.FnvHasher::new(),
      @bft.MockVerifier::new(),
      @wire.encode_inventory_listing_proof_bundle(fixture.bundle),
      expected_session_id=fixture.session_id,
      expected_authority_key=fixture.authority_key,
      expected_checkpoint_digest=@bft.Digest("stale-checkpoint"),
      expected_game_manifest_digest=fixture.bundle.game_manifest_digest,
      expected_origin=fixture.origin,
      expected_seller_id="bob",
      rejected_ancestor=false,
      limits=@wire.InventoryListingWireLimits::default(),
    ),
    InventoryListingCentralResult::InventoryListingRefused(
      InventoryListingCentralRefusal::InventoryExpectedCheckpointMismatch,
    ),
  )
  let attestations = fixture.bundle.attestations
  let under_quorum = @wire.InventoryListingProofBundle::{
    ..fixture.bundle,
    attestations: [attestations[0], attestations[1]],
  }
  assert_eq(
    verify_inventory_listing_fixture(fixture, under_quorum),
    InventoryListingCentralResult::InventoryListingRefused(
      InventoryListingCentralRefusal::InventoryWitnessQuorumPending(2, 3),
    ),
  )
  let proof = fixture.bundle.proof
  let tampered = @wire.InventoryListingProofBundle::{
    ..fixture.bundle,
    proof: { ..proof, record: { ..proof.record, version: 2 } },
  }
  match verify_inventory_listing_fixture(fixture, tampered) {
    InventoryListingRefused(InventoryCurrentOwnerProofRefused) => ()
    _ => fail("tampered inventory version was accepted")
  }
}
