///|
fn prepared(event_root? : String = "events") -> @checkpoint.PreparedCheckpoint {
  let hasher = @bft.FnvHasher::new()
  @checkpoint.prepare_checkpoint(hasher, @checkpoint.Checkpoint::{
    session_id: "dungeon-42",
    epoch: 7,
    previous_checkpoint: @bft.Digest("previous"),
    manifest_digest: @bft.Digest("manifest"),
    event_root: @bft.Digest(event_root),
    public_state_root: @bft.Digest("state"),
    asset_delta_root: @bft.Digest("items"),
    hidden_state_commitment: None,
  })
}

///|
fn participant(id : String, signer : &@bft.Signer) -> Participant {
  { id, key: signer.public_key() }
}

///|
fn expect_rejection_kind(
  result : EvidenceDeliveryResult,
  expected : EvidenceAlertKind,
) -> Unit raise Error {
  match result {
    Rejected(alert) => assert_eq(alert.kind, expected)
    _ => fail("expected rejected attestation")
  }
}

///|
test "verified approvals become audit quorum evidence" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let bob = @bft.MockSigner::new("bob")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
    participant("bob", bob),
  ])
  assert_true(collector.is_roster_valid())
  assert_eq(
    collector.deliver(sign_attestation(hasher, alice, target, "alice", Approve)),
    EvidenceDeliveryResult::Accepted,
  )
  assert_eq(
    collector.deliver(sign_attestation(hasher, bob, target, "bob", Approve)),
    EvidenceDeliveryResult::Accepted,
  )
  let evidence = collector.evidence()
  assert_true(evidence.approvals[0])
  assert_true(evidence.approvals[1])
  assert_false(evidence.challenged)
  assert_eq(
    collector.decide(
      2,
      authority=@audit.AuthorityVerdict::NoVerdict,
      authority_key=@bft.PublicKey(""),
      replay_match=None,
    ),
    @audit.CheckpointDecision::Attested,
  )
}

///|
test "a verified challenge disables the quorum fast path" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let bob = @bft.MockSigner::new("bob")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
    participant("bob", bob),
  ])
  ignore(
    collector.deliver(sign_attestation(hasher, alice, target, "alice", Approve)),
  )
  ignore(
    collector.deliver(sign_attestation(hasher, bob, target, "bob", Challenge)),
  )
  let evidence = collector.evidence()
  assert_true(evidence.approvals[0])
  assert_false(evidence.approvals[1])
  assert_true(evidence.challenged)
  assert_eq(
    collector.decide(
      1,
      authority=@audit.AuthorityVerdict::Accept,
      authority_key=@bft.PublicKey("authority"),
      replay_match=None,
    ),
    @audit.CheckpointDecision::Challenged,
  )
}

///|
test "invalid signature cannot create a challenge" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
  ])
  let signed = sign_attestation(hasher, alice, target, "alice", Challenge)
  let tampered : SignedAttestation = {
    attestation: signed.attestation,
    digest: signed.digest,
    signature: @bft.Signature("invalid"),
    signer_key: signed.signer_key,
  }
  expect_rejection_kind(
    collector.deliver(tampered),
    EvidenceAlertKind::InvalidSignature,
  )
  assert_false(collector.evidence().challenged)
}

///|
test "a signer cannot claim another participant id" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let mallory = @bft.MockSigner::new("mallory")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
  ])
  expect_rejection_kind(
    collector.deliver(
      sign_attestation(hasher, mallory, target, "alice", Approve),
    ),
    EvidenceAlertKind::SignerKeyMismatch,
  )
  assert_false(collector.evidence().approvals[0])
}

///|
test "content tampering and unknown participants are rejected" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let mallory = @bft.MockSigner::new("mallory")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
  ])
  let signed = sign_attestation(hasher, alice, target, "alice", Approve)
  let tampered : SignedAttestation = {
    attestation: { ..signed.attestation, choice: Challenge },
    digest: signed.digest,
    signature: signed.signature,
    signer_key: signed.signer_key,
  }
  expect_rejection_kind(
    collector.deliver(tampered),
    EvidenceAlertKind::HashMismatch,
  )
  expect_rejection_kind(
    collector.deliver(
      sign_attestation(hasher, mallory, target, "mallory", Approve),
    ),
    EvidenceAlertKind::UnknownParticipant,
  )
}

///|
test "an authenticated vote for another checkpoint is rejected" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let target = prepared()
  let other = prepared(event_root="other-events")
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
  ])
  expect_rejection_kind(
    collector.deliver(sign_attestation(hasher, alice, other, "alice", Approve)),
    EvidenceAlertKind::WrongCheckpoint,
  )
}

