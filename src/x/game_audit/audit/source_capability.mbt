///|
/// Pure trust-boundary predicate for a source-event capability.
pub fn source_capability_matches(
  session_matches~ : Bool,
  digest_matches~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    source_capability_matches_post(session_matches, digest_matches, result)
  },
} {
  let result = session_matches && digest_matches
  proof_assert source_capability_matches_post(
    session_matches, digest_matches, result,
  )
  result
}
