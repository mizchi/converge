///|
test "observer signs only a new valid plan-slot target" {
  assert_eq(
    classify_open_world_observer_signing(
      target_valid=true,
      previous_observation_present=false,
      previous_digest_matches=false,
    ),
    OpenWorldObserverSigningDecision::SignNewObservation,
  )
}

///|
test "same observer registration is an idempotent retry" {
  assert_eq(
    classify_open_world_observer_signing(
      target_valid=true,
      previous_observation_present=true,
      previous_digest_matches=true,
    ),
    OpenWorldObserverSigningDecision::ReuseExistingObservation,
  )
}

///|
test "conflicting digest for one plan-slot is never signed" {
  assert_eq(
    classify_open_world_observer_signing(
      target_valid=true,
      previous_observation_present=true,
      previous_digest_matches=false,
    ),
    OpenWorldObserverSigningDecision::RejectConflictingObservation,
  )
}

///|
test "invalid observer signing target fails closed" {
  for previous_present in [false, true] {
    for previous_matches in [false, true] {
      assert_eq(
        classify_open_world_observer_signing(
          target_valid=false,
          previous_observation_present=previous_present,
          previous_digest_matches=previous_matches,
        ),
        OpenWorldObserverSigningDecision::RejectInvalidObservation,
      )
    }
  }
}
