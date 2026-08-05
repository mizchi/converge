///|
struct ExampleGameCheckpoint {
  scope : String
  epoch : Int
}

///|
impl CheckpointAdapter for ExampleGameCheckpoint with fn checkpoint_commitment(
  self : ExampleGameCheckpoint,
) -> CheckpointCommitment {
  {
    scope_id: self.scope,
    epoch: self.epoch,
    previous_checkpoint: AuditDigest("parent"),
    manifest_digest: AuditDigest("manifest"),
    event_root: AuditDigest("events"),
    state_root: AuditDigest("state"),
    effect_root: AuditDigest("effects"),
    sealed_state_commitment: None,
  }
}

///|
test "a game supplies semantics through the generic checkpoint adapter" {
  let adapted = adapt_checkpoint(ExampleGameCheckpoint::{
    scope: "match-7",
    epoch: 3,
  })
  debug_inspect(
    adapted.scope_id,
    content=(
      #|"match-7"
    ),
  )
  debug_inspect(adapted.epoch, content="3")
  debug_inspect(adapted.effect_root, content="AuditDigest(\"effects\")")
}
