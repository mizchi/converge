///|
/// Current authenticated state for one durable asset.
pub(all) struct AssetRecord {
  asset_id : String
  owner_id : String
  item_type : String
  quantity : Int
  origin_source_event : @bft.Digest
  origin_output_index : Int
  origin_receipt_digest : @bft.Digest
  version : Int
  last_event : @bft.Digest
} derive(Eq, Debug)

///|
/// Ownership transition referencing a game or marketplace event. Planning
/// separately requires a matching replayed-effect capability.
pub(all) struct AssetTransfer {
  asset_id : String
  from_owner : String
  to_owner : String
  expected_version : Int
  source_event : @bft.Digest
} derive(Eq, Debug)

///|
pub(all) enum TransferValidation {
  UnknownAsset
  OwnerMismatch
  VersionMismatch
  InvalidRecipient
  SameOwner
  UnreplayedSourceEvent
} derive(Eq, Debug)

///|
pub(all) enum InventoryPlanError {
  DuplicateAsset(String)
  UnreplayedCreation(Int)
  ReplayManifestConflict
  InvalidTransfer(Int, TransferValidation)
} derive(Eq, Debug)

///|
pub(all) enum InventoryPlanResult {
  Planned(InventoryPlan)
  PlanRejected(InventoryPlanError)
}

///|
pub(all) enum InventoryCommitResult {
  Committed
  AlreadyCommitted
  StalePlan
  SessionMismatch
  PreviousCheckpointMismatch
  EpochRegression
  ReplayManifestMismatch
  AssetDeltaRootMismatch
  PublicStateRootMismatch
} derive(Eq, Debug)

///|
pub(all) struct InventoryProof {
  record : AssetRecord
  map_proof : @authmap.AuthMapProof
} derive(Eq, Debug)

///|
/// Local-first authenticated inventory state.
pub struct InventoryIndex {
  hasher : &@bft.Hasher
  session : String
  records : Map[String, AssetRecord]
  mut state_map : @authmap.AuthenticatedMap
  mut checkpoint_digest : @bft.Digest
  mut checkpoint_epoch : Int
}

///|
/// Transaction candidate computed before the authority checkpoint is signed.
pub struct InventoryPlan {
  base_root : @bft.Digest
  base_checkpoint : @bft.Digest
  base_epoch : Int
  record_updates : Map[String, AssetRecord]
  next_state_map : @authmap.AuthenticatedMap
  resulting_root : @bft.Digest
  delta_root : @bft.Digest
  replay_manifest : @bft.Digest?
}

///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
pub fn serialize_asset_record(record : AssetRecord) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "asset-record-v1")
  append_field(buffer, record.asset_id)
  append_field(buffer, record.owner_id)
  append_field(buffer, record.item_type)
  append_field(buffer, record.quantity.to_string())
  append_field(buffer, record.origin_source_event.0)
  append_field(buffer, record.origin_output_index.to_string())
  append_field(buffer, record.origin_receipt_digest.0)
  append_field(buffer, record.version.to_string())
  append_field(buffer, record.last_event.0)
  buffer.to_string()
}

///|
pub fn inventory_origin_receipt_digest(
  hasher : &@bft.Hasher,
  receipt : @market.ItemReceipt,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "inventory-origin-receipt-v1")
  append_field(buffer, @market.serialize_item_receipt(receipt))
  hasher.hash_string(buffer.to_string())
}

///|
pub fn InventoryIndex::new(
  hasher : &@bft.Hasher,
  session_id~ : String,
  genesis_checkpoint~ : @bft.Digest,
) -> InventoryIndex {
  InventoryIndex::{
    hasher,
    session: session_id,
    records: Map([]),
    state_map: @authmap.AuthenticatedMap::new(hasher),
    checkpoint_digest: genesis_checkpoint,
    checkpoint_epoch: -1,
  }
}

///|
pub fn InventoryIndex::session_id(self : InventoryIndex) -> String {
  self.session
}

///|
pub fn InventoryIndex::root(self : InventoryIndex) -> @bft.Digest {
  self.state_map.root()
}

