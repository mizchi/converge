///|
test "registered slot beyond the sealed count proves truncation" {
  assert_eq(
    classify_open_world_seal_conflict(
      encounter_boundary_matches=true,
      registration_index=4,
      registered_count=4,
      missing_registration_present=false,
      missing_registration_matches=false,
      conflicting_inclusion_present=false,
      conflicting_inclusion_matches=false,
      sealed_digest_matches=false,
    ),
    OpenWorldSealConflictDecision::RegistryTruncated,
  )
}

///|
test "a different included digest at the same slot proves substitution" {
  assert_eq(
    classify_open_world_seal_conflict(
      encounter_boundary_matches=true,
      registration_index=2,
      registered_count=4,
      missing_registration_present=false,
      missing_registration_matches=false,
      conflicting_inclusion_present=true,
      conflicting_inclusion_matches=true,
      sealed_digest_matches=false,
    ),
    OpenWorldSealConflictDecision::SlotSubstituted,
  )
}

///|
test "wrong boundaries missing proofs and matching leaves never accuse" {
  for
    decision in [
      classify_open_world_seal_conflict(
        encounter_boundary_matches=false,
        registration_index=2,
        registered_count=4,
        missing_registration_present=false,
        missing_registration_matches=false,
        conflicting_inclusion_present=true,
        conflicting_inclusion_matches=true,
        sealed_digest_matches=false,
      ),
      classify_open_world_seal_conflict(
        encounter_boundary_matches=true,
        registration_index=2,
        registered_count=4,
        missing_registration_present=false,
        missing_registration_matches=false,
        conflicting_inclusion_present=false,
        conflicting_inclusion_matches=false,
        sealed_digest_matches=false,
      ),
      classify_open_world_seal_conflict(
        encounter_boundary_matches=true,
        registration_index=2,
        registered_count=4,
        missing_registration_present=false,
        missing_registration_matches=false,
        conflicting_inclusion_present=true,
        conflicting_inclusion_matches=false,
        sealed_digest_matches=false,
      ),
    ] {
    assert_eq(decision, OpenWorldSealConflictDecision::InvalidEvidence)
  }
  assert_eq(
    classify_open_world_seal_conflict(
      encounter_boundary_matches=true,
      registration_index=2,
      registered_count=4,
      missing_registration_present=false,
      missing_registration_matches=false,
      conflicting_inclusion_present=true,
      conflicting_inclusion_matches=true,
      sealed_digest_matches=true,
    ),
    OpenWorldSealConflictDecision::NoConflict,
  )
}

///|
test "negative indices and counts fail closed" {
  for
    decision in [
      classify_open_world_seal_conflict(
        encounter_boundary_matches=true,
        registration_index=-1,
        registered_count=4,
        missing_registration_present=false,
        missing_registration_matches=false,
        conflicting_inclusion_present=false,
        conflicting_inclusion_matches=false,
        sealed_digest_matches=false,
      ),
      classify_open_world_seal_conflict(
        encounter_boundary_matches=true,
        registration_index=0,
        registered_count=-1,
        missing_registration_present=false,
        missing_registration_matches=false,
        conflicting_inclusion_present=false,
        conflicting_inclusion_matches=false,
        sealed_digest_matches=false,
      ),
    ] {
    assert_eq(decision, OpenWorldSealConflictDecision::InvalidEvidence)
  }
}

///|
test "an authenticated empty in-range slot proves omission" {
  assert_eq(
    classify_open_world_seal_conflict(
      encounter_boundary_matches=true,
      registration_index=2,
      registered_count=4,
      missing_registration_present=true,
      missing_registration_matches=true,
      conflicting_inclusion_present=false,
      conflicting_inclusion_matches=false,
      sealed_digest_matches=false,
    ),
    OpenWorldSealConflictDecision::SlotMissing,
  )
}

///|
test "invalid or ambiguous absence evidence cannot accuse" {
  for
    decision in [
      classify_open_world_seal_conflict(
        encounter_boundary_matches=true,
        registration_index=2,
        registered_count=4,
        missing_registration_present=true,
        missing_registration_matches=false,
        conflicting_inclusion_present=false,
        conflicting_inclusion_matches=false,
        sealed_digest_matches=false,
      ),
      classify_open_world_seal_conflict(
        encounter_boundary_matches=true,
        registration_index=2,
        registered_count=4,
        missing_registration_present=true,
        missing_registration_matches=true,
        conflicting_inclusion_present=true,
        conflicting_inclusion_matches=true,
        sealed_digest_matches=false,
      ),
    ] {
    assert_eq(decision, OpenWorldSealConflictDecision::InvalidEvidence)
  }
}
