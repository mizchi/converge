///|
/// A registration-observer policy tolerates at most `max_faults` Byzantine
/// observers when the plan-bound roster contains strictly more than `3f`.
pub fn open_world_observer_policy_valid(
  observer_count : Int,
  max_faults : Int,
) -> Bool where {
  proof_ensure: result => {
    open_world_observer_policy_valid_post(observer_count, max_faults, result)
  },
} {
  let result = max_faults >= 0 && observer_count > 3 * max_faults
  proof_assert open_world_observer_policy_valid_post(
    observer_count, max_faults, result,
  )
  result
}

///|
/// Use `n - f` receipts so two independently accepted registration
/// certificates must intersect in more than `f` observer positions.
pub fn open_world_observer_quorum_size(
  observer_count : Int,
  max_faults : Int,
) -> Int where {
  proof_ensure: result => {
    open_world_observer_quorum_size_post(observer_count, max_faults, result)
  },
} {
  let result = observer_count - max_faults
  proof_assert open_world_observer_quorum_size_post(
    observer_count, max_faults, result,
  )
  result
}

///|
/// Decide whether authenticated observer receipts can certify that a specific
/// `(audit plan, slot, encounter digest)` registration was observed.
pub fn open_world_observer_certificate_allowed(
  observer_count~ : Int,
  max_faults~ : Int,
  approval_count~ : Int,
) -> Bool where {
  proof_ensure: result => {
    open_world_observer_certificate_allowed_post(
      observer_count, max_faults, approval_count, result,
    )
  },
} {
  let result = max_faults >= 0 &&
    observer_count > 3 * max_faults &&
    approval_count >= observer_count - max_faults &&
    approval_count <= observer_count
  proof_assert open_world_observer_certificate_allowed_post(
    observer_count, max_faults, approval_count, result,
  )
  result
}