///|
pub fn InventoryIndex::size(self : InventoryIndex) -> Int {
  self.state_map.size()
}

///|
pub fn InventoryIndex::last_checkpoint(self : InventoryIndex) -> @bft.Digest {
  self.checkpoint_digest
}

///|
pub fn InventoryIndex::last_epoch(self : InventoryIndex) -> Int {
  self.checkpoint_epoch
}

///|
pub fn InventoryIndex::get(
  self : InventoryIndex,
  asset_id : String,
) -> AssetRecord? {
  self.records.get(asset_id)
}

///|
pub fn InventoryPlan::state_root(self : InventoryPlan) -> @bft.Digest {
  self.resulting_root
}

///|
pub fn InventoryPlan::asset_delta_root(self : InventoryPlan) -> @bft.Digest {
  self.delta_root
}

///|
pub fn InventoryPlan::replay_manifest_digest(
  self : InventoryPlan,
) -> @bft.Digest? {
  self.replay_manifest
}

///|
fn create_record(
  hasher : &@bft.Hasher,
  receipt : @market.ItemReceipt,
) -> AssetRecord {
  AssetRecord::{
    asset_id: receipt.asset_id,
    owner_id: receipt.recipient_id,
    item_type: receipt.item_type,
    quantity: receipt.quantity,
    origin_source_event: receipt.source_event,
    origin_output_index: receipt.output_index,
    origin_receipt_digest: inventory_origin_receipt_digest(hasher, receipt),
    version: 0,
    last_event: receipt.source_event,
  }
}

///|
fn validate_transfer(
  record : AssetRecord?,
  transfer : AssetTransfer,
  source_replayed : Bool,
) -> TransferValidation? {
  let current = match record {
    None => return Some(UnknownAsset)
    Some(value) => value
  }
  let owner_matches = current.owner_id == transfer.from_owner
  let version_matches = current.version == transfer.expected_version
  let recipient_valid = transfer.to_owner != ""
  let changes_owner = transfer.from_owner != transfer.to_owner
  if @audit.transfer_transition_allowed(
      asset_exists=true,
      owner_matches~,
      version_matches~,
      recipient_valid~,
      changes_owner~,
      source_authenticated=source_replayed,
    ) {
    return None
  }
  if transfer.to_owner == "" {
    return Some(InvalidRecipient)
  }
  if transfer.from_owner == transfer.to_owner {
    return Some(SameOwner)
  }
  if !source_replayed {
    return Some(UnreplayedSourceEvent)
  }
  if current.owner_id != transfer.from_owner {
    return Some(OwnerMismatch)
  }
  if current.version != transfer.expected_version {
    return Some(VersionMismatch)
  }
  // All concrete rejection reasons above mirror the proof-checked predicate.
  Some(OwnerMismatch)
}

///|
fn creation_effect(receipt : @market.ItemReceipt) -> @replay.AssetEffect {
  @replay.AssetEffect::Create(
    asset_id=receipt.asset_id,
    recipient_id=receipt.recipient_id,
    item_type=receipt.item_type,
    quantity=receipt.quantity,
    output_index=receipt.output_index,
  )
}

///|
fn transfer_effect(transfer : AssetTransfer) -> @replay.AssetEffect {
  @replay.AssetEffect::Transfer(
    asset_id=transfer.asset_id,
    from_owner=transfer.from_owner,
    to_owner=transfer.to_owner,
    expected_version=transfer.expected_version,
  )
}

///|
fn replay_key(
  source_digest : @bft.Digest,
  effect : @replay.AssetEffect,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, source_digest.0)
  append_field(buffer, @replay.serialize_asset_effect(effect))
  buffer.to_string()
}

