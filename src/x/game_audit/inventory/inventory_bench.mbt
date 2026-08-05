///|
fn benchmark_replayed_effects(
  effects : Array[@replay.AssetEffect],
  counter_offset : Int,
) -> (Array[@bft.AuthenticatedEvent], Array[@replay.ReplayedAssetEffect]) {
  let adapter = @bft.BFTAdapter::new(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    session_id="benchmark",
  )
  let signer = @bft.MockSigner::new("game-server")
  ignore(
    adapter.register_peer(@types.PeerId("game-server"), signer.public_key()),
  )
  let sources : Array[@bft.AuthenticatedEvent] = []
  let replayed : Array[@replay.ReplayedAssetEffect] = []
  let kernel = @replay.CanonicalAssetKernel::new(
    @bft.FnvHasher::new(),
    effect_author=@bft.PublicKey("game-server"),
  )
  let engine = @replay.ReplayEngine::new(kernel, session_id="benchmark")
  for index, effect in effects {
    let counter = counter_offset + index
    let event = @replay.make_asset_effect_event(
      peer=@types.PeerId("game-server"),
      counter~,
      lamport=counter + 1,
      deps=[],
      effect~,
    )
    let source = match adapter.deliver(adapter.sign(signer, event, [])) {
      Accepted(source) => source
      _ => abort("benchmark source authentication failed")
    }
    match engine.replay(source, effect) {
      Replayed(capability) => {
        sources.push(source)
        replayed.push(capability)
      }
      Refused(_) => abort("benchmark effect replay failed")
    }
  }
  (sources, replayed)
}

///|
fn benchmark_creations(
  size : Int,
) -> (@market.ReceiptBatch, Array[@replay.ReplayedAssetEffect]) {
  let effects : Array[@replay.AssetEffect] = []
  for index in 0..<size {
    effects.push(
      @replay.AssetEffect::Create(
        asset_id="asset-" + index.to_string(),
        recipient_id="owner-" + (index % 64).to_string(),
        item_type="loot",
        quantity=1,
        output_index=0,
      ),
    )
  }
  let (sources, replayed) = benchmark_replayed_effects(effects, 0)
  let receipts : Array[@market.ItemReceipt] = []
  for index, source in sources {
    receipts.push({
      asset_id: "asset-" + index.to_string(),
      recipient_id: "owner-" + (index % 64).to_string(),
      item_type: "loot",
      quantity: 1,
      source_event: source.digest(),
      output_index: 0,
    })
  }
  match @market.build_receipt_batch(@bft.FnvHasher::new(), receipts) {
    Built(batch) => (batch, replayed)
    BatchRejected(_) => abort("benchmark receipt batch rejected")
  }
}

///|
fn benchmark_transfers(
  asset_indices : Array[Int],
  counter_offset : Int,
) -> (Array[AssetTransfer], Array[@replay.ReplayedAssetEffect]) {
  let effects : Array[@replay.AssetEffect] = []
  for asset_index in asset_indices {
    effects.push(
      @replay.AssetEffect::Transfer(
        asset_id="asset-" + asset_index.to_string(),
        from_owner="owner-" + (asset_index % 64).to_string(),
        to_owner="new-owner",
        expected_version=0,
      ),
    )
  }
  let (sources, replayed) = benchmark_replayed_effects(effects, counter_offset)
  let transfers : Array[AssetTransfer] = []
  for index, asset_index in asset_indices {
    transfers.push({
      asset_id: "asset-" + asset_index.to_string(),
      from_owner: "owner-" + (asset_index % 64).to_string(),
      to_owner: "new-owner",
      expected_version: 0,
      source_event: sources[index].digest(),
    })
  }
  (transfers, replayed)
}

///|
fn benchmark_inventory() -> InventoryIndex {
  InventoryIndex::new(
    @bft.FnvHasher::new(),
    session_id="benchmark",
    genesis_checkpoint=@bft.Digest("genesis"),
  )
}

///|
fn benchmark_finalize(
  inventory : InventoryIndex,
  plan : InventoryPlan,
  epoch : Int,
) -> @attestation.FinalizedCheckpoint {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let prepared = @checkpoint.prepare_checkpoint(hasher, @checkpoint.Checkpoint::{
    session_id: inventory.session_id(),
    epoch,
    previous_checkpoint: inventory.last_checkpoint(),
    manifest_digest: plan
    .replay_manifest_digest()
    .unwrap_or(@bft.Digest("manifest")),
    event_root: @bft.Digest("events"),
    public_state_root: plan.state_root(),
    asset_delta_root: plan.asset_delta_root(),
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
fn benchmark_populated_inventory(size : Int) -> InventoryIndex {
  let inventory = benchmark_inventory()
  let (creations, effects) = benchmark_creations(size)
  let plan = match inventory.plan(creations, [], effects~) {
    Planned(plan) => plan
    PlanRejected(_) => abort("benchmark inventory plan rejected")
  }
  let finalized = benchmark_finalize(inventory, plan, 1)
  match inventory.commit(finalized, plan) {
    Committed => inventory
    _ => abort("benchmark inventory commit rejected")
  }
}

///|
test "bench: plan 1000 asset creations" (b : @bench.T) {
  let inventory = benchmark_inventory()
  let (creations, effects) = benchmark_creations(1000)
  b.bench(fn() { b.keep(inventory.plan(creations, [], effects~)) })
}

///|
test "bench: plan 1000 transfers in 10000 assets" (b : @bench.T) {
  let inventory = benchmark_populated_inventory(10000)
  let empty = benchmark_creations(0).0
  let asset_indices : Array[Int] = []
  for index in 0..<1000 {
    asset_indices.push(index)
  }
  let (transfers, effects) = benchmark_transfers(asset_indices, 10000)
  b.bench(fn() { b.keep(inventory.plan(empty, transfers, effects~)) })
}

///|
fn benchmark_single_transfer_plan(
  b : @bench.T,
  inventory_size : Int,
  asset_index : Int,
) -> Unit {
  let inventory = benchmark_populated_inventory(inventory_size)
  let empty = benchmark_creations(0).0
  let (transfers, effects) = benchmark_transfers([asset_index], inventory_size)
  b.bench(fn() { b.keep(inventory.plan(empty, transfers, effects~)) })
}

///|
test "bench: plan 1 transfer in 1000 assets" (b : @bench.T) {
  benchmark_single_transfer_plan(b, 1000, 777)
}

///|
test "bench: plan 1 transfer in 10000 assets" (b : @bench.T) {
  benchmark_single_transfer_plan(b, 10000, 7777)
}

///|
test "bench: verify 1000 inventory proofs in 10000 assets" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let inventory = benchmark_populated_inventory(10000)
  let proof = match inventory.proof("asset-7777") {
    Some(value) => value
    None => abort("benchmark inventory proof missing")
  }
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(verify_inventory_proof(hasher, inventory.root(), proof))
    }
  })
}
