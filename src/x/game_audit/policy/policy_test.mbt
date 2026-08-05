///|
fn verified_policy(mode : GameAuditMode) -> @audit.VerifiedCheckpointPolicy {
  match checkpoint_policy_for_mode(mode) {
    @audit.CheckpointPolicyOpenResult::Opened(policy) => policy
    @audit.CheckpointPolicyOpenResult::Refused(_) =>
      abort("game checkpoint policy must be valid")
  }
}

///|
test "game modes choose policy numbers without changing the generic algorithm" {
  let pvp = verified_policy(AdversarialPvp)
  let pvp_value = pvp.policy()
  inspect(pvp_value.event_interval_ms, content="16")
  inspect(pvp_value.micro_checkpoint_interval_ms, content="250")
  inspect(pvp_value.macro_checkpoint_interval_ms, content="2000")
  inspect(@audit.dispute_bisection_rounds(pvp), content="7")

  let pve = verified_policy(CooperativePve)
  let pve_value = pve.policy()
  inspect(pve_value.event_interval_ms, content="33")
  inspect(pve_value.micro_checkpoint_interval_ms, content="1000")
  inspect(pve_value.macro_checkpoint_interval_ms, content="15000")
  inspect(@audit.dispute_bisection_rounds(pve), content="9")

  let open_world = verified_policy(OpenWorldEncounter)
  let open_value = open_world.policy()
  inspect(open_value.event_interval_ms, content="50")
  inspect(open_value.micro_checkpoint_interval_ms, content="2000")
  inspect(open_value.macro_checkpoint_interval_ms, content="30000")
  inspect(@audit.dispute_bisection_rounds(open_world), content="10")
}

///|
test "game policy finality uses measured latency as an input not a core constant" {
  let pve = verified_policy(CooperativePve)
  debug_inspect(
    @audit.estimate_finality(pve, mean_validation_ms=100, p99_validation_ms=244),
    content=(
      #|Some({ average_ms: 7600, p99_upper_ms: 15244 })
    ),
  )
  let open_world = verified_policy(OpenWorldEncounter)
  debug_inspect(
    @audit.localization_precision_ms(open_world, 300000),
    content="Some(50)",
  )
  debug_inspect(
    @audit.localization_precision_ms(open_world, 300001),
    content="Some(2000)",
  )
}
