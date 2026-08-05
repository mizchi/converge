///|
/// Game-specific policy presets. These names and numbers are intentionally
/// outside converge's generic audit package.
pub(all) enum GameAuditMode {
  CooperativePve
  AdversarialPvp
  OpenWorldEncounter
} derive(Eq, Debug)

///|
/// Return the application-owned numbers for one game mode. The event interval
/// is an audit-log slot, not a rendering or simulation frame rate.
pub fn raw_checkpoint_policy_for_mode(
  mode : GameAuditMode,
) -> @audit.CheckpointPolicy {
  match mode {
    AdversarialPvp =>
      {
        event_interval_ms: 16,
        micro_checkpoint_interval_ms: 250,
        macro_checkpoint_interval_ms: 2000,
        event_retention_ms: 60000,
        micro_checkpoint_retention_ms: 300000,
        macro_checkpoint_retention_ms: 86400000,
      }
    CooperativePve =>
      {
        event_interval_ms: 33,
        micro_checkpoint_interval_ms: 1000,
        macro_checkpoint_interval_ms: 15000,
        event_retention_ms: 120000,
        micro_checkpoint_retention_ms: 600000,
        macro_checkpoint_retention_ms: 86400000,
      }
    OpenWorldEncounter =>
      {
        event_interval_ms: 50,
        micro_checkpoint_interval_ms: 2000,
        macro_checkpoint_interval_ms: 30000,
        event_retention_ms: 300000,
        micro_checkpoint_retention_ms: 3600000,
        macro_checkpoint_retention_ms: 604800000,
      }
  }
}

///|
/// Open a game preset through the same fail-closed capability gate available
/// to non-game converge users.
pub fn checkpoint_policy_for_mode(
  mode : GameAuditMode,
) -> @audit.CheckpointPolicyOpenResult {
  @audit.open_checkpoint_policy(raw_checkpoint_policy_for_mode(mode))
}
