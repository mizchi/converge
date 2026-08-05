///|
fn benchmark_receipts(size : Int) -> Array[ItemReceipt] {
  let receipts : Array[ItemReceipt] = []
  for index in 0..<size {
    receipts.push({
      asset_id: "asset-" + index.to_string(),
      recipient_id: "player-" + (index % 8).to_string(),
      item_type: "loot",
      quantity: 1,
      source_event: @bft.Digest("event-" + index.to_string()),
      output_index: 0,
    })
  }
  receipts
}

///|
fn benchmark_replayed_effect() -> (
  @bft.AuthenticatedEvent,
  @replay.ReplayedAssetEffect,
) {
  let adapter = @bft.BFTAdapter::new(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    session_id="benchmark",
  )
  let signer = @bft.MockSigner::new("game-server")
  ignore(
    adapter.register_peer(@types.PeerId("game-server"), signer.public_key()),
  )
  let effect = @replay.AssetEffect::Create(
    asset_id="asset-777",
    recipient_id="player-1",
    item_type="loot",
    quantity=1,
    output_index=0,
  )
  let event = @replay.make_asset_effect_event(
    peer=@types.PeerId("game-server"),
    counter=777,
    lamport=778,
    deps=[],
    effect~,
  )
  let source = match adapter.deliver(adapter.sign(signer, event, [])) {
    Accepted(source) => source
    _ => abort("benchmark source authentication failed")
  }
  let kernel = @replay.CanonicalAssetKernel::new(
    @bft.FnvHasher::new(),
    effect_author=@bft.PublicKey("game-server"),
  )
  let engine = @replay.ReplayEngine::new(kernel, session_id="benchmark")
  match engine.replay(source, effect) {
    Replayed(capability) => (source, capability)
    Refused(_) => abort("benchmark effect replay failed")
  }
}

///|
fn benchmark_finalized(
  batch : ReceiptBatch,
  manifest_digest : @bft.Digest,
) -> @attestation.FinalizedCheckpoint {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let prepared = @checkpoint.prepare_checkpoint(hasher, @checkpoint.Checkpoint::{
    session_id: "benchmark",
    epoch: 1,
    previous_checkpoint: @bft.Digest("previous"),
    manifest_digest,
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
    Refused(_) => abort("benchmark checkpoint verification failed")
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
    _ => abort("benchmark participant attestation failed")
  }
  match collector.finalize(verified, 1, replay_match=None) {
    Ready(value) => value
    _ => abort("benchmark checkpoint finalization failed")
  }
}

///|
test "bench: validate and build 1000 item receipts" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let receipts = benchmark_receipts(1000)
  b.bench(fn() { b.keep(build_receipt_batch(hasher, receipts)) })
}

///|
test "bench: verify 1000 marketplace listings in 1024 receipts" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let (source, replayed) = benchmark_replayed_effect()
  let receipts = benchmark_receipts(1024)
  receipts[777] = { ..receipts[777], source_event: source.digest() }
  let batch = match build_receipt_batch(hasher, receipts) {
    Built(batch) => batch
    BatchRejected(_) => abort("benchmark receipt batch rejected")
  }
  let finalized = benchmark_finalized(batch, replayed.manifest_digest())
  let proof = match batch.proof_for("asset-777") {
    Some(value) => value
    None => abort("benchmark receipt proof missing")
  }
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        market_accepts_listing(
          hasher,
          finalized,
          proof,
          replayed~,
          seller_id="player-1",
          rejected_ancestor=false,
        ),
      )
    }
  })
}
