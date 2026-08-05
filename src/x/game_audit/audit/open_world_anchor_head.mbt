///|
pub(all) enum OpenWorldSigningAnchorHeadDecision {
  AdvanceSigningAnchorHead
  DuplicateSigningAnchorHead
  DetectSameEpochSigningAnchorFork
  DetectSigningAnchorParentFork
  SigningAnchorHeadGap
  StaleSigningAnchorHead
  RejectSigningAnchorHeadBoundary
} derive(Eq, Debug)

///|
/// Classify one authenticated anchor-log head received from a peer.
pub fn classify_open_world_signing_anchor_head(
  boundary_matches~ : Bool,
  epoch_known~ : Bool,
  known_digest_matches~ : Bool,
  current_epoch~ : Int,
  incoming_epoch~ : Int,
  parent_matches~ : Bool,
) -> OpenWorldSigningAnchorHeadDecision where {
  proof_ensure: decision => {
    open_world_signing_anchor_head_post(
      boundary_matches, epoch_known, known_digest_matches, current_epoch, incoming_epoch,
      parent_matches, decision,
    )
  },
} {
  let decision = if !boundary_matches {
    OpenWorldSigningAnchorHeadDecision::RejectSigningAnchorHeadBoundary
  } else if epoch_known {
    if known_digest_matches {
      OpenWorldSigningAnchorHeadDecision::DuplicateSigningAnchorHead
    } else {
      OpenWorldSigningAnchorHeadDecision::DetectSameEpochSigningAnchorFork
    }
  } else if incoming_epoch > current_epoch &&
    incoming_epoch - 1 == current_epoch {
    if parent_matches {
      OpenWorldSigningAnchorHeadDecision::AdvanceSigningAnchorHead
    } else {
      OpenWorldSigningAnchorHeadDecision::DetectSigningAnchorParentFork
    }
  } else if incoming_epoch > current_epoch {
    OpenWorldSigningAnchorHeadDecision::SigningAnchorHeadGap
  } else {
    OpenWorldSigningAnchorHeadDecision::StaleSigningAnchorHead
  }
  proof_assert open_world_signing_anchor_head_post(
    boundary_matches, epoch_known, known_digest_matches, current_epoch, incoming_epoch,
    parent_matches, decision,
  )
  decision
}
