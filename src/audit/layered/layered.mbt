///|
/// Compact metadata for one event window. Event payloads are retained only by
/// `SealedMicroCheckpoint`, so callers can discard them independently of this
/// root record.
pub(all) struct MicroCheckpoint {
  scope_id : String
  macro_epoch : Int
  micro_index : Int
  starts_at_ms : Int
  ends_at_ms : Int
  event_count : Int
  event_root : @bft.Digest
  digest : @bft.Digest
} derive(Eq, Debug)

///|
/// Compact metadata for one authority-facing macro window. `micro_root`
/// commits the canonical serialized micro checkpoints in window order.
pub(all) struct MacroCheckpoint {
  scope_id : String
  epoch : Int
  starts_at_ms : Int
  ends_at_ms : Int
  micro_checkpoint_count : Int
  event_count : Int
  previous_macro_digest : @bft.Digest
  micro_root : @bft.Digest
  digest : @bft.Digest
} derive(Eq, Debug)

///|
struct PendingAuditEvent {
  event_time_ms : Int
  canonical_payload : String
}

///|
/// A micro checkpoint plus retained leaves needed to answer event inclusion
/// challenges. Stripping this to `MicroCheckpoint` intentionally discards that
/// capability.
pub struct SealedMicroCheckpoint {
  checkpoint_value : MicroCheckpoint
  canonical_payloads : Array[String]
  tree : @merkle.MerkleTree
}

///|
/// A macro checkpoint plus its retained micro records and inclusion tree.
pub struct SealedMacroCheckpoint {
  checkpoint_value : MacroCheckpoint
  micro_values : Array[SealedMicroCheckpoint]
  tree : @merkle.MerkleTree
}

///|
/// Two-level proof from one canonical event payload through its micro root to
/// the authority-facing macro root.
pub(all) struct LayeredEventProof {
  micro_checkpoint : MicroCheckpoint
  event_proof : @merkle.MerkleProof
  micro_proof : @merkle.MerkleProof
} derive(Eq, Debug)

///|
pub(all) enum LayeredBuilderOpenError {
  EmptyScopeId
  NonPositivePendingEventLimit
} derive(Eq, Debug)

///|
pub enum LayeredBuilderOpenResult {
  LayeredBuilderReady(LayeredCheckpointBuilder)
  LayeredBuilderRefused(LayeredBuilderOpenError)
}

///|
pub(all) enum AuditEventAdmissionError {
  EventBeforeOrigin
  EventBehindWatermark
  InvalidBuilderWatermark
  EmptyCanonicalEvent
  PendingEventLimitReached
} derive(Eq, Debug)

///|
pub(all) enum AppendAuditEventResult {
  AuditEventAppended
  AuditEventDuplicate
  AuditEventRefused(AuditEventAdmissionError)
} derive(Eq, Debug)

///|
pub(all) enum AdvanceWatermarkError {
  WatermarkBeforeOrigin
  WatermarkMovedBackward
  NegativeCheckpointWindowBudget
  /// The first value is a lower bound discovered after scanning at most
  /// `budget + 1` windows, not an unbounded exact catch-up count.
  CheckpointWindowBudgetExceeded(Int, Int)
} derive(Eq, Debug)

///|
pub enum AdvanceWatermarkResult {
  WatermarkAdvanced(LayeredCheckpointEmission)
  WatermarkRefused(AdvanceWatermarkError)
}

///|
/// All windows sealed by one atomic watermark advance.
pub struct LayeredCheckpointEmission {
  micro_values : Array[SealedMicroCheckpoint]
  macro_values : Array[SealedMacroCheckpoint]
}

///|
/// Watermark-driven event -> micro -> macro checkpoint builder.
///
/// Event time is an authenticated, application-assigned audit time, not an
/// untrusted client wall clock. Events may arrive in any order while their time
/// is at or ahead of the watermark. Advancing the watermark promises that no
/// more earlier events will be accepted.
pub struct LayeredCheckpointBuilder {
  hasher : &@bft.Hasher
  policy : @audit.VerifiedCheckpointPolicy
  scope_id : String
  origin_ms : Int
  max_pending_events : Int
  mut watermark_ms : Int
  mut macro_epoch : Int
  mut micro_index : Int
  mut window_start_ms : Int
  mut previous_macro_digest : @bft.Digest
  mut pending_events : Array[PendingAuditEvent]
  pending_payloads : Map[String, Bool]
  mut current_macro_micros : Array[SealedMicroCheckpoint]
}