///|
fn replayed_effects_by_key(
  effects : Array[@replay.ReplayedAssetEffect],
) -> (Map[String, @replay.ReplayedAssetEffect], Bool) {
  let indexed : Map[String, @replay.ReplayedAssetEffect] = Map([])
  let mut manifest_conflict = false
  for replayed in effects {
    let key = replay_key(replayed.source_digest(), replayed.effect())
    match indexed.get(key) {
      Some(existing) =>
        if existing.manifest_digest() != replayed.manifest_digest() {
          manifest_conflict = true
        }
      None => indexed[key] = replayed
    }
  }
  (indexed, manifest_conflict)
}

///|
/// Compute a transaction without mutating local state.
pub fn InventoryIndex::plan(
  self : InventoryIndex,
  creations : @market.ReceiptBatch,
  transfers : Array[AssetTransfer],
  effects~ : Array[@replay.ReplayedAssetEffect],
) -> InventoryPlanResult {
  let record_updates : Map[String, AssetRecord] = Map([])
  let next_state_map = self.state_map.fork()
  let replay_index = replayed_effects_by_key(effects)
  if replay_index.1 {
    return PlanRejected(ReplayManifestConflict)
  }
  let replayed = replay_index.0
  let mut replay_manifest : @bft.Digest? = None
  for index, receipt in creations.receipts() {
    if record_updates.contains(receipt.asset_id) ||
      self.records.contains(receipt.asset_id) {
      return PlanRejected(DuplicateAsset(receipt.asset_id))
    }
    let expected_effect = creation_effect(receipt)
    let capability = match
      replayed.get(replay_key(receipt.source_event, expected_effect)) {
      None => return PlanRejected(UnreplayedCreation(index))
      Some(value) => value
    }
    if !capability.matches(
        session_id=self.session,
        manifest_digest=capability.manifest_digest(),
        source_digest=receipt.source_event,
        effect=expected_effect,
      ) {
      return PlanRejected(UnreplayedCreation(index))
    }
    match replay_manifest {
      None => replay_manifest = Some(capability.manifest_digest())
      Some(manifest) =>
        if manifest != capability.manifest_digest() {
          return PlanRejected(ReplayManifestConflict)
        }
    }
    let record = create_record(self.hasher, receipt)
    record_updates[receipt.asset_id] = record
    ignore(next_state_map.put(receipt.asset_id, serialize_asset_record(record)))
  }
  for index, transfer in transfers {
    let current = match record_updates.get(transfer.asset_id) {
      Some(record) => Some(record)
      None => self.records.get(transfer.asset_id)
    }
    let expected_effect = transfer_effect(transfer)
    let capability = replayed.get(
      replay_key(transfer.source_event, expected_effect),
    )
    let source_replayed = match capability {
      None => false
      Some(value) =>
        value.matches(
          session_id=self.session,
          manifest_digest=value.manifest_digest(),
          source_digest=transfer.source_event,
          effect=expected_effect,
        )
    }
    match validate_transfer(current, transfer, source_replayed) {
      Some(reason) => return PlanRejected(InvalidTransfer(index, reason))
      None => {
        let matched = capability.unwrap()
        match replay_manifest {
          None => replay_manifest = Some(matched.manifest_digest())
          Some(manifest) =>
            if manifest != matched.manifest_digest() {
              return PlanRejected(ReplayManifestConflict)
            }
        }
        let record = current.unwrap()
        let updated : AssetRecord = {
          ..record,
          owner_id: transfer.to_owner,
          version: record.version + 1,
          last_event: transfer.source_event,
        }
        record_updates[transfer.asset_id] = updated
        ignore(
          next_state_map.put(transfer.asset_id, serialize_asset_record(updated)),
        )
      }
    }
  }
  Planned(InventoryPlan::{
    base_root: self.root(),
    base_checkpoint: self.checkpoint_digest,
    base_epoch: self.checkpoint_epoch,
    record_updates,
    next_state_map,
    resulting_root: next_state_map.root(),
    delta_root: creations.root(),
    replay_manifest,
  })
}

