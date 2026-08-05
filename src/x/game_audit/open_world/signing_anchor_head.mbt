///|
/// Start tracking one anchor log from an authenticated publication capability.
pub fn OpenWorldObserverSigningAnchorHeadTracker::new(
  initial : PublishedOpenWorldObserverSigningAnchor,
) -> OpenWorldObserverSigningAnchorHeadTracker {
  let observed_checkpoints : Map[Int, @bft.Digest] = Map([])
  observed_checkpoints[initial.log_epoch] = initial.publication_checkpoint_digest
  OpenWorldObserverSigningAnchorHeadTracker::{
    log_session_id: initial.log_session_id,
    publisher_key: initial.publisher_key,
    current_epoch: initial.log_epoch,
    current_checkpoint_digest: initial.publication_checkpoint_digest,
    observed_checkpoints,
  }
}

///|
pub fn OpenWorldObserverSigningAnchorHeadTracker::current_epoch(
  self : OpenWorldObserverSigningAnchorHeadTracker,
) -> Int {
  self.current_epoch
}

///|
pub fn OpenWorldObserverSigningAnchorHeadTracker::current_checkpoint_digest(
  self : OpenWorldObserverSigningAnchorHeadTracker,
) -> @bft.Digest {
  self.current_checkpoint_digest
}

///|
pub fn OpenWorldObserverSigningAnchorHeadTracker::log_session_id(
  self : OpenWorldObserverSigningAnchorHeadTracker,
) -> String {
  self.log_session_id
}

///|
pub fn OpenWorldObserverSigningAnchorHeadTracker::publisher_key(
  self : OpenWorldObserverSigningAnchorHeadTracker,
) -> @bft.PublicKey {
  self.publisher_key
}

///|
pub fn OpenWorldObserverSigningAnchorHeadTracker::observed_checkpoint_count(
  self : OpenWorldObserverSigningAnchorHeadTracker,
) -> Int {
  self.observed_checkpoints.length()
}

///|
fn open_world_observer_signing_anchor_fork(
  kind : OpenWorldObserverSigningAnchorForkKind,
  tracker : OpenWorldObserverSigningAnchorHeadTracker,
  incoming : PublishedOpenWorldObserverSigningAnchor,
  accepted_epoch : Int,
  accepted_checkpoint_digest : @bft.Digest,
) -> OpenWorldObserverSigningAnchorFork {
  OpenWorldObserverSigningAnchorFork::{
    kind,
    log_session_id: tracker.log_session_id,
    publisher_key: tracker.publisher_key,
    accepted_epoch,
    accepted_checkpoint_digest,
    observed_epoch: incoming.log_epoch,
    conflicting_checkpoint_digest: incoming.publication_checkpoint_digest,
    conflicting_previous_checkpoint_digest: incoming.previous_checkpoint_digest,
  }
}

///|
/// Merge one peer-gossiped authenticated head without silently skipping gaps.
pub fn OpenWorldObserverSigningAnchorHeadTracker::deliver(
  self : OpenWorldObserverSigningAnchorHeadTracker,
  incoming : PublishedOpenWorldObserverSigningAnchor,
) -> OpenWorldObserverSigningAnchorHeadDelivery {
  let boundary_matches = incoming.log_session_id == self.log_session_id &&
    incoming.publisher_key == self.publisher_key
  let known = self.observed_checkpoints.get(incoming.log_epoch)
  let epoch_known = known is Some(_)
  let known_digest_matches = match known {
    Some(digest) => digest == incoming.publication_checkpoint_digest
    None => false
  }
  let parent_matches = incoming.previous_checkpoint_digest ==
    self.current_checkpoint_digest
  match
    @checkpoint_audit.classify_checkpoint_head(
      boundary_matches~,
      epoch_known~,
      known_digest_matches~,
      current_epoch=self.current_epoch,
      incoming_epoch=incoming.log_epoch,
      parent_matches~,
    ) {
    @checkpoint_audit.CheckpointHeadDecision::BoundaryMismatch =>
      SigningAnchorHeadBoundaryMismatch
    @checkpoint_audit.CheckpointHeadDecision::Duplicate =>
      SigningAnchorHeadDuplicate
    @checkpoint_audit.CheckpointHeadDecision::SameEpochFork =>
      match known {
        Some(accepted_digest) =>
          SigningAnchorHeadForkDetected(
            open_world_observer_signing_anchor_fork(
              SameEpochSigningAnchorCheckpoint,
              self,
              incoming,
              incoming.log_epoch,
              accepted_digest,
            ),
          )
        None => SigningAnchorHeadStale
      }
    @checkpoint_audit.CheckpointHeadDecision::ParentFork =>
      SigningAnchorHeadForkDetected(
        open_world_observer_signing_anchor_fork(
          WrongParentSigningAnchorCheckpoint,
          self,
          incoming,
          self.current_epoch,
          self.current_checkpoint_digest,
        ),
      )
    @checkpoint_audit.CheckpointHeadDecision::Advance => {
      self.observed_checkpoints[incoming.log_epoch] = incoming.publication_checkpoint_digest
      self.current_epoch = incoming.log_epoch
      self.current_checkpoint_digest = incoming.publication_checkpoint_digest
      SigningAnchorHeadAdvanced
    }
    @checkpoint_audit.CheckpointHeadDecision::Gap =>
      SigningAnchorHeadGap(self.current_epoch + 1, incoming.log_epoch)
    @checkpoint_audit.CheckpointHeadDecision::Stale => SigningAnchorHeadStale
  }
}

