///|
test "replay witness quorum tolerates the declared Byzantine fault bound" {
  assert_true(replay_witness_policy_valid(4, 1))
  assert_eq(replay_witness_quorum_size(4, 1), 3)
  assert_true(
    replay_witness_certificate_allowed(
      witness_count=4,
      max_faults=1,
      approval_count=3,
    ),
  )
  assert_false(
    replay_witness_certificate_allowed(
      witness_count=4,
      max_faults=1,
      approval_count=2,
    ),
  )
}

///|
test "invalid replay witness policies fail closed" {
  assert_false(replay_witness_policy_valid(3, 1))
  assert_false(replay_witness_policy_valid(4, -1))
  assert_false(replay_witness_policy_valid(0, 0))
  assert_false(
    replay_witness_certificate_allowed(
      witness_count=3,
      max_faults=1,
      approval_count=3,
    ),
  )
}

///|
test "non-minimal valid rosters use n minus f approvals" {
  assert_true(replay_witness_policy_valid(8, 2))
  assert_eq(replay_witness_quorum_size(8, 2), 6)
}
