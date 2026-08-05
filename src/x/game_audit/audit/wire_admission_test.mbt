///|
test "wire admission is fail closed for every decoding boundary" {
  assert_eq(
    classify_open_world_wire_admission(
      bytes_within_budget=true,
      canonical_encoding=true,
      supported_version=true,
      shape_valid=true,
      text_within_budget=true,
      proof_within_budget=true,
      items_within_budget=true,
    ),
    OpenWorldWireAdmissionDecision::AdmitOpenWorldWirePayload,
  )
  let expected = [
    OpenWorldWireAdmissionDecision::RejectOpenWorldWireByteBudget,
    OpenWorldWireAdmissionDecision::RejectOpenWorldWireCanonicalEncoding,
    OpenWorldWireAdmissionDecision::RejectOpenWorldWireVersion,
    OpenWorldWireAdmissionDecision::RejectOpenWorldWireShape,
    OpenWorldWireAdmissionDecision::RejectOpenWorldWireTextBudget,
    OpenWorldWireAdmissionDecision::RejectOpenWorldWireProofBudget,
    OpenWorldWireAdmissionDecision::RejectOpenWorldWireItemBudget,
  ]
  for rejected_index in 0..<expected.length() {
    let flags = Array::make(7, true)
    flags[rejected_index] = false
    assert_eq(
      classify_open_world_wire_admission(
        bytes_within_budget=flags[0],
        canonical_encoding=flags[1],
        supported_version=flags[2],
        shape_valid=flags[3],
        text_within_budget=flags[4],
        proof_within_budget=flags[5],
        items_within_budget=flags[6],
      ),
      expected[rejected_index],
    )
  }
}
