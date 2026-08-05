///|
/// Per-participant evidence for one authenticated checkpoint digest.
///
/// This is a join-semilattice: duplicate delivery is idempotent, delivery
/// order is irrelevant, and conflicting signed choices become equivocation.
pub(all) enum ParticipantVote {
  NoVote
  ApproveVote
  ChallengeVote
  EquivocatedVote
} derive(Eq, Debug)

///|
/// Merge two independently observed states for the same participant.
pub fn merge_participant_votes(
  left : ParticipantVote,
  right : ParticipantVote,
) -> ParticipantVote where {
  proof_ensure: result => merge_participant_votes_post(left, right, result),
} {
  let result = match (left, right) {
    (EquivocatedVote, _) | (_, EquivocatedVote) => EquivocatedVote
    (NoVote, state) | (state, NoVote) => state
    (ApproveVote, ApproveVote) => ApproveVote
    (ChallengeVote, ChallengeVote) => ChallengeVote
    (ApproveVote, ChallengeVote) | (ChallengeVote, ApproveVote) =>
      EquivocatedVote
  }
  proof_assert merge_participant_votes_post(left, right, result)
  result
}

///|
/// Only an uncontested approval contributes to quorum.
pub fn ParticipantVote::is_approval(
  self : ParticipantVote,
) -> Bool where {
  proof_ensure: result => participant_vote_is_approval_post(self, result),
} {
  let result = match self {
    ApproveVote => true
    _ => false
  }
  proof_assert participant_vote_is_approval_post(self, result)
  result
}

///|
/// A signed challenge or equivocation disables the participant fast path.
pub fn ParticipantVote::is_challenge(
  self : ParticipantVote,
) -> Bool where {
  proof_ensure: result => participant_vote_is_challenge_post(self, result),
} {
  let result = match self {
    ChallengeVote | EquivocatedVote => true
    _ => false
  }
  proof_assert participant_vote_is_challenge_post(self, result)
  result
}
