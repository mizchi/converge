///|
fn item(
  asset_id? : String = "asset-1",
  recipient_id? : String = "alice",
  item_type? : String = "rare-sword",
  quantity? : Int = 1,
  source_event? : @bft.Digest = @bft.Digest("unauthenticated-source"),
  output_index? : Int = 0,
) -> @market.ItemReceipt {
  { asset_id, recipient_id, item_type, quantity, source_event, output_index }
}

///|
fn batch(
  items : Array[@market.ItemReceipt],
) -> @market.ReceiptBatch raise Error {
  match @market.build_receipt_batch(@bft.FnvHasher::new(), items) {
    Built(batch) => batch
    BatchRejected(_) => fail("expected valid item receipt batch")
  }
}

///|
fn replayed_effect(
  effect : @replay.AssetEffect,
  session_id? : String = "dungeon-42",
  counter? : Int = 0,
  effect_author? : String = "game-server",
) -> (@bft.AuthenticatedEvent, @replay.ReplayedAssetEffect) raise Error {
  let adapter = @bft.BFTAdapter::new(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    session_id~,
  )
  let signer = @bft.MockSigner::new(effect_author)
  assert_true(
    adapter.register_peer(@types.PeerId(effect_author), signer.public_key()),
  )
  let event = @replay.make_asset_effect_event(
    peer=@types.PeerId(effect_author),
    counter~,
    lamport=counter + 1,
    deps=[],
    effect~,
  )
  let source = match adapter.deliver(adapter.sign(signer, event, [])) {
    Accepted(source) => source
    _ => fail("expected authenticated effect event")
  }
  let kernel = @replay.CanonicalAssetKernel::new(
    @bft.FnvHasher::new(),
    effect_author=@bft.PublicKey(effect_author),
  )
  let engine = @replay.ReplayEngine::new(kernel, session_id~)
  match engine.replay(source, effect) {
    Replayed(capability) => (source, capability)
    Refused(_) => fail("expected replayed asset effect")
  }
}

///|
fn replayed_item(
  asset_id? : String = "asset-1",
  recipient_id? : String = "alice",
  item_type? : String = "rare-sword",
  quantity? : Int = 1,
  output_index? : Int = 0,
  session_id? : String = "dungeon-42",
  counter? : Int = 0,
  effect_author? : String = "game-server",
) -> (@market.ItemReceipt, @replay.ReplayedAssetEffect) raise Error {
  let effect = @replay.AssetEffect::Create(
    asset_id~,
    recipient_id~,
    item_type~,
    quantity~,
    output_index~,
  )
  let (source, capability) = replayed_effect(
    effect,
    session_id~,
    counter~,
    effect_author~,
  )
  (
    item(
      asset_id~,
      recipient_id~,
      item_type~,
      quantity~,
      source_event=source.digest(),
      output_index~,
    ),
    capability,
  )
}

///|
fn replayed_transfer(
  asset_id? : String = "asset-1",
  from_owner? : String = "alice",
  to_owner? : String = "bob",
  expected_version? : Int = 0,
  session_id? : String = "dungeon-42",
  counter? : Int = 1,
  effect_author? : String = "game-server",
) -> (AssetTransfer, @replay.ReplayedAssetEffect) raise Error {
  let effect = @replay.AssetEffect::Transfer(
    asset_id~,
    from_owner~,
    to_owner~,
    expected_version~,
  )
  let (source, capability) = replayed_effect(
    effect,
    session_id~,
    counter~,
    effect_author~,
  )
  (
    AssetTransfer::{
      asset_id,
      from_owner,
      to_owner,
      expected_version,
      source_event: source.digest(),
    },
    capability,
  )
}

///|
fn plan_or_fail(
  inventory : InventoryIndex,
  creations : @market.ReceiptBatch,
  transfers : Array[AssetTransfer],
  effects : Array[@replay.ReplayedAssetEffect],
) -> InventoryPlan raise Error {
  match inventory.plan(creations, transfers, effects~) {
    Planned(plan) => plan
    PlanRejected(_) => fail("expected valid inventory plan")
  }
}

