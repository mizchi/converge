///|
fn quorum_member(id : String, signer : &@bft.Signer) -> QuorumMember {
  { member_id: id, member_key: signer.public_key() }
}

///|
test "authenticated votes are collected without application semantics" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let subject = @bft.Digest("opaque-subject")
  let collector = VoteCollector::new(
    hasher,
    verifier,
    subject,
    "replicated-log-approval",
    [quorum_member("alice", alice)],
  )
  let signed = sign_vote(
    hasher,
    alice,
    subject,
    "alice",
    "replicated-log-approval",
    VoteChoice::ApproveChoice,
  )
  assert_eq(collector.deliver(signed), VoteDeliveryResult::VoteAccepted)
  let evidence = collector.evidence()
  assert_true(evidence.approvals[0])
  assert_false(evidence.challenged)
}

///|
test "conflicting authenticated votes converge to challenge" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let subject = @bft.Digest("opaque-subject")
  let collector = VoteCollector::new(
    hasher,
    verifier,
    subject,
    "replicated-log-approval",
    [quorum_member("alice", alice)],
  )
  ignore(
    collector.deliver(
      sign_vote(
        hasher,
        alice,
        subject,
        "alice",
        "replicated-log-approval",
        VoteChoice::ApproveChoice,
      ),
    ),
  )
  match
    collector.deliver(
      sign_vote(
        hasher,
        alice,
        subject,
        "alice",
        "replicated-log-approval",
        VoteChoice::ChallengeChoice,
      ),
    ) {
    VoteRejected(alert) =>
      assert_eq(alert.kind, VoteAlertKind::VoteEquivocation)
    _ => fail("expected equivocation evidence")
  }
  let evidence = collector.evidence()
  assert_false(evidence.approvals[0])
  assert_true(evidence.challenged)
}