///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
fn append_int_field(buffer : StringBuilder, value : Int) -> Unit {
  append_field(buffer, value.to_string())
}

///|
fn serialize_micro_checkpoint_core(checkpoint : MicroCheckpoint) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "layered-micro-v1")
  append_field(buffer, checkpoint.scope_id)
  append_int_field(buffer, checkpoint.macro_epoch)
  append_int_field(buffer, checkpoint.micro_index)
  append_int_field(buffer, checkpoint.starts_at_ms)
  append_int_field(buffer, checkpoint.ends_at_ms)
  append_int_field(buffer, checkpoint.event_count)
  append_field(buffer, checkpoint.event_root.0)
  buffer.to_string()
}

///|
/// Canonical macro-leaf representation of a micro checkpoint.
pub fn serialize_micro_checkpoint(checkpoint : MicroCheckpoint) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "layered-micro-record-v1")
  append_field(buffer, serialize_micro_checkpoint_core(checkpoint))
  append_field(buffer, checkpoint.digest.0)
  buffer.to_string()
}

///|
fn micro_checkpoint_digest(
  hasher : &@bft.Hasher,
  checkpoint : MicroCheckpoint,
) -> @bft.Digest {
  hasher.hash_string(serialize_micro_checkpoint_core(checkpoint))
}

///|
fn serialize_macro_checkpoint_core(checkpoint : MacroCheckpoint) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "layered-macro-v1")
  append_field(buffer, checkpoint.scope_id)
  append_int_field(buffer, checkpoint.epoch)
  append_int_field(buffer, checkpoint.starts_at_ms)
  append_int_field(buffer, checkpoint.ends_at_ms)
  append_int_field(buffer, checkpoint.micro_checkpoint_count)
  append_int_field(buffer, checkpoint.event_count)
  append_field(buffer, checkpoint.previous_macro_digest.0)
  append_field(buffer, checkpoint.micro_root.0)
  buffer.to_string()
}

///|
/// Canonical storage/wire representation of a macro checkpoint.
pub fn serialize_macro_checkpoint(checkpoint : MacroCheckpoint) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "layered-macro-record-v1")
  append_field(buffer, serialize_macro_checkpoint_core(checkpoint))
  append_field(buffer, checkpoint.digest.0)
  buffer.to_string()
}

///|
fn macro_checkpoint_digest(
  hasher : &@bft.Hasher,
  checkpoint : MacroCheckpoint,
) -> @bft.Digest {
  hasher.hash_string(serialize_macro_checkpoint_core(checkpoint))
}

///|
pub fn LayeredCheckpointBuilder::open(
  hasher : &@bft.Hasher,
  policy : @audit.VerifiedCheckpointPolicy,
  scope_id~ : String,
  origin_ms~ : Int,
  previous_macro_digest~ : @bft.Digest,
  max_pending_events~ : Int,
) -> LayeredBuilderOpenResult {
  if scope_id == "" {
    return LayeredBuilderRefused(EmptyScopeId)
  }
  if max_pending_events <= 0 {
    return LayeredBuilderRefused(NonPositivePendingEventLimit)
  }
  LayeredBuilderReady(LayeredCheckpointBuilder::{
    hasher,
    policy,
    scope_id,
    origin_ms,
    max_pending_events,
    watermark_ms: origin_ms,
    macro_epoch: 0,
    micro_index: 0,
    window_start_ms: origin_ms,
    previous_macro_digest,
    pending_events: [],
    pending_payloads: {},
    current_macro_micros: [],
  })
}

///|
pub fn LayeredCheckpointBuilder::watermark_ms(
  self : LayeredCheckpointBuilder,
) -> Int {
  self.watermark_ms
}

///|
pub fn LayeredCheckpointBuilder::pending_event_count(
  self : LayeredCheckpointBuilder,
) -> Int {
  self.pending_events.length()
}