///|
/// Atomically commit a plan only when the finalized checkpoint authenticates
/// its base ancestry, delta root, and resulting public-state root.
pub fn InventoryIndex::commit(
  self : InventoryIndex,
  finalized : @attestation.FinalizedCheckpoint,
  plan : InventoryPlan,
) -> InventoryCommitResult {
  if finalized.digest() == self.checkpoint_digest {
    return AlreadyCommitted
  }
  if plan.base_root != self.root() ||
    plan.base_checkpoint != self.checkpoint_digest ||
    plan.base_epoch != self.checkpoint_epoch {
    return StalePlan
  }
  let checkpoint = finalized.checkpoint()
  if checkpoint.session_id != self.session {
    return SessionMismatch
  }
  if checkpoint.previous_checkpoint != self.checkpoint_digest {
    return PreviousCheckpointMismatch
  }
  if checkpoint.epoch <= self.checkpoint_epoch {
    return EpochRegression
  }
  match plan.replay_manifest {
    Some(manifest) =>
      if checkpoint.manifest_digest != manifest {
        return ReplayManifestMismatch
      }
    None => ()
  }
  if checkpoint.asset_delta_root != plan.delta_root {
    return AssetDeltaRootMismatch
  }
  if checkpoint.public_state_root != plan.resulting_root {
    return PublicStateRootMismatch
  }
  for asset_id, record in plan.record_updates {
    self.records[asset_id] = record
  }
  self.state_map = plan.next_state_map
  self.checkpoint_digest = finalized.digest()
  self.checkpoint_epoch = checkpoint.epoch
  Committed
}

///|
pub fn InventoryIndex::proof(
  self : InventoryIndex,
  asset_id : String,
) -> InventoryProof? {
  match (self.records.get(asset_id), self.state_map.proof(asset_id)) {
    (Some(record), Some(map_proof)) =>
      Some(InventoryProof::{ record, map_proof })
    _ => None
  }
}

///|
fn record_is_structurally_valid(record : AssetRecord) -> Bool {
  record.asset_id != "" &&
  record.owner_id != "" &&
  record.item_type != "" &&
  record.quantity > 0 &&
  record.origin_output_index >= 0 &&
  record.origin_source_event.0 != "" &&
  record.origin_receipt_digest.0 != "" &&
  record.version >= 0 &&
  record.last_event.0 != ""
}

///|
pub fn verify_inventory_proof(
  hasher : &@bft.Hasher,
  expected_root : @bft.Digest,
  proof : InventoryProof,
) -> Bool {
  record_is_structurally_valid(proof.record) &&
  proof.record.asset_id == proof.map_proof.key &&
  serialize_asset_record(proof.record) == proof.map_proof.value &&
  @authmap.verify_membership(hasher, expected_root, proof.map_proof)
}

///|
/// Bind a current-state inventory proof back to the authority-verified item
/// creation receipt. The recipient is covered by the origin receipt digest even
/// though the current owner may have changed after one or more transfers.
pub fn inventory_proof_matches_origin_receipt(
  hasher : &@bft.Hasher,
  proof : InventoryProof,
  origin : @market.ItemReceipt,
) -> Bool {
  @market.validate_item_receipt(origin) == @market.ReceiptValid &&
  proof.record.asset_id == origin.asset_id &&
  proof.record.item_type == origin.item_type &&
  proof.record.quantity == origin.quantity &&
  proof.record.origin_source_event == origin.source_event &&
  proof.record.origin_output_index == origin.output_index &&
  proof.record.origin_receipt_digest ==
  inventory_origin_receipt_digest(hasher, origin)
}

///|
/// Marketplace gate for the current owner authenticated by public_state_root.
pub fn market_accepts_inventory_listing(
  hasher : &@bft.Hasher,
  finalized : @attestation.FinalizedCheckpoint,
  proof : InventoryProof,
  seller_id~ : String,
  rejected_ancestor~ : Bool,
) -> Bool {
  let included = proof.record.owner_id == seller_id &&
    verify_inventory_proof(
      hasher,
      finalized.checkpoint().public_state_root,
      proof,
    )
  @audit.market_accepts(
    @audit.CheckpointDecision::Finalized,
    item_included=included,
    rejected_ancestor~,
  )
}
