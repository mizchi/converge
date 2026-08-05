///|
/// Storage facts read inside the transaction that will apply an atomic seal
/// plan. `known_seal_complete` means the known checkpoint has its history,
/// head, required outbox entries, and consumed closure in the same committed
/// transaction footprint.
pub(all) struct CheckpointSealStorageSnapshot {
  boundary : AuditBoundary
  current_epoch : Int
  current_digest : @commitment.AuditDigest
  incoming_epoch_known : Bool
  known_digest_matches : Bool
  known_seal_complete : Bool
  closure_consumed : Bool
  outbox_entry_count : Int
  outbox_capacity : Int
  next_created_order : Int
} derive(Eq, Debug)

///|
/// Canonical checkpoint prepared by a game-specific adapter. The digest must
/// commit to the canonical envelope, including its boundary, epoch, and parent.
pub(all) struct CheckpointSealDraft {
  boundary : AuditBoundary
  epoch : Int
  previous_checkpoint : @commitment.AuditDigest
  checkpoint_digest : @commitment.AuditDigest
  canonical_envelope : String
} derive(Eq, Debug)

///|
pub(all) struct CheckpointSealHead {
  boundary : AuditBoundary
  epoch : Int
  checkpoint_digest : @commitment.AuditDigest
} derive(Eq, Debug)

///|
pub(all) enum CheckpointSealConflictReason {
  SealSameEpochFork
  SealParentFork
  SealIncompleteKnownCommit
} derive(Eq, Debug)

///|
pub(all) enum CheckpointSealRefusal {
  SealInvalidStorageSnapshot
  SealInvalidCheckpointDraft
  SealBoundaryMismatch
  SealClosureEpochMismatch
  SealClosureAlreadyConsumed
  SealEpochGap
  SealStaleEpoch
  SealDestinationsEmpty
  SealDestinationEmpty
  SealDestinationDuplicate
  SealOutboxCapacityExceeded
  SealCreatedOrderOverflow
} derive(Eq, Debug)

///|
/// Opaque write set. A persistence adapter must apply all represented changes
/// in one transaction and compare the expected snapshot before commit.
pub struct AtomicCheckpointSealPlan {
  expected_snapshot_value : CheckpointSealStorageSnapshot
  checkpoint_value : CheckpointSealDraft
  next_head_value : CheckpointSealHead
  outbox_entries_value : Array[CheckpointOutboxEntry]
  consumed_closure_epoch_value : Int
  next_outbox_entry_count_value : Int
  next_created_order_value : Int
} derive(Eq, Debug)

///|
pub(all) enum AtomicCheckpointSealResult {
  AtomicCheckpointSealPrepared(AtomicCheckpointSealPlan)
  CheckpointSealAlreadyCommitted
  CheckpointSealConflict(CheckpointSealConflictReason)
  CheckpointSealRefused(CheckpointSealRefusal)
} derive(Eq, Debug)

///|
fn seal_snapshot_valid(snapshot : CheckpointSealStorageSnapshot) -> Bool {
  boundary_valid(snapshot.boundary) &&
  snapshot.current_epoch >= -1 &&
  snapshot.current_digest.0 != "" &&
  snapshot.outbox_entry_count >= 0 &&
  snapshot.outbox_capacity >= 0 &&
  snapshot.outbox_entry_count <= snapshot.outbox_capacity &&
  snapshot.next_created_order >= 0 &&
  (!snapshot.known_digest_matches || snapshot.incoming_epoch_known) &&
  (
    !snapshot.known_seal_complete ||
    (snapshot.known_digest_matches && snapshot.closure_consumed)
  )
}

///|
fn seal_draft_valid(draft : CheckpointSealDraft) -> Bool {
  boundary_valid(draft.boundary) &&
  draft.epoch >= 0 &&
  draft.previous_checkpoint.0 != "" &&
  draft.checkpoint_digest.0 != "" &&
  draft.canonical_envelope != ""
}

///|
fn classify_seal_destinations(
  destinations : Array[String],
) -> CheckpointSealRefusal? {
  if destinations.length() == 0 {
    return Some(SealDestinationsEmpty)
  }
  let sorted = destinations.copy()
  sorted.sort_by(fn(left, right) { right.compare(left) })
  for index = 0; index < sorted.length(); index = index + 1 {
    if sorted[index] == "" {
      return Some(SealDestinationEmpty)
    }
    if index > 0 && sorted[index] == sorted[index - 1] {
      return Some(SealDestinationDuplicate)
    }
  }
  None
}

///|
fn make_seal_outbox_entries(
  snapshot : CheckpointSealStorageSnapshot,
  draft : CheckpointSealDraft,
  destinations : Array[String],
) -> Array[CheckpointOutboxEntry] {
  let entries : Array[CheckpointOutboxEntry] = []
  for index = 0; index < destinations.length(); index = index + 1 {
    match
      open_checkpoint_outbox_entry(
        boundary=draft.boundary,
        destination_id=destinations[index],
        epoch=draft.epoch,
        checkpoint_digest=draft.checkpoint_digest,
        canonical_envelope=draft.canonical_envelope,
        created_order=snapshot.next_created_order + index,
      ) {
      OutboxEntryReady(entry) => entries.push(entry)
      OutboxEntryRefused(_) => abort("validated seal outbox entry diverged")
    }
  }
  entries
}