///|
pub fn LayeredCheckpointBuilder::append_event(
  self : LayeredCheckpointBuilder,
  event_time_ms : Int,
  canonical_payload : String,
) -> AppendAuditEventResult {
  match
    @audit.classify_audit_event_time(
      origin_ms=self.origin_ms,
      watermark_ms=self.watermark_ms,
      event_time_ms~,
    ) {
    @audit.AuditEventTimeDecision::AuditEventBeforeOrigin =>
      return AuditEventRefused(EventBeforeOrigin)
    @audit.AuditEventTimeDecision::AuditEventBehindWatermark =>
      return AuditEventRefused(EventBehindWatermark)
    @audit.AuditEventTimeDecision::InvalidAuditWatermark =>
      return AuditEventRefused(InvalidBuilderWatermark)
    @audit.AuditEventTimeDecision::AuditEventTimeAccepted => ()
  }
  if canonical_payload == "" {
    return AuditEventRefused(EmptyCanonicalEvent)
  }
  if self.pending_payloads.contains(canonical_payload) {
    return AuditEventDuplicate
  }
  if self.pending_events.length() >= self.max_pending_events {
    return AuditEventRefused(PendingEventLimitReached)
  }
  self.pending_events.push(PendingAuditEvent::{
    event_time_ms,
    canonical_payload,
  })
  self.pending_payloads[canonical_payload] = true
  AuditEventAppended
}

///|
fn LayeredCheckpointBuilder::macro_end_ms(
  self : LayeredCheckpointBuilder,
) -> Int {
  let policy = self.policy.policy()
  self.origin_ms + (self.macro_epoch + 1) * policy.macro_checkpoint_interval_ms
}

///|
fn LayeredCheckpointBuilder::next_boundary_ms(
  self : LayeredCheckpointBuilder,
) -> Int {
  let policy = self.policy.policy()
  let micro_end = self.window_start_ms + policy.micro_checkpoint_interval_ms
  let macro_end = self.macro_end_ms()
  if micro_end < macro_end {
    micro_end
  } else {
    macro_end
  }
}

///|
fn LayeredCheckpointBuilder::due_window_count(
  self : LayeredCheckpointBuilder,
  target_watermark_ms : Int,
  stop_after : Int,
) -> Int {
  let policy = self.policy.policy()
  let mut epoch = self.macro_epoch
  let mut window_start = self.window_start_ms
  let mut count = 0
  while true {
    let macro_end = self.origin_ms +
      (epoch + 1) * policy.macro_checkpoint_interval_ms
    let micro_end = window_start + policy.micro_checkpoint_interval_ms
    let boundary = if micro_end < macro_end { micro_end } else { macro_end }
    if boundary > target_watermark_ms {
      break
    }
    count += 1
    if count > stop_after {
      break
    }
    window_start = boundary
    if boundary == macro_end {
      epoch += 1
    }
  }
  count
}

///|
fn LayeredCheckpointBuilder::take_window_payloads(
  self : LayeredCheckpointBuilder,
  starts_at_ms : Int,
  ends_at_ms : Int,
) -> Array[String] {
  let payloads : Array[String] = []
  let retained : Array[PendingAuditEvent] = []
  for event in self.pending_events {
    if event.event_time_ms >= starts_at_ms && event.event_time_ms < ends_at_ms {
      payloads.push(event.canonical_payload)
      ignore(self.pending_payloads.remove(event.canonical_payload))
    } else {
      retained.push(event)
    }
  }
  self.pending_events = retained
  payloads.sort_by(fn(left, right) { left.compare(right) })
  payloads
}

///|
fn LayeredCheckpointBuilder::seal_next_micro(
  self : LayeredCheckpointBuilder,
  ends_at_ms : Int,
) -> SealedMicroCheckpoint {
  let payloads = self.take_window_payloads(self.window_start_ms, ends_at_ms)
  let tree = @merkle.MerkleTree::build(self.hasher, payloads)
  let unsigned : MicroCheckpoint = {
    scope_id: self.scope_id,
    macro_epoch: self.macro_epoch,
    micro_index: self.micro_index,
    starts_at_ms: self.window_start_ms,
    ends_at_ms,
    event_count: payloads.length(),
    event_root: tree.root(),
    digest: @bft.Digest(""),
  }
  let checkpoint = {
    ..unsigned,
    digest: micro_checkpoint_digest(self.hasher, unsigned),
  }
  SealedMicroCheckpoint::{
    checkpoint_value: checkpoint,
    canonical_payloads: payloads,
    tree,
  }
}

