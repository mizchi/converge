///|
/// Pure fail-closed gate at the Worker persistence boundary. A replay summary
/// may become durable marketplace creation evidence only for the open-world
/// artifact class and only when every independently checked binding holds.
pub fn marketplace_creation_persist_allowed(
  open_world_boundary~ : Bool,
  central_replay_verified~ : Bool,
  summary_normalized~ : Bool,
  checkpoint_bound~ : Bool,
  conflict_free~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    marketplace_creation_persist_post(
      open_world_boundary, central_replay_verified, summary_normalized, checkpoint_bound,
      conflict_free, result,
    )
  },
} {
  let result = open_world_boundary &&
    central_replay_verified &&
    summary_normalized &&
    checkpoint_bound &&
    conflict_free
  proof_assert marketplace_creation_persist_post(
    open_world_boundary, central_replay_verified, summary_normalized, checkpoint_bound,
    conflict_free, result,
  )
  result
}
