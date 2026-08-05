///|
/// Pure fail-closed model for publishing one audit plan and its seal through
/// an independently signed transparency checkpoint.
pub fn open_world_audit_transparency_allowed(
  trusted_publication_boundary~ : Bool,
  audit_checkpoint_authenticated~ : Bool,
  seal_checkpoint_authenticated~ : Bool,
  transparency_manifest_matches~ : Bool,
  audit_membership_valid~ : Bool,
  seal_membership_valid~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    result ==
    open_world_audit_transparency_post(
      trusted_publication_boundary, audit_checkpoint_authenticated, seal_checkpoint_authenticated,
      transparency_manifest_matches, audit_membership_valid, seal_membership_valid,
    )
  },
} {
  let result = trusted_publication_boundary &&
    audit_checkpoint_authenticated &&
    seal_checkpoint_authenticated &&
    transparency_manifest_matches &&
    audit_membership_valid &&
    seal_membership_valid
  proof_assert result ==
    open_world_audit_transparency_post(
      trusted_publication_boundary, audit_checkpoint_authenticated, seal_checkpoint_authenticated,
      transparency_manifest_matches, audit_membership_valid, seal_membership_valid,
    )
  result
}