///|
fn LayeredCheckpointBuilder::seal_macro(
  self : LayeredCheckpointBuilder,
  ends_at_ms : Int,
) -> SealedMacroCheckpoint {
  let payloads : Array[String] = []
  let mut event_count = 0
  for micro in self.current_macro_micros {
    payloads.push(serialize_micro_checkpoint(micro.checkpoint_value))
    event_count += micro.checkpoint_value.event_count
  }
  let tree = @merkle.MerkleTree::build(self.hasher, payloads)
  let policy = self.policy.policy()
  let starts_at_ms = self.origin_ms +
    self.macro_epoch * policy.macro_checkpoint_interval_ms
  let unsigned : MacroCheckpoint = {
    scope_id: self.scope_id,
    epoch: self.macro_epoch,
    starts_at_ms,
    ends_at_ms,
    micro_checkpoint_count: self.current_macro_micros.length(),
    event_count,
    previous_macro_digest: self.previous_macro_digest,
    micro_root: tree.root(),
    digest: @bft.Digest(""),
  }
  let checkpoint = {
    ..unsigned,
    digest: macro_checkpoint_digest(self.hasher, unsigned),
  }
  SealedMacroCheckpoint::{
    checkpoint_value: checkpoint,
    micro_values: self.current_macro_micros.copy(),
    tree,
  }
}

///|
/// Atomically advance a trusted watermark. `max_windows` bounds catch-up work;
/// exceeding it refuses before any event or checkpoint state is mutated.
pub fn LayeredCheckpointBuilder::advance_watermark(
  self : LayeredCheckpointBuilder,
  target_watermark_ms : Int,
  max_windows~ : Int,
) -> AdvanceWatermarkResult {
  if target_watermark_ms < self.origin_ms {
    return WatermarkRefused(WatermarkBeforeOrigin)
  }
  if target_watermark_ms < self.watermark_ms {
    return WatermarkRefused(WatermarkMovedBackward)
  }
  if max_windows < 0 {
    return WatermarkRefused(NegativeCheckpointWindowBudget)
  }
  let due = self.due_window_count(target_watermark_ms, max_windows)
  if due > max_windows {
    return WatermarkRefused(CheckpointWindowBudgetExceeded(due, max_windows))
  }
  let emitted_micros : Array[SealedMicroCheckpoint] = []
  let emitted_macros : Array[SealedMacroCheckpoint] = []
  for _ in 0..<due {
    let boundary = self.next_boundary_ms()
    let macro_end = self.macro_end_ms()
    let micro = self.seal_next_micro(boundary)
    self.current_macro_micros.push(micro)
    emitted_micros.push(micro)
    self.window_start_ms = boundary
    if boundary == macro_end {
      let sealed_macro = self.seal_macro(boundary)
      self.previous_macro_digest = sealed_macro.checkpoint_value.digest
      emitted_macros.push(sealed_macro)
      self.current_macro_micros = []
      self.macro_epoch += 1
      self.micro_index = 0
    } else {
      self.micro_index += 1
    }
  }
  self.watermark_ms = target_watermark_ms
  WatermarkAdvanced(LayeredCheckpointEmission::{
    micro_values: emitted_micros,
    macro_values: emitted_macros,
  })
}

///|
pub fn LayeredCheckpointEmission::empty() -> LayeredCheckpointEmission {
  LayeredCheckpointEmission::{ micro_values: [], macro_values: [] }
}

///|
pub fn LayeredCheckpointEmission::micro_checkpoints(
  self : LayeredCheckpointEmission,
) -> Array[SealedMicroCheckpoint] {
  self.micro_values.copy()
}

///|
pub fn LayeredCheckpointEmission::macro_checkpoints(
  self : LayeredCheckpointEmission,
) -> Array[SealedMacroCheckpoint] {
  self.macro_values.copy()
}

