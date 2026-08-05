///|
test "participant vote merge is idempotent" {
  let states = [
    ParticipantVote::NoVote,
    ParticipantVote::ApproveVote,
    ParticipantVote::ChallengeVote,
    ParticipantVote::EquivocatedVote,
  ]
  for state in states {
    assert_eq(merge_participant_votes(state, state), state)
  }
}

///|
test "participant vote merge is commutative and associative" {
  let states = [
    ParticipantVote::NoVote,
    ParticipantVote::ApproveVote,
    ParticipantVote::ChallengeVote,
    ParticipantVote::EquivocatedVote,
  ]
  for left in states {
    for right in states {
      assert_eq(
        merge_participant_votes(left, right),
        merge_participant_votes(right, left),
      )
      for third in states {
        assert_eq(
          merge_participant_votes(merge_participant_votes(left, right), third),
          merge_participant_votes(left, merge_participant_votes(right, third)),
        )
      }
    }
  }
}

///|
test "approve and challenge equivocation fails closed" {
  let merged = merge_participant_votes(
    ParticipantVote::ApproveVote,
    ParticipantVote::ChallengeVote,
  )
  assert_eq(merged, ParticipantVote::EquivocatedVote)
  assert_false(merged.is_approval())
  assert_true(merged.is_challenge())
}

///|
test "only a clean approval counts toward quorum" {
  assert_false(ParticipantVote::NoVote.is_approval())
  assert_true(ParticipantVote::ApproveVote.is_approval())
  assert_false(ParticipantVote::ChallengeVote.is_approval())
  assert_false(ParticipantVote::EquivocatedVote.is_approval())
  assert_false(ParticipantVote::NoVote.is_challenge())
  assert_false(ParticipantVote::ApproveVote.is_challenge())
  assert_true(ParticipantVote::ChallengeVote.is_challenge())
  assert_true(ParticipantVote::EquivocatedVote.is_challenge())
}
