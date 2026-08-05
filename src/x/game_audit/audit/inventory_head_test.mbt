///|
test "inventory head advances iff every monotonic binding holds" {
  for mask in 0..<64 {
    let creation_eligible = (mask & 1) != 0
    let proof_verified = (mask & 2) != 0
    let manifest_matches = (mask & 4) != 0
    let parent_matches = (mask & 8) != 0
    let epoch_advances = (mask & 16) != 0
    let owner_version_consistent = (mask & 32) != 0
    assert_eq(
      inventory_head_advance_allowed(
        creation_eligible~,
        proof_verified~,
        manifest_matches~,
        parent_matches~,
        epoch_advances~,
        owner_version_consistent~,
      ),
      mask == 63,
    )
  }
}