///|
pub fn SealedMicroCheckpoint::checkpoint(
  self : SealedMicroCheckpoint,
) -> MicroCheckpoint {
  self.checkpoint_value
}

///|
pub fn SealedMicroCheckpoint::event_proof(
  self : SealedMicroCheckpoint,
  canonical_payload : String,
) -> @merkle.MerkleProof? {
  for index, payload in self.canonical_payloads {
    if payload == canonical_payload {
      return self.tree.proof(index)
    }
  }
  None
}

///|
pub fn SealedMacroCheckpoint::checkpoint(
  self : SealedMacroCheckpoint,
) -> MacroCheckpoint {
  self.checkpoint_value
}

///|
pub fn SealedMacroCheckpoint::micro_checkpoint(
  self : SealedMacroCheckpoint,
  index : Int,
) -> MicroCheckpoint? {
  if index < 0 || index >= self.micro_values.length() {
    None
  } else {
    Some(self.micro_values[index].checkpoint_value)
  }
}

///|
pub fn SealedMacroCheckpoint::micro_proof(
  self : SealedMacroCheckpoint,
  index : Int,
) -> @merkle.MerkleProof? {
  self.tree.proof(index)
}

///|
pub fn SealedMacroCheckpoint::event_proof(
  self : SealedMacroCheckpoint,
  canonical_payload : String,
) -> LayeredEventProof? {
  for index, micro in self.micro_values {
    match micro.event_proof(canonical_payload) {
      None => ()
      Some(event_proof) =>
        match self.tree.proof(index) {
          None => return None
          Some(micro_proof) =>
            return Some({
              micro_checkpoint: micro.checkpoint_value,
              event_proof,
              micro_proof,
            })
        }
    }
  }
  None
}

///|
pub fn verify_micro_checkpoint_event(
  hasher : &@bft.Hasher,
  checkpoint : MicroCheckpoint,
  canonical_payload : String,
  proof : @merkle.MerkleProof,
) -> Bool {
  if checkpoint.event_count <= 0 ||
    checkpoint.ends_at_ms <= checkpoint.starts_at_ms ||
    proof.leaf_count != checkpoint.event_count ||
    micro_checkpoint_digest(hasher, checkpoint) != checkpoint.digest {
    return false
  }
  @merkle.verify_inclusion(
    hasher,
    canonical_payload,
    checkpoint.event_root,
    proof,
  )
}

///|
pub fn verify_macro_checkpoint_micro(
  hasher : &@bft.Hasher,
  checkpoint : MacroCheckpoint,
  micro : MicroCheckpoint,
  proof : @merkle.MerkleProof,
) -> Bool {
  if checkpoint.micro_checkpoint_count <= 0 ||
    checkpoint.ends_at_ms <= checkpoint.starts_at_ms ||
    proof.leaf_count != checkpoint.micro_checkpoint_count ||
    proof.leaf_index != micro.micro_index ||
    macro_checkpoint_digest(hasher, checkpoint) != checkpoint.digest ||
    micro_checkpoint_digest(hasher, micro) != micro.digest ||
    micro.scope_id != checkpoint.scope_id ||
    micro.macro_epoch != checkpoint.epoch ||
    micro.starts_at_ms < checkpoint.starts_at_ms ||
    micro.ends_at_ms > checkpoint.ends_at_ms ||
    micro.ends_at_ms <= micro.starts_at_ms {
    return false
  }
  @merkle.verify_inclusion(
    hasher,
    serialize_micro_checkpoint(micro),
    checkpoint.micro_root,
    proof,
  )
}

///|
/// Verify both Merkle levels and all metadata/digest bindings for an event in a
/// macro checkpoint.
pub fn verify_macro_checkpoint_event(
  hasher : &@bft.Hasher,
  checkpoint : MacroCheckpoint,
  canonical_payload : String,
  proof : LayeredEventProof,
) -> Bool {
  verify_micro_checkpoint_event(
    hasher,
    proof.micro_checkpoint,
    canonical_payload,
    proof.event_proof,
  ) &&
  verify_macro_checkpoint_micro(
    hasher,
    checkpoint,
    proof.micro_checkpoint,
    proof.micro_proof,
  )
}