///|
fn finalized_plan(
  inventory : InventoryIndex,
  plan : InventoryPlan,
  epoch : Int,
  previous_override? : @bft.Digest? = None,
  state_override? : @bft.Digest? = None,
  delta_override? : @bft.Digest? = None,
  session_override? : String? = None,
  manifest_override? : @bft.Digest? = None,
) -> @attestation.FinalizedCheckpoint raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let prepared = @checkpoint.prepare_checkpoint(hasher, @checkpoint.Checkpoint::{
    session_id: session_override.unwrap_or(inventory.session_id()),
    epoch,
    previous_checkpoint: previous_override.unwrap_or(
      inventory.last_checkpoint(),
    ),
    manifest_digest: manifest_override.unwrap_or(
      plan.replay_manifest_digest().unwrap_or(@bft.Digest("manifest")),
    ),
    event_root: @bft.Digest("events-" + epoch.to_string()),
    public_state_root: state_override.unwrap_or(plan.state_root()),
    asset_delta_root: delta_override.unwrap_or(plan.asset_delta_root()),
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
    Refused(_) => fail("expected verified inventory checkpoint")
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
    _ => fail("expected participant inventory attestation")
  }
  match collector.finalize(verified, 1, replay_match=None) {
    Ready(value) => value
    _ => fail("expected participant-finalized inventory checkpoint")
  }
}

///|
fn new_inventory() -> InventoryIndex {
  InventoryIndex::new(
    @bft.FnvHasher::new(),
    session_id="dungeon-42",
    genesis_checkpoint=@bft.Digest("genesis"),
  )
}

///|
test "creation without a replayed effect capability is rejected" {
  let inventory = new_inventory()
  match inventory.plan(batch([item()]), [], effects=[]) {
    PlanRejected(UnreplayedCreation(0)) => ()
    _ => fail("unreplayed creation unexpectedly entered inventory")
  }
}

///|
test "creation with a different replayed effect is rejected" {
  let inventory = new_inventory()
  let (expected, _) = replayed_item()
  let (_, different) = replayed_item(asset_id="different", counter=1)
  match inventory.plan(batch([expected]), [], effects=[different]) {
    PlanRejected(UnreplayedCreation(0)) => ()
    _ => fail("wrong replayed effect unexpectedly entered inventory")
  }
}

///|
test "creation capability from another session is rejected" {
  let inventory = new_inventory()
  let (foreign_item, foreign) = replayed_item(session_id="other-dungeon")
  match inventory.plan(batch([foreign_item]), [], effects=[foreign]) {
    PlanRejected(UnreplayedCreation(0)) => ()
    _ => fail("cross-session creation unexpectedly entered inventory")
  }
}

///|
test "one inventory plan cannot mix replay kernel manifests" {
  let inventory = new_inventory()
  let (first, first_effect) = replayed_item(asset_id="asset-a")
  let (second, second_effect) = replayed_item(
    asset_id="asset-b",
    counter=1,
    effect_author="other-server",
  )
  match
    inventory.plan(batch([first, second]), [], effects=[
      first_effect, second_effect,
    ]) {
    PlanRejected(ReplayManifestConflict) => ()
    _ => fail("mixed replay manifests unexpectedly entered one plan")
  }
}

///|
test "committed creation is indexed and cannot be created again" {
  let inventory = new_inventory()
  let (receipt, replayed) = replayed_item()
  let creations = batch([receipt])
  let plan = plan_or_fail(inventory, creations, [], [replayed])
  assert_eq(plan.replay_manifest_digest(), Some(replayed.manifest_digest()))
  let finalized = finalized_plan(inventory, plan, 1)
  assert_eq(inventory.commit(finalized, plan), InventoryCommitResult::Committed)
  let record = inventory.get("asset-1").unwrap()
  assert_eq(record.owner_id, "alice")
  assert_eq(record.version, 0)
  assert_eq(inventory.last_checkpoint(), finalized.digest())
  assert_eq(
    inventory.commit(finalized, plan),
    InventoryCommitResult::AlreadyCommitted,
  )
  match inventory.plan(batch([receipt]), [], effects=[replayed]) {
    PlanRejected(DuplicateAsset("asset-1")) => ()
    _ => fail("cross-checkpoint duplicate creation unexpectedly accepted")
  }
}

