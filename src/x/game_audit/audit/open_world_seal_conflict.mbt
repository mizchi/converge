///|
/// Result of checking whether an authority-sealed indexed encounter registry
/// conflicts with an authority-signed encounter checkpoint.
pub(all) enum OpenWorldSealConflictDecision {
  RegistryTruncated
  SlotSubstituted
  SlotMissing
  NoConflict
  InvalidEvidence
} derive(Eq, Debug)

///|
/// Classify only cryptographically derived boundary and Merkle facts.
///
/// A registry shorter than a valid signed slot is direct truncation evidence.
/// For an in-range slot, substitution requires a valid inclusion proof for a
/// different digest at that exact slot. A missing or malformed proof never
/// accuses the sealing authority.
pub fn classify_open_world_seal_conflict(
  encounter_boundary_matches~ : Bool,
  registration_index~ : Int,
  registered_count~ : Int,
  missing_registration_present~ : Bool,
  missing_registration_matches~ : Bool,
  conflicting_inclusion_present~ : Bool,
  conflicting_inclusion_matches~ : Bool,
  sealed_digest_matches~ : Bool,
) -> OpenWorldSealConflictDecision where {
  proof_ensure: decision => {
    open_world_seal_conflict_post(
      encounter_boundary_matches, registration_index, registered_count, missing_registration_present,
      missing_registration_matches, conflicting_inclusion_present, conflicting_inclusion_matches,
      sealed_digest_matches, decision,
    )
  },
} {
  let decision = if !encounter_boundary_matches ||
    registration_index < 0 ||
    registered_count < 0 {
    OpenWorldSealConflictDecision::InvalidEvidence
  } else if registration_index >= registered_count {
    OpenWorldSealConflictDecision::RegistryTruncated
  } else if missing_registration_present && conflicting_inclusion_present {
    OpenWorldSealConflictDecision::InvalidEvidence
  } else if missing_registration_present {
    if missing_registration_matches {
      OpenWorldSealConflictDecision::SlotMissing
    } else {
      OpenWorldSealConflictDecision::InvalidEvidence
    }
  } else if !conflicting_inclusion_present || !conflicting_inclusion_matches {
    OpenWorldSealConflictDecision::InvalidEvidence
  } else if sealed_digest_matches {
    OpenWorldSealConflictDecision::NoConflict
  } else {
    OpenWorldSealConflictDecision::SlotSubstituted
  }
  proof_assert open_world_seal_conflict_post(
    encounter_boundary_matches, registration_index, registered_count, missing_registration_present,
    missing_registration_matches, conflicting_inclusion_present, conflicting_inclusion_matches,
    sealed_digest_matches, decision,
  )
  decision
}
