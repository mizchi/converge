///|
/// Scheduling and retention contract for a layered audit log.
///
/// Event leaves provide the finest dispute resolution. Peer-facing micro
/// checkpoints summarize those leaves, and server-facing macro checkpoints
/// summarize the micro roots. Retention is independently tiered so old data can
/// degrade from event-level replay to root-level evidence without changing the
/// live checkpoint cadence.
pub(all) struct CheckpointPolicy {
  event_interval_ms : Int
  micro_checkpoint_interval_ms : Int
  macro_checkpoint_interval_ms : Int
  event_retention_ms : Int
  micro_checkpoint_retention_ms : Int
  macro_checkpoint_retention_ms : Int
} derive(Eq, Debug)

///|
/// First invalid boundary found while opening a checkpoint policy.
pub(all) enum CheckpointPolicyError {
  NonPositiveEventInterval
  MicroCheckpointBeforeEvent
  MacroCheckpointBeforeMicro
  EventRetentionBeforeMacroCheckpoint
  MicroRetentionBeforeEventRetention
  MacroRetentionBeforeMicroRetention
} derive(Eq, Debug)

///|
/// Capability proving that all interval and retention tiers are nested.
pub struct VerifiedCheckpointPolicy {
  value : CheckpointPolicy
} derive(Eq, Debug)

///|
pub(all) enum CheckpointPolicyOpenResult {
  Opened(VerifiedCheckpointPolicy)
  Refused(CheckpointPolicyError)
} derive(Eq, Debug)

///|
/// Best evidence still retained for an event of a given age.
pub(all) enum RetainedEvidenceLevel {
  EventLeaves
  MicroCheckpointRoots
  MacroCheckpointRoots
  EvidenceExpired
} derive(Eq, Debug)

///|
/// Latency projection. `average_ms` assumes events are uniformly distributed
/// inside a macro interval. `p99_upper_ms` is the full macro interval plus the
/// supplied p99 validation latency; it is an engineering bound, not an SLA.
pub(all) struct FinalityEstimate {
  average_ms : Int
  p99_upper_ms : Int
} derive(Eq, Debug)

///|
/// Validate a raw policy and mint a capability only for nested, positive
/// intervals and monotonically increasing retention tiers.
pub fn open_checkpoint_policy(
  policy : CheckpointPolicy,
) -> CheckpointPolicyOpenResult {
  let valid = checkpoint_policy_fields_valid(
    policy.event_interval_ms,
    policy.micro_checkpoint_interval_ms,
    policy.macro_checkpoint_interval_ms,
    policy.event_retention_ms,
    policy.micro_checkpoint_retention_ms,
    policy.macro_checkpoint_retention_ms,
  )
  if valid {
    return Opened(VerifiedCheckpointPolicy::{ value: policy })
  }
  if policy.event_interval_ms <= 0 {
    CheckpointPolicyOpenResult::Refused(NonPositiveEventInterval)
  } else if policy.micro_checkpoint_interval_ms < policy.event_interval_ms {
    CheckpointPolicyOpenResult::Refused(MicroCheckpointBeforeEvent)
  } else if policy.macro_checkpoint_interval_ms <
    policy.micro_checkpoint_interval_ms {
    CheckpointPolicyOpenResult::Refused(MacroCheckpointBeforeMicro)
  } else if policy.event_retention_ms < policy.macro_checkpoint_interval_ms {
    CheckpointPolicyOpenResult::Refused(EventRetentionBeforeMacroCheckpoint)
  } else if policy.micro_checkpoint_retention_ms < policy.event_retention_ms {
    CheckpointPolicyOpenResult::Refused(MicroRetentionBeforeEventRetention)
  } else if policy.macro_checkpoint_retention_ms <
    policy.micro_checkpoint_retention_ms {
    CheckpointPolicyOpenResult::Refused(MacroRetentionBeforeMicroRetention)
  } else {
    abort("checkpoint policy validator and refusal classifier diverged")
  }
}

///|
/// Primitive policy predicate shared by the runtime capability gate and the
/// proof model.
fn checkpoint_policy_fields_valid(
  event_interval_ms : Int,
  micro_checkpoint_interval_ms : Int,
  macro_checkpoint_interval_ms : Int,
  event_retention_ms : Int,
  micro_checkpoint_retention_ms : Int,
  macro_checkpoint_retention_ms : Int,
) -> Bool where {
  proof_ensure: result => {
    checkpoint_policy_fields_valid_post(
      event_interval_ms, micro_checkpoint_interval_ms, macro_checkpoint_interval_ms,
      event_retention_ms, micro_checkpoint_retention_ms, macro_checkpoint_retention_ms,
      result,
    )
  },
} {
  let result = event_interval_ms > 0 &&
    micro_checkpoint_interval_ms >= event_interval_ms &&
    macro_checkpoint_interval_ms >= micro_checkpoint_interval_ms &&
    event_retention_ms >= macro_checkpoint_interval_ms &&
    micro_checkpoint_retention_ms >= event_retention_ms &&
    macro_checkpoint_retention_ms >= micro_checkpoint_retention_ms
  proof_assert checkpoint_policy_fields_valid_post(
    event_interval_ms, micro_checkpoint_interval_ms, macro_checkpoint_interval_ms,
    event_retention_ms, micro_checkpoint_retention_ms, macro_checkpoint_retention_ms,
    result,
  )
  result
}

///|
pub fn VerifiedCheckpointPolicy::policy(
  self : VerifiedCheckpointPolicy,
) -> CheckpointPolicy {
  self.value
}

///|
fn positive_ceil_div(numerator : Int, denominator : Int) -> Int {
  let quotient = numerator / denominator
  if numerator % denominator == 0 {
    quotient
  } else {
    quotient + 1
  }
}