///|
test "duplicate delivery is idempotent" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
  ])
  let signed = sign_attestation(hasher, alice, target, "alice", Approve)
  assert_eq(collector.deliver(signed), EvidenceDeliveryResult::Accepted)
  assert_eq(collector.deliver(signed), EvidenceDeliveryResult::Duplicate)
  assert_true(collector.evidence().approvals[0])
}

///|
test "conflicting signed choices revoke approval and raise challenge" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
  ])
  ignore(
    collector.deliver(sign_attestation(hasher, alice, target, "alice", Approve)),
  )
  expect_rejection_kind(
    collector.deliver(
      sign_attestation(hasher, alice, target, "alice", Challenge),
    ),
    EvidenceAlertKind::Equivocation,
  )
  let evidence = collector.evidence()
  assert_false(evidence.approvals[0])
  assert_true(evidence.challenged)
}

///|
test "duplicate participant ids or shared keys invalidate the roster" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let target = prepared()
  let duplicate_id = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
    participant("alice", alice),
  ])
  assert_false(duplicate_id.is_roster_valid())
  expect_rejection_kind(
    duplicate_id.deliver(
      sign_attestation(hasher, alice, target, "alice", Approve),
    ),
    EvidenceAlertKind::InvalidRoster,
  )
  let shared_key = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
    participant("alice-alt", alice),
  ])
  assert_false(shared_key.is_roster_valid())
}

///|
test "canonical attestation serialization separates string boundaries" {
  let target = prepared()
  let left : Attestation = {
    checkpoint_digest: target.digest(),
    participant_id: "a:b",
    purpose: CheckpointApproval,
    choice: Approve,
  }
  let right : Attestation = {
    checkpoint_digest: target.digest(),
    participant_id: "a",
    purpose: CheckpointApproval,
    choice: Challenge,
  }
  assert_not_eq(serialize_attestation(left), serialize_attestation(right))
}

///|
test "one-to-many mode needs authority replay when no participant quorum exists" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (target, _, replay_match) = authority_replay_fixture()
  let collector = EvidenceCollector::new(hasher, verifier, target, [])
  assert_true(collector.is_roster_valid())
  assert_eq(
    collector.decide(
      0,
      authority=@audit.AuthorityVerdict::NoVerdict,
      authority_key=@bft.PublicKey(""),
      replay_match=None,
    ),
    @audit.CheckpointDecision::Pending,
  )
  assert_eq(
    collector.decide(
      0,
      authority=@audit.AuthorityVerdict::Accept,
      authority_key=@bft.PublicKey("authority"),
      replay_match=Some(replay_match),
    ),
    @audit.CheckpointDecision::Finalized,
  )
}

///|
test "conflicting choices converge regardless of delivery order" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let target = prepared()
  let roster = [participant("alice", alice)]
  let approve = sign_attestation(hasher, alice, target, "alice", Approve)
  let challenge = sign_attestation(hasher, alice, target, "alice", Challenge)
  let left = EvidenceCollector::new(hasher, verifier, target, roster)
  ignore(left.deliver(approve))
  ignore(left.deliver(challenge))
  let right = EvidenceCollector::new(hasher, verifier, target, roster)
  ignore(right.deliver(challenge))
  ignore(right.deliver(approve))
  let left_evidence = left.evidence()
  let right_evidence = right.evidence()
  assert_eq(left_evidence.approvals[0], right_evidence.approvals[0])
  assert_eq(left_evidence.challenged, right_evidence.challenged)
  assert_false(left_evidence.approvals[0])
  assert_true(left_evidence.challenged)
}

///|
fn verified_checkpoint(
  target : @checkpoint.PreparedCheckpoint,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  verified_checkpoint_by(target, "authority")
}

///|
fn verified_checkpoint_by(
  target : @checkpoint.PreparedCheckpoint,
  authority_name : String,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new(authority_name)
  let signed = @checkpoint.sign_prepared_checkpoint(authority, target)
  match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      authority.public_key(),
      signed,
    ) {
    Opened(verified) => verified
    Refused(_) => fail("expected authority checkpoint verification")
  }
}

