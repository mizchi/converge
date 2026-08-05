///|
fn example_policy() -> CheckpointPolicy {
  {
    event_interval_ms: 20,
    micro_checkpoint_interval_ms: 200,
    macro_checkpoint_interval_ms: 15000,
    event_retention_ms: 30000,
    micro_checkpoint_retention_ms: 120000,
    macro_checkpoint_retention_ms: 600000,
  }
}

///|
fn verified_example_policy() -> VerifiedCheckpointPolicy {
  match open_checkpoint_policy(example_policy()) {
    Opened(policy) => policy
    Refused(_) => abort("expected valid checkpoint policy")
  }
}

///|
test "checkpoint policy opens only when intervals and retention are nested" {
  let policy = verified_example_policy()
  debug_inspect(
    policy.policy(),
    content=(
      #|{
      #|  event_interval_ms: 20,
      #|  micro_checkpoint_interval_ms: 200,
      #|  macro_checkpoint_interval_ms: 15000,
      #|  event_retention_ms: 30000,
      #|  micro_checkpoint_retention_ms: 120000,
      #|  macro_checkpoint_retention_ms: 600000,
      #|}
    ),
  )
  debug_inspect(event_leaves_per_micro_checkpoint(policy), content="10")
  debug_inspect(micro_checkpoints_per_macro_checkpoint(policy), content="75")
  debug_inspect(event_leaves_per_macro_checkpoint(policy), content="750")
  debug_inspect(dispute_bisection_rounds(policy), content="10")
}

///|
test "checkpoint policy validation fails closed at the first broken boundary" {
  debug_inspect(
    open_checkpoint_policy({ ..example_policy(), event_interval_ms: 0 }),
    content="Refused(NonPositiveEventInterval)",
  )
  debug_inspect(
    open_checkpoint_policy({
      ..example_policy(),
      micro_checkpoint_interval_ms: 19,
    }),
    content="Refused(MicroCheckpointBeforeEvent)",
  )
  debug_inspect(
    open_checkpoint_policy({
      ..example_policy(),
      macro_checkpoint_interval_ms: 199,
    }),
    content="Refused(MacroCheckpointBeforeMicro)",
  )
  debug_inspect(
    open_checkpoint_policy({ ..example_policy(), event_retention_ms: 14999 }),
    content="Refused(EventRetentionBeforeMacroCheckpoint)",
  )
  debug_inspect(
    open_checkpoint_policy({
      ..example_policy(),
      micro_checkpoint_retention_ms: 29999,
    }),
    content="Refused(MicroRetentionBeforeEventRetention)",
  )
  debug_inspect(
    open_checkpoint_policy({
      ..example_policy(),
      macro_checkpoint_retention_ms: 119999,
    }),
    content="Refused(MacroRetentionBeforeMicroRetention)",
  )
}

///|
test "retained evidence degrades localization without changing server cadence" {
  let policy = verified_example_policy()
  debug_inspect(evidence_level_at_age(policy, -1), content="EvidenceExpired")
  debug_inspect(evidence_level_at_age(policy, 30000), content="EventLeaves")
  debug_inspect(
    evidence_level_at_age(policy, 30001),
    content="MicroCheckpointRoots",
  )
  debug_inspect(
    evidence_level_at_age(policy, 120001),
    content="MacroCheckpointRoots",
  )
  debug_inspect(
    evidence_level_at_age(policy, 600001),
    content="EvidenceExpired",
  )
  debug_inspect(localization_precision_ms(policy, 30000), content="Some(20)")
  debug_inspect(localization_precision_ms(policy, 30001), content="Some(200)")
  debug_inspect(
    localization_precision_ms(policy, 120001),
    content="Some(15000)",
  )
  debug_inspect(localization_precision_ms(policy, 600001), content="None")
}

///|
test "finality estimate separates checkpoint cadence from validation latency" {
  let policy = verified_example_policy()
  debug_inspect(
    estimate_finality(policy, mean_validation_ms=100, p99_validation_ms=244),
    content=(
      #|Some({ average_ms: 7600, p99_upper_ms: 15244 })
    ),
  )
  debug_inspect(
    estimate_finality(policy, mean_validation_ms=-1, p99_validation_ms=244),
    content="None",
  )
  debug_inspect(
    estimate_finality(policy, mean_validation_ms=245, p99_validation_ms=244),
    content="None",
  )
}

///|
test "generic head classifier separates advance duplicate fork gap and stale" {
  debug_inspect(
    classify_checkpoint_head(
      boundary_matches=true,
      epoch_known=false,
      known_digest_matches=false,
      current_epoch=10,
      incoming_epoch=11,
      parent_matches=true,
    ),
    content="Advance",
  )
  debug_inspect(
    classify_checkpoint_head(
      boundary_matches=true,
      epoch_known=true,
      known_digest_matches=true,
      current_epoch=10,
      incoming_epoch=10,
      parent_matches=false,
    ),
    content="Duplicate",
  )
  debug_inspect(
    classify_checkpoint_head(
      boundary_matches=true,
      epoch_known=true,
      known_digest_matches=false,
      current_epoch=10,
      incoming_epoch=10,
      parent_matches=true,
    ),
    content="SameEpochFork",
  )
  debug_inspect(
    classify_checkpoint_head(
      boundary_matches=true,
      epoch_known=false,
      known_digest_matches=false,
      current_epoch=10,
      incoming_epoch=11,
      parent_matches=false,
    ),
    content="ParentFork",
  )
  debug_inspect(
    classify_checkpoint_head(
      boundary_matches=true,
      epoch_known=false,
      known_digest_matches=false,
      current_epoch=10,
      incoming_epoch=13,
      parent_matches=false,
    ),
    content="Gap",
  )
  debug_inspect(
    classify_checkpoint_head(
      boundary_matches=true,
      epoch_known=false,
      known_digest_matches=false,
      current_epoch=10,
      incoming_epoch=9,
      parent_matches=false,
    ),
    content="Stale",
  )
  debug_inspect(
    classify_checkpoint_head(
      boundary_matches=false,
      epoch_known=true,
      known_digest_matches=false,
      current_epoch=10,
      incoming_epoch=10,
      parent_matches=false,
    ),
    content="BoundaryMismatch",
  )
}

///|
test "audit event time accepts only the current watermark or future" {
  debug_inspect(
    classify_audit_event_time(origin_ms=100, watermark_ms=99, event_time_ms=100),
    content="InvalidAuditWatermark",
  )
  debug_inspect(
    classify_audit_event_time(origin_ms=100, watermark_ms=100, event_time_ms=99),
    content="AuditEventBeforeOrigin",
  )
  debug_inspect(
    classify_audit_event_time(
      origin_ms=100,
      watermark_ms=150,
      event_time_ms=149,
    ),
    content="AuditEventBehindWatermark",
  )
  debug_inspect(
    classify_audit_event_time(
      origin_ms=100,
      watermark_ms=150,
      event_time_ms=150,
    ),
    content="AuditEventTimeAccepted",
  )
  debug_inspect(
    classify_audit_event_time(
      origin_ms=100,
      watermark_ms=150,
      event_time_ms=151,
    ),
    content="AuditEventTimeAccepted",
  )
}
