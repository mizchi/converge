///|
/// Pure fail-closed policy for replacing a Durable Object's per-asset
/// inventory head. Idempotent reads are handled separately and cannot mutate
/// this head.
pub fn inventory_head_advance_allowed(
  creation_eligible~ : Bool,
  proof_verified~ : Bool,
  manifest_matches~ : Bool,
  parent_matches~ : Bool,
  epoch_advances~ : Bool,
  owner_version_consistent~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    inventory_head_advance_post(
      creation_eligible, proof_verified, manifest_matches, parent_matches, epoch_advances,
      owner_version_consistent, result,
    )
  },
} {
  let result = creation_eligible &&
    proof_verified &&
    manifest_matches &&
    parent_matches &&
    epoch_advances &&
    owner_version_consistent
  proof_assert inventory_head_advance_post(
    creation_eligible, proof_verified, manifest_matches, parent_matches, epoch_advances,
    owner_version_consistent, result,
  )
  result
}
