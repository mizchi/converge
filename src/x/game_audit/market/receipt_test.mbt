///|
fn receipt(
  asset_id? : String = "asset-1",
  recipient_id? : String = "alice",
  item_type? : String = "rare-sword",
  quantity? : Int = 1,
  source_event? : @bft.Digest = @bft.Digest("unauthenticated-source"),
  output_index? : Int = 0,
) -> ItemReceipt {
  { asset_id, recipient_id, item_type, quantity, source_event, output_index }
}

///|
fn batch_or_fail(receipts : Array[ItemReceipt]) -> ReceiptBatch raise Error {
  match build_receipt_batch(@bft.FnvHasher::new(), receipts) {
    Built(batch) => batch
    BatchRejected(_) => fail("expected valid receipt batch")
  }
}

///|
fn proof_or_fail(
  batch : ReceiptBatch,
  asset_id : String,
) -> ItemReceiptProof raise Error {
  match batch.proof_for(asset_id) {
    Some(proof) => proof
    None => fail("expected item receipt proof")
  }
}

///|
fn replayed_receipt(
  asset_id? : String = "authenticated-asset",
  recipient_id? : String = "alice",
  item_type? : String = "rare-sword",
  quantity? : Int = 1,
  output_index? : Int = 0,
  session_id? : String = "dungeon-42",
  counter? : Int = 0,
) -> (ItemReceipt, @replay.ReplayedAssetEffect) raise Error {
  let effect = @replay.AssetEffect::Create(
    asset_id~,
    recipient_id~,
    item_type~,
    quantity~,
    output_index~,
  )
  let adapter = @bft.BFTAdapter::new(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    session_id~,
  )
  let signer = @bft.MockSigner::new("game-server")
  assert_true(
    adapter.register_peer(@types.PeerId("game-server"), signer.public_key()),
  )
  let event = @replay.make_asset_effect_event(
    peer=@types.PeerId("game-server"),
    counter~,
    lamport=counter + 1,
    deps=[],
    effect~,
  )
  let source = match adapter.deliver(adapter.sign(signer, event, [])) {
    Accepted(value) => value
    _ => fail("expected authenticated receipt effect")
  }
  let kernel = @replay.CanonicalAssetKernel::new(
    @bft.FnvHasher::new(),
    effect_author=@bft.PublicKey("game-server"),
  )
  let engine = @replay.ReplayEngine::new(kernel, session_id~)
  let replayed = match engine.replay(source, effect) {
    Replayed(value) => value
    Refused(_) => fail("expected replayed receipt effect")
  }
  (
    ItemReceipt::{
      asset_id,
      recipient_id,
      item_type,
      quantity,
      source_event: source.digest(),
      output_index,
    },
    replayed,
  )
}

///|
fn finalized_for(
  batch : ReceiptBatch,
  manifest_override? : @bft.Digest? = None,
) -> @attestation.FinalizedCheckpoint raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let kernel = @replay.CanonicalAssetKernel::new(
    hasher,
    effect_author=@bft.PublicKey("game-server"),
  )
  let prepared = @checkpoint.prepare_checkpoint(hasher, @checkpoint.Checkpoint::{
    session_id: "dungeon-42",
    epoch: 7,
    previous_checkpoint: @bft.Digest("previous"),
    manifest_digest: manifest_override.unwrap_or(kernel.manifest_digest()),
    event_root: @bft.Digest("events"),
    public_state_root: @bft.Digest("state"),
    asset_delta_root: batch.root(),
    hidden_state_commitment: None,
  })
  let signed = @checkpoint.sign_prepared_checkpoint(authority, prepared)
  let verified = match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      authority.public_key(),
      signed,
    ) {
    Opened(value) => value
    Refused(_) => fail("expected verified checkpoint")
  }
  let collector = @attestation.EvidenceCollector::new(
    hasher,
    verifier,
    prepared,
    [{ id: "checkpoint-auditor", key: @bft.PublicKey("checkpoint-auditor") }],
  )
  let auditor = @bft.MockSigner::new("checkpoint-auditor")
  match
    collector.deliver(
      @attestation.sign_attestation(
        hasher,
        auditor,
        prepared,
        "checkpoint-auditor",
        @attestation.AttestationChoice::Approve,
      ),
    ) {
    Accepted => ()
    _ => fail("expected participant checkpoint attestation")
  }
  match collector.finalize(verified, 1, replay_match=None) {
    Ready(value) => value
    _ => fail("expected participant checkpoint finalization")
  }
}

