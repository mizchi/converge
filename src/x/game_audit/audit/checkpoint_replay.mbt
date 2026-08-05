///|
/// Convert the typed replay boundary into the Boolean consumed by the small
/// checkpoint decision model. Both possession and exact checkpoint identity
/// are required; callers must not supply a free-standing success flag.
pub fn checkpoint_replay_capability_matches(
  capability_present~ : Bool,
  checkpoint_digest_matches~ : Bool,
  authority_key_matches~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    checkpoint_replay_capability_post(
      capability_present, checkpoint_digest_matches, authority_key_matches, result,
    )
  },
} {
  let result = capability_present &&
    checkpoint_digest_matches &&
    authority_key_matches
  proof_assert checkpoint_replay_capability_post(
    capability_present, checkpoint_digest_matches, authority_key_matches, result,
  )
  result
}
