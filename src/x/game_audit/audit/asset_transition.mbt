///|
/// Pure authorization boundary for one ownership transition.
pub fn transfer_transition_allowed(
  asset_exists~ : Bool,
  owner_matches~ : Bool,
  version_matches~ : Bool,
  recipient_valid~ : Bool,
  changes_owner~ : Bool,
  source_authenticated~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    transfer_transition_allowed_post(
      asset_exists, owner_matches, version_matches, recipient_valid, changes_owner,
      source_authenticated, result,
    )
  },
} {
  let result = asset_exists &&
    owner_matches &&
    version_matches &&
    recipient_valid &&
    changes_owner &&
    source_authenticated
  proof_assert transfer_transition_allowed_post(
    asset_exists, owner_matches, version_matches, recipient_valid, changes_owner,
    source_authenticated, result,
  )
  result
}