///|
test "listing requires an exact replayed effect and kernel manifest" {
  let hasher = @bft.FnvHasher::new()
  let (item, replayed) = replayed_receipt()
  let batch = batch_or_fail([item])
  assert_true(
    market_accepts_listing(
      hasher,
      finalized_for(batch),
      proof_or_fail(batch, "authenticated-asset"),
      replayed~,
      seller_id="alice",
      rejected_ancestor=false,
    ),
  )
  let (_, wrong_effect) = replayed_receipt(asset_id="unrelated", counter=1)
  assert_false(
    market_accepts_listing(
      hasher,
      finalized_for(batch),
      proof_or_fail(batch, "authenticated-asset"),
      replayed=wrong_effect,
      seller_id="alice",
      rejected_ancestor=false,
    ),
  )
  let (_, foreign) = replayed_receipt(session_id="other-dungeon")
  assert_false(
    market_accepts_listing(
      hasher,
      finalized_for(batch),
      proof_or_fail(batch, "authenticated-asset"),
      replayed=foreign,
      seller_id="alice",
      rejected_ancestor=false,
    ),
  )
  assert_false(
    market_accepts_listing(
      hasher,
      finalized_for(batch, manifest_override=Some(@bft.Digest("other-kernel"))),
      proof_or_fail(batch, "authenticated-asset"),
      replayed~,
      seller_id="alice",
      rejected_ancestor=false,
    ),
  )
}

///|
test "finalized checkpoint Merkle proof authorizes the recorded owner" {
  let hasher = @bft.FnvHasher::new()
  let (replayed_item, replayed) = replayed_receipt(
    asset_id="asset-2",
    recipient_id="bob",
    item_type="potion",
    counter=1,
  )
  let batch = batch_or_fail([
    receipt(),
    replayed_item,
    receipt(
      asset_id="asset-3",
      recipient_id="carol",
      item_type="mount-token",
      output_index=1,
    ),
  ])
  let finalized = finalized_for(batch)
  let proof = proof_or_fail(batch, "asset-2")
  assert_true(
    market_accepts_listing(
      hasher,
      finalized,
      proof,
      replayed~,
      seller_id="bob",
      rejected_ancestor=false,
    ),
  )
}

///|
test "wrong owner, rejected ancestry, and receipt tampering are denied" {
  let hasher = @bft.FnvHasher::new()
  let (item, replayed) = replayed_receipt(asset_id="asset-1")
  let batch = batch_or_fail([item])
  let finalized = finalized_for(batch)
  let proof = proof_or_fail(batch, "asset-1")
  assert_false(
    market_accepts_listing(
      hasher,
      finalized,
      proof,
      replayed~,
      seller_id="mallory",
      rejected_ancestor=false,
    ),
  )
  assert_false(
    market_accepts_listing(
      hasher,
      finalized,
      proof,
      replayed~,
      seller_id="alice",
      rejected_ancestor=true,
    ),
  )
  let tampered : ItemReceiptProof = {
    receipt: { ..proof.receipt, quantity: 99 },
    merkle_proof: proof.merkle_proof,
  }
  assert_false(
    market_accepts_listing(
      hasher,
      finalized,
      tampered,
      replayed~,
      seller_id="alice",
      rejected_ancestor=false,
    ),
  )
}

///|
test "proof from another finalized checkpoint is denied" {
  let hasher = @bft.FnvHasher::new()
  let (item, replayed) = replayed_receipt(asset_id="asset-1")
  let original = batch_or_fail([item])
  let other = batch_or_fail([receipt(asset_id="other-asset")])
  assert_false(
    market_accepts_listing(
      hasher,
      finalized_for(other),
      proof_or_fail(original, "asset-1"),
      replayed~,
      seller_id="alice",
      rejected_ancestor=false,
    ),
  )
}

///|
test "invalid receipts are rejected before building a root" {
  let hasher = @bft.FnvHasher::new()
  let invalid = [
    receipt(asset_id=""),
    receipt(recipient_id=""),
    receipt(item_type=""),
    receipt(quantity=0),
    receipt(output_index=-1),
  ]
  for item in invalid {
    match build_receipt_batch(hasher, [item]) {
      Built(_) => fail("invalid receipt unexpectedly entered a batch")
      BatchRejected(InvalidReceipt(_, _)) => ()
      BatchRejected(_) => fail("unexpected receipt validation error")
    }
  }
}

///|
test "duplicate asset ids and source output coordinates are rejected" {
  let hasher = @bft.FnvHasher::new()
  match
    build_receipt_batch(hasher, [
      receipt(),
      receipt(asset_id="asset-1", output_index=1),
    ]) {
    BatchRejected(DuplicateAssetId("asset-1")) => ()
    _ => fail("duplicate asset id unexpectedly accepted")
  }
  match build_receipt_batch(hasher, [receipt(), receipt(asset_id="asset-2")]) {
    BatchRejected(DuplicateSourceOutput(1)) => ()
    _ => fail("duplicate source output unexpectedly accepted")
  }
}

///|
test "receipt serialization separates field boundaries" {
  let left = receipt(asset_id="a:b", recipient_id="c")
  let right = receipt(asset_id="a", recipient_id="b:c")
  assert_not_eq(serialize_item_receipt(left), serialize_item_receipt(right))
}

///|
test "unknown asset id has no proof" {
  let batch = batch_or_fail([receipt()])
  assert_eq(batch.proof_for("missing-asset"), None)
}
