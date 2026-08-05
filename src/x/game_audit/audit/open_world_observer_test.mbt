///|
test "open-world observer quorum tolerates the declared Byzantine bound" {
  assert_true(open_world_observer_policy_valid(4, 1))
  assert_eq(open_world_observer_quorum_size(4, 1), 3)
  assert_true(
    open_world_observer_certificate_allowed(
      observer_count=4,
      max_faults=1,
      approval_count=3,
    ),
  )
  assert_false(
    open_world_observer_certificate_allowed(
      observer_count=4,
      max_faults=1,
      approval_count=2,
    ),
  )
}

///|
test "invalid open-world observer policies fail closed" {
  assert_false(open_world_observer_policy_valid(3, 1))
  assert_false(open_world_observer_policy_valid(4, -1))
  assert_false(open_world_observer_policy_valid(0, 0))
  assert_false(
    open_world_observer_certificate_allowed(
      observer_count=3,
      max_faults=1,
      approval_count=3,
    ),
  )
}

///|
test "non-minimal observer rosters use n minus f approvals" {
  assert_true(open_world_observer_policy_valid(8, 2))
  assert_eq(open_world_observer_quorum_size(8, 2), 6)
}