///|
test "authorized transfer updates owner version and authenticated proof" {
  let hasher = @bft.FnvHasher::new()
  let inventory = new_inventory()
  let (receipt, creation_effect) = replayed_item()
  let create_plan = plan_or_fail(inventory, batch([receipt]), [], [
    creation_effect,
  ])
  ignore(
    inventory.commit(finalized_plan(inventory, create_plan, 1), create_plan),
  )
  let (transfer, transfer_effect) = replayed_transfer()
  let transfer_plan = plan_or_fail(inventory, batch([]), [transfer], [
    transfer_effect,
  ])
  let finalized = finalized_plan(inventory, transfer_plan, 2)
  assert_eq(
    inventory.commit(finalized, transfer_plan),
    InventoryCommitResult::Committed,
  )
  let record = inventory.get("asset-1").unwrap()
  assert_eq(record.owner_id, "bob")
  assert_eq(record.version, 1)
  assert_eq(record.origin_source_event, receipt.source_event)
  assert_eq(record.origin_output_index, 0)
  assert_eq(record.last_event, transfer.source_event)
  let proof = inventory.proof("asset-1").unwrap()
  assert_true(verify_inventory_proof(hasher, inventory.root(), proof))
  assert_true(inventory_proof_matches_origin_receipt(hasher, proof, receipt))
  assert_false(
    inventory_proof_matches_origin_receipt(hasher, proof, {
      ..receipt,
      recipient_id: "mallory",
    }),
  )
  assert_true(
    market_accepts_inventory_listing(
      hasher,
      finalized,
      proof,
      seller_id="bob",
      rejected_ancestor=false,
    ),
  )
  assert_false(
    market_accepts_inventory_listing(
      hasher,
      finalized,
      proof,
      seller_id="alice",
      rejected_ancestor=false,
    ),
  )
}

///|
test "unknown asset wrong owner and stale version transfers are rejected" {
  let inventory = new_inventory()
  let (receipt, creation_effect) = replayed_item()
  let create_plan = plan_or_fail(inventory, batch([receipt]), [], [
    creation_effect,
  ])
  ignore(
    inventory.commit(finalized_plan(inventory, create_plan, 1), create_plan),
  )
  let (unknown, unknown_effect) = replayed_transfer(asset_id="missing")
  match inventory.plan(batch([]), [unknown], effects=[unknown_effect]) {
    PlanRejected(InvalidTransfer(0, UnknownAsset)) => ()
    _ => fail("unknown asset transfer unexpectedly accepted")
  }
  let (wrong_owner, wrong_owner_effect) = replayed_transfer(
    from_owner="mallory",
    counter=2,
  )
  match inventory.plan(batch([]), [wrong_owner], effects=[wrong_owner_effect]) {
    PlanRejected(InvalidTransfer(0, OwnerMismatch)) => ()
    _ => fail("wrong owner transfer unexpectedly accepted")
  }
  let (stale, stale_effect) = replayed_transfer(expected_version=9, counter=3)
  match inventory.plan(batch([]), [stale], effects=[stale_effect]) {
    PlanRejected(InvalidTransfer(0, VersionMismatch)) => ()
    _ => fail("stale version transfer unexpectedly accepted")
  }
}

///|
test "invalid recipient same owner and unreplayed source are rejected" {
  let inventory = new_inventory()
  let (receipt, creation_effect) = replayed_item()
  let create_plan = plan_or_fail(inventory, batch([receipt]), [], [
    creation_effect,
  ])
  ignore(
    inventory.commit(finalized_plan(inventory, create_plan, 1), create_plan),
  )
  let (valid, _) = replayed_transfer()
  match inventory.plan(batch([]), [{ ..valid, to_owner: "" }], effects=[]) {
    PlanRejected(InvalidTransfer(0, InvalidRecipient)) => ()
    _ => fail("empty recipient unexpectedly accepted")
  }
  match
    inventory.plan(batch([]), [{ ..valid, to_owner: "alice" }], effects=[]) {
    PlanRejected(InvalidTransfer(0, SameOwner)) => ()
    _ => fail("same-owner transfer unexpectedly accepted")
  }
  match inventory.plan(batch([]), [valid], effects=[]) {
    PlanRejected(InvalidTransfer(0, UnreplayedSourceEvent)) => ()
    _ => fail("unreplayed source event unexpectedly accepted")
  }
}

///|
test "failed plan is transactional" {
  let inventory = new_inventory()
  let before = inventory.root()
  let (receipt, creation_effect) = replayed_item(asset_id="new-asset")
  let (invalid, transfer_effect) = replayed_transfer(
    asset_id="new-asset",
    from_owner="mallory",
  )
  match
    inventory.plan(batch([receipt]), [invalid], effects=[
      creation_effect, transfer_effect,
    ]) {
    PlanRejected(InvalidTransfer(0, OwnerMismatch)) => ()
    _ => fail("invalid mixed plan unexpectedly accepted")
  }
  assert_eq(inventory.root(), before)
  assert_eq(inventory.get("new-asset"), None)
}

