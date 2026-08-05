///|
/// Opaque content digest at the generic audit boundary. Crypto adapters own
/// the conversion to and from their concrete digest representation.
pub(all) struct AuditDigest(String) derive(Eq, Compare, Hash, Debug)

///|
/// Game-neutral view of a checkpoint commitment.
///
/// The application owns event decoding and replay semantics. Converge only
/// needs this stable projection to bind a scope and epoch to deterministic
/// manifest, event, state, and effect roots.
pub(all) struct CheckpointCommitment {
  scope_id : String
  epoch : Int
  previous_checkpoint : AuditDigest
  manifest_digest : AuditDigest
  event_root : AuditDigest
  state_root : AuditDigest
  effect_root : AuditDigest
  sealed_state_commitment : AuditDigest?
} derive(Eq, Debug)

///|
/// Adapter implemented by an application-specific checkpoint type.
pub(open) trait CheckpointAdapter {
  fn checkpoint_commitment(Self) -> CheckpointCommitment
}

///|
/// Erase the application-specific checkpoint representation at the contract
/// boundary.
pub fn adapt_checkpoint(adapter : &CheckpointAdapter) -> CheckpointCommitment {
  adapter.checkpoint_commitment()
}