///|
/// Prepare the complete write set for IMPL-SEAL-001 without mutating storage.
/// A successful plan means history append, head update, all durable outbox
/// inserts, and closure consumption are valid together. It does not mean the
/// transaction has committed; the adapter must CAS the expected snapshot and
/// apply the plan atomically.
pub fn prepare_atomic_checkpoint_seal(
  snapshot : CheckpointSealStorageSnapshot,
  draft : CheckpointSealDraft,
  closure : TrustedEpochClosure,
  destinations : Array[String],
) -> AtomicCheckpointSealResult {
  if !seal_snapshot_valid(snapshot) {
    return CheckpointSealRefused(SealInvalidStorageSnapshot)
  }
  if !seal_draft_valid(draft) {
    return CheckpointSealRefused(SealInvalidCheckpointDraft)
  }
  if snapshot.boundary != draft.boundary ||
    closure.evidence_value.boundary != draft.boundary {
    return CheckpointSealRefused(SealBoundaryMismatch)
  }
  if closure.evidence_value.epoch != draft.epoch {
    return CheckpointSealRefused(SealClosureEpochMismatch)
  }
  match classify_seal_destinations(destinations) {
    Some(reason) => return CheckpointSealRefused(reason)
    None => ()
  }
  let head_decision = @audit.classify_checkpoint_head(
    boundary_matches=true,
    epoch_known=snapshot.incoming_epoch_known,
    known_digest_matches=snapshot.known_digest_matches,
    current_epoch=snapshot.current_epoch,
    incoming_epoch=draft.epoch,
    parent_matches=draft.previous_checkpoint == snapshot.current_digest,
  )
  match head_decision {
    @audit.CheckpointHeadDecision::Duplicate =>
      if snapshot.known_seal_complete {
        CheckpointSealAlreadyCommitted
      } else {
        CheckpointSealConflict(SealIncompleteKnownCommit)
      }
    @audit.CheckpointHeadDecision::SameEpochFork =>
      CheckpointSealConflict(SealSameEpochFork)
    @audit.CheckpointHeadDecision::ParentFork =>
      CheckpointSealConflict(SealParentFork)
    @audit.CheckpointHeadDecision::Gap => CheckpointSealRefused(SealEpochGap)
    @audit.CheckpointHeadDecision::Stale =>
      CheckpointSealRefused(SealStaleEpoch)
    @audit.CheckpointHeadDecision::BoundaryMismatch =>
      CheckpointSealRefused(SealBoundaryMismatch)
    @audit.CheckpointHeadDecision::Advance => {
      let boundary_matches = snapshot.boundary == draft.boundary &&
        closure.evidence_value.boundary == draft.boundary
      let closure_epoch_matches = closure.evidence_value.epoch == draft.epoch
      let closure_available = !snapshot.closure_consumed
      let exact_next = draft.epoch > snapshot.current_epoch &&
        draft.epoch - 1 == snapshot.current_epoch
      let parent_matches = draft.previous_checkpoint == snapshot.current_digest
      if !closure_available {
        return CheckpointSealRefused(SealClosureAlreadyConsumed)
      }
      let destination_count = destinations.length()
      let remaining_capacity = snapshot.outbox_capacity -
        snapshot.outbox_entry_count
      let capacity_available = destination_count <= remaining_capacity
      if !capacity_available {
        return CheckpointSealRefused(SealOutboxCapacityExceeded)
      }
      let next_created_order = snapshot.next_created_order + destination_count
      let created_order_available = next_created_order >=
        snapshot.next_created_order
      if !created_order_available {
        return CheckpointSealRefused(SealCreatedOrderOverflow)
      }
      if !@audit.runtime_atomic_seal_advance_allowed(
          boundary_matches, closure_epoch_matches, closure_available, exact_next,
          parent_matches, true, capacity_available, created_order_available,
        ) {
        abort("atomic seal validator diverged")
      }
      let outbox_entries = make_seal_outbox_entries(
        snapshot, draft, destinations,
      )
      AtomicCheckpointSealPrepared(AtomicCheckpointSealPlan::{
        expected_snapshot_value: snapshot,
        checkpoint_value: draft,
        next_head_value: {
          boundary: draft.boundary,
          epoch: draft.epoch,
          checkpoint_digest: draft.checkpoint_digest,
        },
        outbox_entries_value: outbox_entries,
        consumed_closure_epoch_value: closure.evidence_value.epoch,
        next_outbox_entry_count_value: snapshot.outbox_entry_count +
        destination_count,
        next_created_order_value: next_created_order,
      })
    }
  }
}

///|
pub fn AtomicCheckpointSealPlan::expected_snapshot(
  self : AtomicCheckpointSealPlan,
) -> CheckpointSealStorageSnapshot {
  self.expected_snapshot_value
}

///|
pub fn AtomicCheckpointSealPlan::checkpoint(
  self : AtomicCheckpointSealPlan,
) -> CheckpointSealDraft {
  self.checkpoint_value
}

///|
pub fn AtomicCheckpointSealPlan::next_head(
  self : AtomicCheckpointSealPlan,
) -> CheckpointSealHead {
  self.next_head_value
}

///|
pub fn AtomicCheckpointSealPlan::outbox_entries(
  self : AtomicCheckpointSealPlan,
) -> Array[CheckpointOutboxEntry] {
  self.outbox_entries_value.copy()
}

///|
pub fn AtomicCheckpointSealPlan::consumed_closure_epoch(
  self : AtomicCheckpointSealPlan,
) -> Int {
  self.consumed_closure_epoch_value
}

///|
pub fn AtomicCheckpointSealPlan::next_outbox_entry_count(
  self : AtomicCheckpointSealPlan,
) -> Int {
  self.next_outbox_entry_count_value
}

///|
pub fn AtomicCheckpointSealPlan::next_created_order(
  self : AtomicCheckpointSealPlan,
) -> Int {
  self.next_created_order_value
}
