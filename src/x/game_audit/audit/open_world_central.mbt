///|
/// Pure fail-closed model for elevating an open-world artifact to verified.
/// Runtime integration derives these facts from opaque capabilities and
/// cryptographic checks; callers never supply them over the network.
pub fn open_world_central_bundle_allowed(
  trusted_job_boundary_matches : Bool,
  audit_transparency_published : Bool,
  audit_plan_authenticated : Bool,
  seal_and_seed_authenticated : Bool,
  observer_registration_certified : Bool,
  encounter_eligible : Bool,
  encounter_replay_matches : Bool,
) -> Bool where {
  proof_ensure: result => {
    result ==
    open_world_central_bundle_post(
      trusted_job_boundary_matches, audit_transparency_published, audit_plan_authenticated,
      seal_and_seed_authenticated, observer_registration_certified, encounter_eligible,
      encounter_replay_matches,
    )
  },
} {
  let result = trusted_job_boundary_matches &&
    audit_transparency_published &&
    audit_plan_authenticated &&
    seal_and_seed_authenticated &&
    observer_registration_certified &&
    encounter_eligible &&
    encounter_replay_matches
  proof_assert result ==
    open_world_central_bundle_post(
      trusted_job_boundary_matches, audit_transparency_published, audit_plan_authenticated,
      seal_and_seed_authenticated, observer_registration_certified, encounter_eligible,
      encounter_replay_matches,
    )
  result
}
