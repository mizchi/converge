///|
fn votes(items : Array[Bool]) -> FixedArray[Bool] {
  FixedArray::from_array(items[:])
}

///|
test "quorum attests but does not finalize without authority" {
  let decision = decide_checkpoint(
    votes([true, true, true]),
    3,
    challenged=false,
    authority=AuthorityVerdict::NoVerdict,
    replay_matches=false,
  )
  debug_inspect(decision, content="Attested")
  assert_false(
    market_accepts(decision, item_included=true, rejected_ancestor=false),
  )
}

///|
test "authority replay finalizes when a participant signature is missing" {
  let decision = decide_checkpoint(
    votes([true, true, false]),
    3,
    challenged=false,
    authority=AuthorityVerdict::Accept,
    replay_matches=true,
  )
  debug_inspect(decision, content="Finalized")
  assert_true(
    market_accepts(decision, item_included=true, rejected_ancestor=false),
  )
}

///|
test "challenge requires matching replay before finalization" {
  let challenged = decide_checkpoint(
    votes([true, true, true]),
    3,
    challenged=true,
    authority=AuthorityVerdict::Accept,
    replay_matches=false,
  )
  debug_inspect(challenged, content="Challenged")
  let replayed = decide_checkpoint(
    votes([true, true, true]),
    3,
    challenged=true,
    authority=AuthorityVerdict::Accept,
    replay_matches=true,
  )
  debug_inspect(replayed, content="Finalized")
}

///|
test "rejected ancestry quarantines an otherwise finalized item" {
  assert_false(
    market_accepts(
      CheckpointDecision::Finalized,
      item_included=true,
      rejected_ancestor=true,
    ),
  )
}

///|
test "checkpoint decision is deterministic for identical evidence" {
  let evidence = votes([true, false, true, true])
  let left = decide_checkpoint(
    evidence,
    3,
    challenged=false,
    authority=AuthorityVerdict::Accept,
    replay_matches=false,
  )
  let right = decide_checkpoint(
    evidence,
    3,
    challenged=false,
    authority=AuthorityVerdict::Accept,
    replay_matches=false,
  )
  assert_eq(left, right)
  debug_inspect(left, content="Finalized")
}

///|
test "authority rejection rejects the checkpoint" {
  let decision = decide_checkpoint(
    votes([true, true, true]),
    3,
    challenged=false,
    authority=AuthorityVerdict::Reject,
    replay_matches=true,
  )
  debug_inspect(decision, content="Rejected")
}

///|
test "zero or out-of-range threshold never creates a participant quorum" {
  let empty = votes([])
  assert_eq(
    decide_checkpoint(
      empty,
      0,
      challenged=false,
      authority=AuthorityVerdict::NoVerdict,
      replay_matches=false,
    ),
    CheckpointDecision::Pending,
  )
  assert_eq(
    decide_checkpoint(
      votes([true]),
      2,
      challenged=false,
      authority=AuthorityVerdict::Accept,
      replay_matches=false,
    ),
    CheckpointDecision::Pending,
  )
  assert_eq(
    decide_checkpoint(
      empty,
      0,
      challenged=false,
      authority=AuthorityVerdict::Accept,
      replay_matches=true,
    ),
    CheckpointDecision::Finalized,
  )
}
