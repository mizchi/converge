///|
/// A witness policy can tolerate at most `max_faults` Byzantine witnesses when
/// the authenticated roster contains strictly more than `3 * max_faults`
/// members.
pub fn replay_witness_policy_valid(
  witness_count : Int,
  max_faults : Int,
) -> Bool where {
  proof_ensure: result => {
    replay_witness_policy_valid_post(witness_count, max_faults, result)
  },
} {
  let result = max_faults >= 0 && witness_count > 3 * max_faults
  proof_assert replay_witness_policy_valid_post(
    witness_count, max_faults, result,
  )
  result
}

///|
/// Use `n - f`, rather than a fixed `2f + 1`, so quorum intersection remains
/// greater than `f` even when the roster is larger than the minimum `3f + 1`.
pub fn replay_witness_quorum_size(
  witness_count : Int,
  max_faults : Int,
) -> Int where {
  proof_ensure: result => {
    replay_witness_quorum_size_post(witness_count, max_faults, result)
  },
} {
  let result = witness_count - max_faults
  proof_assert replay_witness_quorum_size_post(
    witness_count, max_faults, result,
  )
  result
}

///|
/// Decide whether authenticated replay-witness approvals can form a
/// certificate. Challenges and equivocations simply do not count as approvals;
/// up to `f` faulty witnesses therefore cannot veto an `n - f` quorum.
pub fn replay_witness_certificate_allowed(
  witness_count~ : Int,
  max_faults~ : Int,
  approval_count~ : Int,
) -> Bool where {
  proof_ensure: result => {
    replay_witness_certificate_allowed_post(
      witness_count, max_faults, approval_count, result,
    )
  },
} {
  let result = max_faults >= 0 &&
    witness_count > 3 * max_faults &&
    approval_count >= witness_count - max_faults &&
    approval_count <= witness_count
  proof_assert replay_witness_certificate_allowed_post(
    witness_count, max_faults, approval_count, result,
  )
  result
}