///|
/// Build the smallest complete encounter whose deterministic result is bound
/// to the exact authority checkpoint returned alongside it.
fn authority_replay_fixture() -> (
  @checkpoint.PreparedCheckpoint,
  @checkpoint.VerifiedCheckpoint,
  @replay.CheckpointReplayMatch,
) raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let adapter = @bft.BFTAdapter::new(hasher, verifier, session_id="dungeon-42")
  assert_true(
    adapter.register_peer(@types.PeerId("authority"), authority.public_key()),
  )
  let attack : @replay.TelegraphedAttack = {
    attack_id: "fixture-attack",
    visible_tick: 10,
    resolve_tick: 14,
    center_x: 0,
    radius: 1,
  }
  let event = @replay.make_dungeon_telegraph_event(
    peer=@types.PeerId("authority"),
    counter=0,
    lamport=1,
    deps=[],
    attack~,
  )
  let telegraph = match adapter.deliver(adapter.sign(authority, event, [])) {
    Accepted(source) => source
    _ => fail("expected authenticated replay fixture")
  }
  let candidate = match
    @replay.prepare_dungeon_encounter(
      hasher,
      session_id="dungeon-42",
      authority_key=authority.public_key(),
      config={
        encounter_id: "fixture-encounter",
        player_max_hp: 2,
        attack_rules: {
          min_reaction_ticks: 2,
          max_backdate_ticks: 2,
          max_dodge_distance: 4,
          arena_min_x: -10,
          arena_max_x: 10,
          loot_item_type: "fixture-token",
        },
      },
      players=[
        {
          player_id: "alice",
          public_key: @bft.PublicKey("alice"),
          initial_x: 0,
        },
      ],
      attacks=[{ attack, damage: 1 }],
      transcripts=[
        { attack_id: attack.attack_id, telegraph, dodge_evidence: [] },
      ],
    ) {
    CandidateReady(candidate) => candidate
    _ => fail("expected complete replay candidate")
  }
  let target = @checkpoint.prepare_checkpoint(hasher, {
    session_id: "dungeon-42",
    epoch: 7,
    previous_checkpoint: @bft.Digest("previous"),
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: candidate.public_state_root(),
    asset_delta_root: @bft.Digest("items"),
    hidden_state_commitment: None,
  })
  let signed = @checkpoint.sign_prepared_checkpoint(authority, target)
  let verified = match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      authority.public_key(),
      signed,
    ) {
    Opened(checkpoint) => checkpoint
    _ => fail("expected verified replay checkpoint")
  }
  let replay_match = match
    @replay.finalize_dungeon_encounter(candidate, verified) {
    EncounterFinalized(resolution) => resolution.replay_match()
    _ => fail("expected checkpoint-bound replay match")
  }
  (target, verified, replay_match)
}

///|
test "only matching verified checkpoint and audit evidence create finalization capability" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
  ])
  ignore(
    collector.deliver(sign_attestation(hasher, alice, target, "alice", Approve)),
  )
  match collector.finalize(verified_checkpoint(target), 1, replay_match=None) {
    Ready(finalized) => assert_eq(finalized.digest(), target.digest())
    _ => fail("expected finalized checkpoint capability")
  }
}

///|
test "a verified but different checkpoint cannot finalize this evidence" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (target, _, replay_match) = authority_replay_fixture()
  let other = prepared(event_root="other-events")
  let collector = EvidenceCollector::new(hasher, verifier, target, [])
  match
    collector.finalize(
      verified_checkpoint(other),
      0,
      replay_match=Some(replay_match),
    ) {
    CheckpointMismatch => ()
    _ => fail("mismatched checkpoint unexpectedly finalized")
  }
}

///|
test "replay evidence for a different checkpoint cannot authorize fallback" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (_, _, replay_match) = authority_replay_fixture()
  let target = prepared(event_root="different-replay-root")
  let collector = EvidenceCollector::new(hasher, verifier, target, [])
  match
    collector.finalize(
      verified_checkpoint(target),
      0,
      replay_match=Some(replay_match),
    ) {
    Deferred(@audit.CheckpointDecision::Pending) => ()
    _ => fail("foreign replay evidence unexpectedly finalized checkpoint")
  }
}

///|
test "authority replay can create finalization capability without peer quorum" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (target, verified, replay_match) = authority_replay_fixture()
  let collector = EvidenceCollector::new(hasher, verifier, target, [])
  match collector.finalize(verified, 0, replay_match=Some(replay_match)) {
    Ready(finalized) =>
      assert_eq(finalized.checkpoint().session_id, "dungeon-42")
    _ => fail("matching authority replay should finalize")
  }
}

///|
test "encounter replay capability is bound to the verified authority key" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (target, _, replay_match) = authority_replay_fixture()
  let collector = EvidenceCollector::new(hasher, verifier, target, [])
  match
    collector.finalize(
      verified_checkpoint_by(target, "impostor-authority"),
      0,
      replay_match=Some(replay_match),
    ) {
    Deferred(@audit.CheckpointDecision::Pending) => ()
    _ => fail("replay capability crossed authority keys")
  }
}

///|
test "an unresolved signed challenge cannot create finalization capability" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let alice = @bft.MockSigner::new("alice")
  let target = prepared()
  let collector = EvidenceCollector::new(hasher, verifier, target, [
    participant("alice", alice),
  ])
  ignore(
    collector.deliver(
      sign_attestation(hasher, alice, target, "alice", Challenge),
    ),
  )
  match collector.finalize(verified_checkpoint(target), 1, replay_match=None) {
    Deferred(@audit.CheckpointDecision::Challenged) => ()
    _ => fail("unresolved challenge unexpectedly finalized")
  }
}
