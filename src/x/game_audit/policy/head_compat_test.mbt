///|
fn generic_head_code(decision : @audit.CheckpointHeadDecision) -> Int {
  match decision {
    Advance => 0
    Duplicate => 1
    SameEpochFork => 2
    ParentFork => 3
    Gap => 4
    Stale => 5
    BoundaryMismatch => 6
  }
}

///|
fn game_head_code(
  decision : @game_audit.OpenWorldSigningAnchorHeadDecision,
) -> Int {
  match decision {
    AdvanceSigningAnchorHead => 0
    DuplicateSigningAnchorHead => 1
    DetectSameEpochSigningAnchorFork => 2
    DetectSigningAnchorParentFork => 3
    SigningAnchorHeadGap => 4
    StaleSigningAnchorHead => 5
    RejectSigningAnchorHeadBoundary => 6
  }
}

///|
test "game compatibility spec is extensionally equal to generic head policy" {
  let booleans = [false, true]
  for boundary_matches in booleans {
    for epoch_known in booleans {
      for known_digest_matches in booleans {
        for parent_matches in booleans {
          for current_epoch in -2..<3 {
            for incoming_epoch in -2..<3 {
              let generic = @audit.classify_checkpoint_head(
                boundary_matches~,
                epoch_known~,
                known_digest_matches~,
                current_epoch~,
                incoming_epoch~,
                parent_matches~,
              )
              let game = @game_audit.classify_open_world_signing_anchor_head(
                boundary_matches~,
                epoch_known~,
                known_digest_matches~,
                current_epoch~,
                incoming_epoch~,
                parent_matches~,
              )
              assert_eq(generic_head_code(generic), game_head_code(game))
            }
          }
        }
      }
    }
  }
}
