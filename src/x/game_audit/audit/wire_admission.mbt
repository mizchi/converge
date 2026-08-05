///|
pub(all) enum OpenWorldWireAdmissionDecision {
  AdmitOpenWorldWirePayload
  RejectOpenWorldWireByteBudget
  RejectOpenWorldWireCanonicalEncoding
  RejectOpenWorldWireVersion
  RejectOpenWorldWireShape
  RejectOpenWorldWireTextBudget
  RejectOpenWorldWireProofBudget
  RejectOpenWorldWireItemBudget
} derive(Eq, Debug)

///|
/// Pure fail-closed policy mirrored by the staged wire decoder.
pub fn classify_open_world_wire_admission(
  bytes_within_budget~ : Bool,
  canonical_encoding~ : Bool,
  supported_version~ : Bool,
  shape_valid~ : Bool,
  text_within_budget~ : Bool,
  proof_within_budget~ : Bool,
  items_within_budget~ : Bool,
) -> OpenWorldWireAdmissionDecision where {
  proof_ensure: decision => {
    open_world_wire_admission_post(
      bytes_within_budget, canonical_encoding, supported_version, shape_valid, text_within_budget,
      proof_within_budget, items_within_budget, decision,
    )
  },
} {
  let decision = if !bytes_within_budget {
    RejectOpenWorldWireByteBudget
  } else if !canonical_encoding {
    RejectOpenWorldWireCanonicalEncoding
  } else if !supported_version {
    RejectOpenWorldWireVersion
  } else if !shape_valid {
    RejectOpenWorldWireShape
  } else if !text_within_budget {
    RejectOpenWorldWireTextBudget
  } else if !proof_within_budget {
    RejectOpenWorldWireProofBudget
  } else if !items_within_budget {
    RejectOpenWorldWireItemBudget
  } else {
    AdmitOpenWorldWirePayload
  }
  proof_assert open_world_wire_admission_post(
    bytes_within_budget, canonical_encoding, supported_version, shape_valid, text_within_budget,
    proof_within_budget, items_within_budget, decision,
  )
  decision
}
