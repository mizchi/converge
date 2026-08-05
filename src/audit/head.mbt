///|
/// Storage-independent classification of an authenticated checkpoint head.
pub(all) enum CheckpointHeadDecision {
  Advance
  Duplicate
  SameEpochFork
  ParentFork
  Gap
  Stale
  BoundaryMismatch
} derive(Eq, Debug)

///|
/// Classify one authenticated checkpoint after the storage adapter has looked
/// up the incoming epoch. Authentication and persistence stay outside this pure
/// function; applications can share the transition rules across local DBs,
/// peers, and authority servers.
pub fn classify_checkpoint_head(
  boundary_matches~ : Bool,
  epoch_known~ : Bool,
  known_digest_matches~ : Bool,
  current_epoch~ : Int,
  incoming_epoch~ : Int,
  parent_matches~ : Bool,
) -> CheckpointHeadDecision where {
  proof_ensure: decision => {
    checkpoint_head_decision_post(
      boundary_matches, epoch_known, known_digest_matches, current_epoch, incoming_epoch,
      parent_matches, decision,
    )
  },
} {
  let decision = if !boundary_matches {
    BoundaryMismatch
  } else if epoch_known {
    if known_digest_matches {
      Duplicate
    } else {
      SameEpochFork
    }
  } else if incoming_epoch > current_epoch &&
    incoming_epoch - 1 == current_epoch {
    if parent_matches {
      Advance
    } else {
      ParentFork
    }
  } else if incoming_epoch > current_epoch {
    Gap
  } else {
    Stale
  }
  proof_assert checkpoint_head_decision_post(
    boundary_matches, epoch_known, known_digest_matches, current_epoch, incoming_epoch,
    parent_matches, decision,
  )
  decision
}

///|
pub fn CheckpointHeadDecision::is_fork(self : CheckpointHeadDecision) -> Bool {
  self == SameEpochFork || self == ParentFork
}

///|
pub fn CheckpointHeadDecision::advances(self : CheckpointHeadDecision) -> Bool {
  self == Advance
}
