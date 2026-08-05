///|
pub(all) enum OpenWorldObserverSigningDecision {
  SignNewObservation
  ReuseExistingObservation
  RejectConflictingObservation
  RejectInvalidObservation
} derive(Eq, Debug)

///|
/// Decide whether a local observer may sign one registration target.
///
/// The storage adapter supplies whether this exact `(plan, slot)` already has
/// an observation and whether its encounter digest matches the retry.
pub fn classify_open_world_observer_signing(
  target_valid~ : Bool,
  previous_observation_present~ : Bool,
  previous_digest_matches~ : Bool,
) -> OpenWorldObserverSigningDecision where {
  proof_ensure: decision => {
    open_world_observer_signing_post(
      target_valid, previous_observation_present, previous_digest_matches, decision,
    )
  },
} {
  let decision = if !target_valid {
    OpenWorldObserverSigningDecision::RejectInvalidObservation
  } else if !previous_observation_present {
    OpenWorldObserverSigningDecision::SignNewObservation
  } else if previous_digest_matches {
    OpenWorldObserverSigningDecision::ReuseExistingObservation
  } else {
    OpenWorldObserverSigningDecision::RejectConflictingObservation
  }
  proof_assert open_world_observer_signing_post(
    target_valid, previous_observation_present, previous_digest_matches, decision,
  )
  decision
}
