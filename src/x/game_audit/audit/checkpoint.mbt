///|
/// Authority decision over a checkpoint candidate.
///
/// `Accept` is not sufficient by itself: either the participant fast path or a
/// matching authority replay must also be present.
pub(all) enum AuthorityVerdict {
  NoVerdict
  Accept
  Reject
} derive(Eq, Debug)

///|
/// Durable lifecycle of a checkpoint in a player's local-first database.
pub(all) enum CheckpointDecision {
  Pending
  Attested
  Challenged
  Finalized
  Rejected
} derive(Eq, Debug)

///|
/// Count participant approvals. A `false` entry represents a missing approval;
/// signed objections are represented separately by `challenged`.
pub fn count_approvals(
  approvals : FixedArray[Bool],
) -> Int where {
  proof_ensure: result => count_approvals_post(approvals, result),
} {
  for i = 0, count = 0; i < approvals.length(); {
    let next_count = if approvals[i] { count + 1 } else { count }
    proof_assert next_count == approval_count_upto(approvals, i + 1)
    continue i + 1, next_count
  } nobreak {
    count
  } where {
    proof_invariant: 0 <= i,
    proof_invariant: i <= approvals.length(),
    proof_invariant: count == approval_count_upto(approvals, i),
    proof_reasoning: (
      #| `count` is the number of `true` approvals in the processed prefix.
      #| Extending the prefix by one either preserves or increments the count.
    ),
  }
}

///|
/// Evaluate a checkpoint using the cooperative fast path and authority fallback.
///
/// - quorum without an authority verdict is only `Attested`
/// - a challenge disables the quorum fast path
/// - a matching replay can finalize despite missing approvals or a challenge
/// - an authority rejection is terminal
pub fn decide_checkpoint(
  approvals : FixedArray[Bool],
  required_approvals : Int,
  challenged~ : Bool,
  authority~ : AuthorityVerdict,
  replay_matches~ : Bool,
) -> CheckpointDecision where {
  proof_ensure: result => {
    decide_checkpoint_post(
      approvals, required_approvals, challenged, authority, replay_matches, result,
    )
  },
} {
  let result = match authority {
    Reject => CheckpointDecision::Rejected
    Accept =>
      if replay_matches {
        CheckpointDecision::Finalized
      } else if challenged {
        CheckpointDecision::Challenged
      } else {
        let approval_count = count_approvals(approvals)
        if required_approvals > 0 &&
          required_approvals <= approvals.length() &&
          approval_count >= required_approvals {
          CheckpointDecision::Finalized
        } else {
          CheckpointDecision::Pending
        }
      }
    NoVerdict =>
      if challenged {
        CheckpointDecision::Challenged
      } else {
        let approval_count = count_approvals(approvals)
        if required_approvals > 0 &&
          required_approvals <= approvals.length() &&
          approval_count >= required_approvals {
          CheckpointDecision::Attested
        } else {
          CheckpointDecision::Pending
        }
      }
  }
  proof_assert decide_checkpoint_post(
    approvals, required_approvals, challenged, authority, replay_matches, result,
  )
  result
}

///|
/// Marketplace acceptance gate for an item receipt.
///
/// The Merkle inclusion check is supplied by the cryptographic boundary. Even a
/// finalized checkpoint cannot authorize an item with a rejected ancestor.
pub fn market_accepts(
  decision : CheckpointDecision,
  item_included~ : Bool,
  rejected_ancestor~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    market_accepts_post(decision, item_included, rejected_ancestor, result)
  },
} {
  let result = match decision {
    Finalized => item_included && !rejected_ancestor
    _ => false
  }
  proof_assert market_accepts_post(
    decision, item_included, rejected_ancestor, result,
  )
  result
}