///|
test "checkpoint root mismatch and stale competing plan do not commit" {
  let inventory = new_inventory()
  let (receipt_a, effect_a) = replayed_item(asset_id="asset-a")
  let (receipt_b, effect_b) = replayed_item(asset_id="asset-b", counter=1)
  let first = plan_or_fail(inventory, batch([receipt_a]), [], [effect_a])
  let competing = plan_or_fail(inventory, batch([receipt_b]), [], [effect_b])
  let wrong_root = finalized_plan(
    inventory,
    first,
    1,
    state_override=Some(@bft.Digest("wrong-state")),
  )
  assert_eq(
    inventory.commit(wrong_root, first),
    InventoryCommitResult::PublicStateRootMismatch,
  )
  assert_eq(inventory.size(), 0)
  let accepted = finalized_plan(inventory, first, 1)
  assert_eq(inventory.commit(accepted, first), InventoryCommitResult::Committed)
  let stale = finalized_plan(new_inventory(), competing, 1)
  assert_eq(
    inventory.commit(stale, competing),
    InventoryCommitResult::StalePlan,
  )
  assert_eq(inventory.get("asset-b"), None)
}

///|
test "all checkpoint bindings fail closed without mutating inventory" {
  let inventory = new_inventory()
  let (receipt, effect) = replayed_item()
  let plan = plan_or_fail(inventory, batch([receipt]), [], [effect])
  let original_root = inventory.root()
  let wrong_session = finalized_plan(
    inventory,
    plan,
    1,
    session_override=Some("other-session"),
  )
  assert_eq(
    inventory.commit(wrong_session, plan),
    InventoryCommitResult::SessionMismatch,
  )
  let wrong_previous = finalized_plan(
    inventory,
    plan,
    1,
    previous_override=Some(@bft.Digest("other-parent")),
  )
  assert_eq(
    inventory.commit(wrong_previous, plan),
    InventoryCommitResult::PreviousCheckpointMismatch,
  )
  let old_epoch = finalized_plan(inventory, plan, -1)
  assert_eq(
    inventory.commit(old_epoch, plan),
    InventoryCommitResult::EpochRegression,
  )
  let wrong_manifest = finalized_plan(
    inventory,
    plan,
    1,
    manifest_override=Some(@bft.Digest("other-kernel")),
  )
  assert_eq(
    inventory.commit(wrong_manifest, plan),
    InventoryCommitResult::ReplayManifestMismatch,
  )
  let wrong_delta = finalized_plan(
    inventory,
    plan,
    1,
    delta_override=Some(@bft.Digest("wrong-delta")),
  )
  assert_eq(
    inventory.commit(wrong_delta, plan),
    InventoryCommitResult::AssetDeltaRootMismatch,
  )
  let wrong_state = finalized_plan(
    inventory,
    plan,
    1,
    state_override=Some(@bft.Digest("wrong-state")),
  )
  assert_eq(
    inventory.commit(wrong_state, plan),
    InventoryCommitResult::PublicStateRootMismatch,
  )
  assert_eq(inventory.root(), original_root)
  assert_eq(inventory.size(), 0)
}

///|
test "inventory membership proof binds current owner and record" {
  let hasher = @bft.FnvHasher::new()
  let inventory = new_inventory()
  let (receipt, effect) = replayed_item()
  let plan = plan_or_fail(inventory, batch([receipt]), [], [effect])
  ignore(inventory.commit(finalized_plan(inventory, plan, 1), plan))
  let proof = inventory.proof("asset-1").unwrap()
  assert_false(
    verify_inventory_proof(hasher, inventory.root(), {
      ..proof,
      record: { ..proof.record, owner_id: "mallory" },
    }),
  )
  assert_false(verify_inventory_proof(hasher, @bft.Digest("wrong-root"), proof))
}

///|
test "semantic inventory root converges despite creation order" {
  let left = new_inventory()
  let right = new_inventory()
  let (first, effect_a) = replayed_item(asset_id="asset-a")
  let (second, effect_b) = replayed_item(asset_id="asset-b", counter=1)
  let effects = [effect_a, effect_b]
  let left_plan = plan_or_fail(left, batch([first, second]), [], effects)
  let right_plan = plan_or_fail(right, batch([second, first]), [], effects)
  assert_eq(left_plan.state_root(), right_plan.state_root())
}
