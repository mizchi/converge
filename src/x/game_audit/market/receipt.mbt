///|
/// Durable asset creation record committed by a checkpoint.
pub(all) struct ItemReceipt {
  asset_id : String
  recipient_id : String
  item_type : String
  quantity : Int
  source_event : @bft.Digest
  output_index : Int
} derive(Eq, Debug)

///|
pub(all) enum ItemReceiptValidation {
  ReceiptValid
  MissingAssetId
  MissingRecipientId
  MissingItemType
  InvalidQuantity
  InvalidOutputIndex
} derive(Eq, Debug)

///|
pub(all) enum ReceiptBatchError {
  InvalidReceipt(Int, ItemReceiptValidation)
  DuplicateAssetId(String)
  DuplicateSourceOutput(Int)
} derive(Eq, Debug)

///|
pub(all) enum ReceiptBatchBuildResult {
  Built(ReceiptBatch)
  BatchRejected(ReceiptBatchError)
}

///|
pub(all) struct ItemReceiptProof {
  receipt : ItemReceipt
  merkle_proof : @merkle.MerkleProof
} derive(Eq, Debug)

///|
pub struct ReceiptBatch {
  receipts : Array[ItemReceipt]
  asset_indices : Map[String, Int]
  tree : @merkle.MerkleTree
}

///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
/// Canonical payload committed as a Merkle leaf.
pub fn serialize_item_receipt(receipt : ItemReceipt) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "item-receipt-v1")
  append_field(buffer, receipt.asset_id)
  append_field(buffer, receipt.recipient_id)
  append_field(buffer, receipt.item_type)
  append_field(buffer, receipt.quantity.to_string())
  append_field(buffer, receipt.source_event.0)
  append_field(buffer, receipt.output_index.to_string())
  buffer.to_string()
}

///|
fn source_output_key(receipt : ItemReceipt) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, receipt.source_event.0)
  append_field(buffer, receipt.output_index.to_string())
  buffer.to_string()
}

///|
/// Structural validation only. Game-specific replay must still establish that
/// the source event was entitled to create this item.
pub fn validate_item_receipt(receipt : ItemReceipt) -> ItemReceiptValidation {
  if receipt.asset_id == "" {
    return MissingAssetId
  }
  if receipt.recipient_id == "" {
    return MissingRecipientId
  }
  if receipt.item_type == "" {
    return MissingItemType
  }
  if receipt.quantity <= 0 {
    return InvalidQuantity
  }
  if receipt.output_index < 0 {
    return InvalidOutputIndex
  }
  ReceiptValid
}

///|
/// Validate and build the item delta Merkle tree in O(n).
pub fn build_receipt_batch(
  hasher : &@bft.Hasher,
  receipts : Array[ItemReceipt],
) -> ReceiptBatchBuildResult {
  let asset_indices : Map[String, Int] = Map([])
  let source_outputs : Map[String, Bool] = Map([])
  let payloads : Array[String] = []
  for index, receipt in receipts {
    let validation = validate_item_receipt(receipt)
    if validation != ReceiptValid {
      return BatchRejected(InvalidReceipt(index, validation))
    }
    if asset_indices.contains(receipt.asset_id) {
      return BatchRejected(DuplicateAssetId(receipt.asset_id))
    }
    let coordinate = source_output_key(receipt)
    if source_outputs.contains(coordinate) {
      return BatchRejected(DuplicateSourceOutput(index))
    }
    asset_indices[receipt.asset_id] = index
    source_outputs[coordinate] = true
    payloads.push(serialize_item_receipt(receipt))
  }
  Built(ReceiptBatch::{
    receipts: receipts.copy(),
    asset_indices,
    tree: @merkle.MerkleTree::build(hasher, payloads),
  })
}

///|
pub fn ReceiptBatch::root(self : ReceiptBatch) -> @bft.Digest {
  self.tree.root()
}

///|
pub fn ReceiptBatch::length(self : ReceiptBatch) -> Int {
  self.receipts.length()
}

///|
/// Return an isolated copy for deterministic inventory planning.
pub fn ReceiptBatch::receipts(self : ReceiptBatch) -> Array[ItemReceipt] {
  self.receipts.copy()
}

///|
pub fn ReceiptBatch::proof_for(
  self : ReceiptBatch,
  asset_id : String,
) -> ItemReceiptProof? {
  match self.asset_indices.get(asset_id) {
    None => None
    Some(index) =>
      match self.tree.proof(index) {
        None => None
        Some(proof) =>
          Some(ItemReceiptProof::{
            receipt: self.receipts[index],
            merkle_proof: proof,
          })
      }
  }
}

///|
/// Marketplace gate: structural validity, ownership, inclusion in the
/// authority-signed finalized checkpoint, and clean ancestry are all required.
pub fn market_accepts_listing(
  hasher : &@bft.Hasher,
  finalized : @attestation.FinalizedCheckpoint,
  proof : ItemReceiptProof,
  replayed~ : @replay.ReplayedAssetEffect,
  seller_id~ : String,
  rejected_ancestor~ : Bool,
) -> Bool {
  let structurally_valid = validate_item_receipt(proof.receipt) == ReceiptValid
  let owned = proof.receipt.recipient_id == seller_id
  let expected_effect = @replay.AssetEffect::Create(
    asset_id=proof.receipt.asset_id,
    recipient_id=proof.receipt.recipient_id,
    item_type=proof.receipt.item_type,
    quantity=proof.receipt.quantity,
    output_index=proof.receipt.output_index,
  )
  let effect_replayed = replayed.matches(
    session_id=finalized.checkpoint().session_id,
    manifest_digest=finalized.checkpoint().manifest_digest,
    source_digest=proof.receipt.source_event,
    effect=expected_effect,
  )
  let included = structurally_valid &&
    owned &&
    effect_replayed &&
    @merkle.verify_inclusion(
      hasher,
      serialize_item_receipt(proof.receipt),
      finalized.checkpoint().asset_delta_root,
      proof.merkle_proof,
    )
  @audit.market_accepts(
    @audit.CheckpointDecision::Finalized,
    item_included=included,
    rejected_ancestor~,
  )
}