///|
/// Validate every fetched head first, then atomically commit all advances.
pub fn OpenWorldObserverSigningAnchorHeadTracker::deliver_batch(
  self : OpenWorldObserverSigningAnchorHeadTracker,
  incoming_heads : Array[PublishedOpenWorldObserverSigningAnchor],
) -> OpenWorldObserverSigningAnchorHeadBatchDelivery {
  let planned_checkpoints : Map[Int, @bft.Digest] = Map([])
  let mut planned_epoch = self.current_epoch
  let mut planned_digest = self.current_checkpoint_digest
  let mut planned_count = 0
  for index, incoming in incoming_heads {
    let boundary_matches = incoming.log_session_id == self.log_session_id &&
      incoming.publisher_key == self.publisher_key
    let known = match self.observed_checkpoints.get(incoming.log_epoch) {
      Some(digest) => Some(digest)
      None => planned_checkpoints.get(incoming.log_epoch)
    }
    let epoch_known = known is Some(_)
    let known_digest_matches = match known {
      Some(digest) => digest == incoming.publication_checkpoint_digest
      None => false
    }
    let parent_matches = incoming.previous_checkpoint_digest == planned_digest
    match
      @checkpoint_audit.classify_checkpoint_head(
        boundary_matches~,
        epoch_known~,
        known_digest_matches~,
        current_epoch=planned_epoch,
        incoming_epoch=incoming.log_epoch,
        parent_matches~,
      ) {
      @checkpoint_audit.CheckpointHeadDecision::BoundaryMismatch =>
        return SigningAnchorHeadBatchBoundaryMismatch(index)
      @checkpoint_audit.CheckpointHeadDecision::Duplicate => ()
      @checkpoint_audit.CheckpointHeadDecision::SameEpochFork =>
        match known {
          Some(accepted_digest) =>
            return SigningAnchorHeadBatchForkDetected(
              index,
              open_world_observer_signing_anchor_fork(
                SameEpochSigningAnchorCheckpoint,
                self,
                incoming,
                incoming.log_epoch,
                accepted_digest,
              ),
            )
          None => return SigningAnchorHeadBatchStale(index, incoming.log_epoch)
        }
      @checkpoint_audit.CheckpointHeadDecision::ParentFork =>
        return SigningAnchorHeadBatchForkDetected(
          index,
          open_world_observer_signing_anchor_fork(
            WrongParentSigningAnchorCheckpoint,
            self,
            incoming,
            planned_epoch,
            planned_digest,
          ),
        )
      @checkpoint_audit.CheckpointHeadDecision::Advance => {
        planned_checkpoints[incoming.log_epoch] = incoming.publication_checkpoint_digest
        planned_epoch = incoming.log_epoch
        planned_digest = incoming.publication_checkpoint_digest
        planned_count += 1
      }
      @checkpoint_audit.CheckpointHeadDecision::Gap =>
        return SigningAnchorHeadBatchGap(
          index,
          planned_epoch + 1,
          incoming.log_epoch,
        )
      @checkpoint_audit.CheckpointHeadDecision::Stale =>
        return SigningAnchorHeadBatchStale(index, incoming.log_epoch)
    }
  }
  if planned_count == 0 {
    return SigningAnchorHeadBatchNoChange
  }
  for epoch, digest in planned_checkpoints {
    self.observed_checkpoints[epoch] = digest
  }
  self.current_epoch = planned_epoch
  self.current_checkpoint_digest = planned_digest
  SigningAnchorHeadBatchAdvanced(planned_count)
}

///|
pub fn OpenWorldObserverSigningAnchorFork::kind(
  self : OpenWorldObserverSigningAnchorFork,
) -> OpenWorldObserverSigningAnchorForkKind {
  self.kind
}

///|
pub fn OpenWorldObserverSigningAnchorFork::log_session_id(
  self : OpenWorldObserverSigningAnchorFork,
) -> String {
  self.log_session_id
}

///|
pub fn OpenWorldObserverSigningAnchorFork::publisher_key(
  self : OpenWorldObserverSigningAnchorFork,
) -> @bft.PublicKey {
  self.publisher_key
}

///|
pub fn OpenWorldObserverSigningAnchorFork::accepted_epoch(
  self : OpenWorldObserverSigningAnchorFork,
) -> Int {
  self.accepted_epoch
}

///|
pub fn OpenWorldObserverSigningAnchorFork::accepted_checkpoint_digest(
  self : OpenWorldObserverSigningAnchorFork,
) -> @bft.Digest {
  self.accepted_checkpoint_digest
}

///|
pub fn OpenWorldObserverSigningAnchorFork::observed_epoch(
  self : OpenWorldObserverSigningAnchorFork,
) -> Int {
  self.observed_epoch
}

///|
pub fn OpenWorldObserverSigningAnchorFork::conflicting_checkpoint_digest(
  self : OpenWorldObserverSigningAnchorFork,
) -> @bft.Digest {
  self.conflicting_checkpoint_digest
}

///|
pub fn OpenWorldObserverSigningAnchorFork::conflicting_previous_checkpoint_digest(
  self : OpenWorldObserverSigningAnchorFork,
) -> @bft.Digest {
  self.conflicting_previous_checkpoint_digest
}
