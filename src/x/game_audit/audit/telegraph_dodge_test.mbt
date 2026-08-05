///|
test "telegraphed dodge gate requires every trust boundary" {
  assert_true(
    telegraph_dodge_allowed(
      telegraph_valid=true,
      player_evidence_valid=true,
      causally_bound=true,
      reaction_window=true,
      receipt_bound=true,
      movement_legal=true,
    ),
  )
  let rejected = [
    (false, true, true, true, true, true),
    (true, false, true, true, true, true),
    (true, true, false, true, true, true),
    (true, true, true, false, true, true),
    (true, true, true, true, false, true),
    (true, true, true, true, true, false),
  ]
  for conditions in rejected {
    assert_false(
      telegraph_dodge_allowed(
        telegraph_valid=conditions.0,
        player_evidence_valid=conditions.1,
        causally_bound=conditions.2,
        reaction_window=conditions.3,
        receipt_bound=conditions.4,
        movement_legal=conditions.5,
      ),
    )
  }
}

///|
test "integer tick helpers enforce reaction and receipt boundaries" {
  assert_true(dodge_reaction_window_allowed(10, 16, 2, 12))
  assert_true(dodge_reaction_window_allowed(10, 16, 2, 15))
  assert_false(dodge_reaction_window_allowed(10, 16, 2, 11))
  assert_false(dodge_reaction_window_allowed(10, 16, 2, 16))
  assert_false(dodge_reaction_window_allowed(10, 16, -1, 12))
  assert_true(dodge_receipt_bound_allowed(13, 15, 2))
  assert_false(dodge_receipt_bound_allowed(13, 12, 2))
  assert_false(dodge_receipt_bound_allowed(13, 16, 2))
  assert_false(dodge_receipt_bound_allowed(13, 13, -1))
}
