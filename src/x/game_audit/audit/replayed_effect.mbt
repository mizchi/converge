///|
/// Pure authorization boundary for minting a replayed asset-effect capability.
pub fn replayed_effect_allowed(
  source_authenticated~ : Bool,
  session_matches~ : Bool,
  effect_valid~ : Bool,
  manifest_present~ : Bool,
  kernel_accepted~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    replayed_effect_allowed_post(
      source_authenticated, session_matches, effect_valid, manifest_present, kernel_accepted,
      result,
    )
  },
} {
  let result = source_authenticated &&
    session_matches &&
    effect_valid &&
    manifest_present &&
    kernel_accepted
  proof_assert replayed_effect_allowed_post(
    source_authenticated, session_matches, effect_valid, manifest_present, kernel_accepted,
    result,
  )
  result
}
