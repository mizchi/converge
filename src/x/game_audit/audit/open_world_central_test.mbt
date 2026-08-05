///|
test "open-world central bundle gate requires every capability" {
  assert_true(
    open_world_central_bundle_allowed(true, true, true, true, true, true, true),
  )
  assert_false(
    open_world_central_bundle_allowed(false, true, true, true, true, true, true),
  )
  assert_false(
    open_world_central_bundle_allowed(true, false, true, true, true, true, true),
  )
  assert_false(
    open_world_central_bundle_allowed(true, true, true, true, true, false, true),
  )
  assert_false(
    open_world_central_bundle_allowed(true, true, true, true, true, true, false),
  )
}
