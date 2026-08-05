///|
test "source capability requires both session and digest binding" {
  assert_true(
    source_capability_matches(session_matches=true, digest_matches=true),
  )
  assert_false(
    source_capability_matches(session_matches=false, digest_matches=true),
  )
  assert_false(
    source_capability_matches(session_matches=true, digest_matches=false),
  )
  assert_false(
    source_capability_matches(session_matches=false, digest_matches=false),
  )
}