///|
pub fn event_leaves_per_micro_checkpoint(
  policy : VerifiedCheckpointPolicy,
) -> Int {
  positive_ceil_div(
    policy.value.micro_checkpoint_interval_ms,
    policy.value.event_interval_ms,
  )
}

///|
pub fn micro_checkpoints_per_macro_checkpoint(
  policy : VerifiedCheckpointPolicy,
) -> Int {
  positive_ceil_div(
    policy.value.macro_checkpoint_interval_ms,
    policy.value.micro_checkpoint_interval_ms,
  )
}

///|
pub fn event_leaves_per_macro_checkpoint(
  policy : VerifiedCheckpointPolicy,
) -> Int {
  positive_ceil_div(
    policy.value.macro_checkpoint_interval_ms,
    policy.value.event_interval_ms,
  )
}

///|
/// Number of binary Merkle descent rounds required to isolate one event leaf
/// inside a macro interval.
pub fn dispute_bisection_rounds(policy : VerifiedCheckpointPolicy) -> Int {
  for leaves = event_leaves_per_macro_checkpoint(policy), rounds = 0; leaves > 1; {
    continue positive_ceil_div(leaves, 2), rounds + 1
  } nobreak {
    rounds
  }
}

///|
pub fn evidence_level_at_age(
  policy : VerifiedCheckpointPolicy,
  age_ms : Int,
) -> RetainedEvidenceLevel {
  if age_ms < 0 {
    EvidenceExpired
  } else if age_ms <= policy.value.event_retention_ms {
    EventLeaves
  } else if age_ms <= policy.value.micro_checkpoint_retention_ms {
    MicroCheckpointRoots
  } else if age_ms <= policy.value.macro_checkpoint_retention_ms {
    MacroCheckpointRoots
  } else {
    EvidenceExpired
  }
}

///|
/// Primitive localization model. `-1` means that no evidence is retained.
fn retained_localization_precision_ms(
  event_interval_ms : Int,
  micro_checkpoint_interval_ms : Int,
  macro_checkpoint_interval_ms : Int,
  event_retention_ms : Int,
  micro_checkpoint_retention_ms : Int,
  macro_checkpoint_retention_ms : Int,
  age_ms : Int,
) -> Int where {
  proof_ensure: result => {
    retained_localization_precision_post(
      event_interval_ms, micro_checkpoint_interval_ms, macro_checkpoint_interval_ms,
      event_retention_ms, micro_checkpoint_retention_ms, macro_checkpoint_retention_ms,
      age_ms, result,
    )
  },
} {
  let result = if age_ms < 0 {
    -1
  } else if age_ms <= event_retention_ms {
    event_interval_ms
  } else if age_ms <= micro_checkpoint_retention_ms {
    micro_checkpoint_interval_ms
  } else if age_ms <= macro_checkpoint_retention_ms {
    macro_checkpoint_interval_ms
  } else {
    -1
  }
  proof_assert retained_localization_precision_post(
    event_interval_ms, micro_checkpoint_interval_ms, macro_checkpoint_interval_ms,
    event_retention_ms, micro_checkpoint_retention_ms, macro_checkpoint_retention_ms,
    age_ms, result,
  )
  result
}

///|
/// Finest time interval that can still be isolated for evidence of `age_ms`.
pub fn localization_precision_ms(
  policy : VerifiedCheckpointPolicy,
  age_ms : Int,
) -> Int? {
  let precision = retained_localization_precision_ms(
    policy.value.event_interval_ms,
    policy.value.micro_checkpoint_interval_ms,
    policy.value.macro_checkpoint_interval_ms,
    policy.value.event_retention_ms,
    policy.value.micro_checkpoint_retention_ms,
    policy.value.macro_checkpoint_retention_ms,
    age_ms,
  )
  if precision < 0 {
    None
  } else {
    Some(precision)
  }
}

///|
fn average_finality_ms(
  macro_checkpoint_interval_ms : Int,
  mean_validation_ms : Int,
) -> Int where {
  proof_ensure: result => {
    average_finality_post(
      macro_checkpoint_interval_ms, mean_validation_ms, result,
    )
  },
} {
  let result = macro_checkpoint_interval_ms / 2 + mean_validation_ms
  proof_assert average_finality_post(
    macro_checkpoint_interval_ms, mean_validation_ms, result,
  )
  result
}

///|
fn finality_upper_bound_ms(
  macro_checkpoint_interval_ms : Int,
  validation_latency_bound_ms : Int,
) -> Int where {
  proof_ensure: result => {
    finality_upper_bound_post(
      macro_checkpoint_interval_ms, validation_latency_bound_ms, result,
    )
  },
} {
  let result = macro_checkpoint_interval_ms + validation_latency_bound_ms
  proof_assert finality_upper_bound_post(
    macro_checkpoint_interval_ms, validation_latency_bound_ms, result,
  )
  result
}

///|
/// Estimate finality without coupling display rollback to server cadence.
/// Invalid latency summaries fail closed instead of producing a misleading
/// estimate.
pub fn estimate_finality(
  policy : VerifiedCheckpointPolicy,
  mean_validation_ms~ : Int,
  p99_validation_ms~ : Int,
) -> FinalityEstimate? {
  if mean_validation_ms < 0 || p99_validation_ms < mean_validation_ms {
    return None
  }
  Some({
    average_ms: average_finality_ms(
      policy.value.macro_checkpoint_interval_ms,
      mean_validation_ms,
    ),
    p99_upper_ms: finality_upper_bound_ms(
      policy.value.macro_checkpoint_interval_ms,
      p99_validation_ms,
    ),
  })
}
