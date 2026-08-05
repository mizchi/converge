///|
fn replay_witness_roster(
  size : Int,
) -> (Array[@bft.MockSigner], Array[Participant]) {
  let signers : Array[@bft.MockSigner] = []
  let roster : Array[Participant] = []
  for index in 0..<size {
    let id = "witness-" + index.to_string()
    let signer = @bft.MockSigner::new(id)
    signers.push(signer)
    roster.push({ id, key: signer.public_key() })
  }
  (signers, roster)
}

///|
fn replay_witness_prepared(
  hasher : &@bft.Hasher,
  referee : &@bft.Signer,
  roster : Array[Participant],
  max_faults : Int,
  event_root? : String = "pvp-events",
) -> @checkpoint.PreparedCheckpoint {
  let manifest = replay_witness_session_manifest(
    hasher,
    game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
    referee_key=referee.public_key(),
    witnesses=roster,
    max_faults~,
  )
  @checkpoint.prepare_checkpoint(hasher, {
    session_id: "pvp-match-1",
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    manifest_digest: manifest,
    event_root: @bft.Digest(event_root),
    public_state_root: @bft.Digest("score-blue-10-orange-8"),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: Some(@bft.Digest("visibility-state")),
  })
}

///|
fn open_replay_witness_checkpoint(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  referee : &@bft.Signer,
  prepared : @checkpoint.PreparedCheckpoint,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let signed = @checkpoint.sign_prepared_checkpoint(referee, prepared)
  match
    @checkpoint.open_checkpoint(hasher, verifier, referee.public_key(), signed) {
    Opened(verified) => verified
    _ => fail("expected verified referee checkpoint")
  }
}

///|
fn replay_witness_collector_or_fail(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  prepared : @checkpoint.PreparedCheckpoint,
  referee : &@bft.Signer,
  roster : Array[Participant],
  max_faults : Int,
) -> ReplayWitnessCollector raise Error {
  match
    ReplayWitnessCollector::new(
      hasher,
      verifier,
      prepared,
      game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
      referee_key=referee.public_key(),
      witnesses=roster,
      max_faults~,
    ) {
    WitnessCollectorReady(collector) => collector
    _ => fail("expected valid replay witness collector")
  }
}

///|
test "replay witness manifest binds policy and is roster-order independent" {
  let hasher = @bft.FnvHasher::new()
  let referee = @bft.MockSigner::new("referee")
  let (_, roster) = replay_witness_roster(4)
  let reversed = [roster[3], roster[2], roster[1], roster[0]]
  let manifest = replay_witness_session_manifest(
    hasher,
    game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
    referee_key=referee.public_key(),
    witnesses=roster,
    max_faults=1,
  )
  assert_eq(
    manifest,
    replay_witness_session_manifest(
      hasher,
      game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
      referee_key=referee.public_key(),
      witnesses=reversed,
      max_faults=1,
    ),
  )
  assert_not_eq(
    manifest,
    replay_witness_session_manifest(
      hasher,
      game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
      referee_key=referee.public_key(),
      witnesses=roster,
      max_faults=0,
    ),
  )
}

///|
test "checkpoint approvals cannot be replayed as witness signatures" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let (signers, roster) = replay_witness_roster(4)
  let prepared = replay_witness_prepared(hasher, referee, roster, 1)
  let witness_collector = replay_witness_collector_or_fail(
    hasher, verifier, prepared, referee, roster, 1,
  )
  let checkpoint_collector = EvidenceCollector::new(
    hasher, verifier, prepared, roster,
  )
  let approval = sign_attestation(
    hasher,
    signers[0],
    prepared,
    roster[0].id,
    Approve,
  )
  let replay_witness = sign_replay_witness_attestation(
    hasher,
    signers[0],
    prepared,
    roster[0].id,
    Approve,
  )
  assert_not_eq(approval.digest, replay_witness.digest)
  match witness_collector.deliver(approval) {
    Rejected(alert) => assert_eq(alert.kind, WrongPurpose)
    _ => fail("checkpoint approval crossed into replay witness domain")
  }
  match checkpoint_collector.deliver(replay_witness) {
    Rejected(alert) => assert_eq(alert.kind, WrongPurpose)
    _ => fail("replay witness crossed into checkpoint approval domain")
  }
}

///|
test "n minus f replay witnesses certify despite one Byzantine challenge" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let (signers, roster) = replay_witness_roster(4)
  let prepared = replay_witness_prepared(hasher, referee, roster, 1)
  let verified = open_replay_witness_checkpoint(
    hasher, verifier, referee, prepared,
  )
  let witnesses = replay_witness_collector_or_fail(
    hasher, verifier, prepared, referee, roster, 1,
  )
  for index in 0..<3 {
    assert_eq(
      witnesses.deliver(
        sign_replay_witness_attestation(
          hasher,
          signers[index],
          prepared,
          roster[index].id,
          Approve,
        ),
      ),
      EvidenceDeliveryResult::Accepted,
    )
  }
  ignore(
    witnesses.deliver(
      sign_replay_witness_attestation(
        hasher,
        signers[3],
        prepared,
        roster[3].id,
        Challenge,
      ),
    ),
  )
  match witnesses.certify(verified) {
    WitnessCertified(certificate) => {
      assert_eq(certificate.checkpoint_digest(), prepared.digest())
      assert_eq(certificate.referee_key(), referee.public_key())
      assert_eq(certificate.approval_count(), 3)
      assert_eq(certificate.required_approvals(), 3)
    }
    _ => fail("n-f replay witness quorum did not certify")
  }
}

///|
test "witness certificate finalizes only its exact authority checkpoint" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let impostor = @bft.MockSigner::new("impostor-referee")
  let (signers, roster) = replay_witness_roster(4)
  let prepared = replay_witness_prepared(hasher, referee, roster, 1)
  let verified = open_replay_witness_checkpoint(
    hasher, verifier, referee, prepared,
  )
  let witnesses = replay_witness_collector_or_fail(
    hasher, verifier, prepared, referee, roster, 1,
  )
  for index in 0..<3 {
    ignore(
      witnesses.deliver(
        sign_replay_witness_attestation(
          hasher,
          signers[index],
          prepared,
          roster[index].id,
          Approve,
        ),
      ),
    )
  }
  let certificate = match witnesses.certify(verified) {
    WitnessCertified(value) => value
    _ => fail("expected replay witness certificate")
  }
  match finalize_witnessed_checkpoint(verified, certificate) {
    Ready(finalized) => assert_eq(finalized.digest(), prepared.digest())
    _ => fail("exact witness capability did not finalize checkpoint")
  }
  let impostor_verified = open_replay_witness_checkpoint(
    hasher, verifier, impostor, prepared,
  )
  match finalize_witnessed_checkpoint(impostor_verified, certificate) {
    CheckpointMismatch => ()
    _ => fail("witness certificate crossed referee identity")
  }
  let other = replay_witness_prepared(
    hasher,
    referee,
    roster,
    1,
    event_root="other-pvp-events",
  )
  let other_verified = open_replay_witness_checkpoint(
    hasher, verifier, referee, other,
  )
  match finalize_witnessed_checkpoint(other_verified, certificate) {
    CheckpointMismatch => ()
    _ => fail("witness certificate crossed checkpoint identity")
  }
}

///|
test "under-quorum and invalid witness policies fail closed" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let (signers, roster) = replay_witness_roster(4)
  let prepared = replay_witness_prepared(hasher, referee, roster, 1)
  let verified = open_replay_witness_checkpoint(
    hasher, verifier, referee, prepared,
  )
  let witnesses = replay_witness_collector_or_fail(
    hasher, verifier, prepared, referee, roster, 1,
  )
  for index in 0..<2 {
    ignore(
      witnesses.deliver(
        sign_replay_witness_attestation(
          hasher,
          signers[index],
          prepared,
          roster[index].id,
          Approve,
        ),
      ),
    )
  }
  assert_eq(
    witnesses.certify(verified),
    ReplayWitnessCertificationResult::WitnessQuorumPending(2, 3),
  )
  let (_, too_small) = replay_witness_roster(3)
  let invalid_prepared = replay_witness_prepared(hasher, referee, too_small, 1)
  match
    ReplayWitnessCollector::new(
      hasher,
      verifier,
      invalid_prepared,
      game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
      referee_key=referee.public_key(),
      witnesses=too_small,
      max_faults=1,
    ) {
    InvalidWitnessPolicy => ()
    _ => fail("invalid n <= 3f witness policy was accepted")
  }
}

///|
test "witness collector binds the committed manifest and independent referee" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let (_, roster) = replay_witness_roster(4)
  let valid_prepared = replay_witness_prepared(hasher, referee, roster, 1)
  match
    ReplayWitnessCollector::new(
      hasher,
      verifier,
      valid_prepared,
      game_manifest_digest=@bft.Digest(""),
      referee_key=referee.public_key(),
      witnesses=roster,
      max_faults=1,
    ) {
    InvalidGameManifest => ()
    _ => fail("empty game manifest was accepted")
  }
  match
    ReplayWitnessCollector::new(
      hasher,
      verifier,
      valid_prepared,
      game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
      referee_key=@bft.PublicKey(""),
      witnesses=roster,
      max_faults=1,
    ) {
    InvalidRefereeKey => ()
    _ => fail("empty referee key was accepted")
  }
  let wrong_manifest = @checkpoint.prepare_checkpoint(hasher, {
    ..replay_witness_prepared(hasher, referee, roster, 1).checkpoint(),
    manifest_digest: @bft.Digest("uncommitted-witness-policy"),
  })
  match
    ReplayWitnessCollector::new(
      hasher,
      verifier,
      wrong_manifest,
      game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
      referee_key=referee.public_key(),
      witnesses=roster,
      max_faults=1,
    ) {
    WitnessManifestMismatch => ()
    _ => fail("uncommitted witness policy was accepted")
  }
  let overlapping = roster.copy()
  overlapping[0] = { id: overlapping[0].id, key: referee.public_key() }
  let overlap_prepared = replay_witness_prepared(
    hasher, referee, overlapping, 1,
  )
  match
    ReplayWitnessCollector::new(
      hasher,
      verifier,
      overlap_prepared,
      game_manifest_digest=@bft.Digest("pvp-kernel-v1"),
      referee_key=referee.public_key(),
      witnesses=overlapping,
      max_faults=1,
    ) {
    RefereeIsWitness => ()
    _ => fail("referee was counted as an independent witness")
  }
}

///|
test "witness certificate cannot cross checkpoint or referee identity" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let impostor = @bft.MockSigner::new("impostor-referee")
  let (signers, roster) = replay_witness_roster(4)
  let prepared = replay_witness_prepared(hasher, referee, roster, 1)
  let verified = open_replay_witness_checkpoint(
    hasher, verifier, referee, prepared,
  )
  let witnesses = replay_witness_collector_or_fail(
    hasher, verifier, prepared, referee, roster, 1,
  )
  for index in 0..<3 {
    ignore(
      witnesses.deliver(
        sign_replay_witness_attestation(
          hasher,
          signers[index],
          prepared,
          roster[index].id,
          Approve,
        ),
      ),
    )
  }
  let certificate = match witnesses.certify(verified) {
    WitnessCertified(value) => value
    _ => fail("expected replay witness certificate")
  }
  let impostor_verified = open_replay_witness_checkpoint(
    hasher, verifier, impostor, prepared,
  )
  assert_eq(
    witnesses.certify(impostor_verified),
    ReplayWitnessCertificationResult::WitnessRefereeMismatch,
  )
  let same_checkpoint = EvidenceCollector::new(hasher, verifier, prepared, [])
  match
    same_checkpoint.finalize(
      impostor_verified,
      0,
      replay_match=None,
      witness_certificate=certificate,
    ) {
    Deferred(@audit.CheckpointDecision::Pending) => ()
    _ => fail("witness certificate crossed referee identity")
  }
  let other = replay_witness_prepared(
    hasher,
    referee,
    roster,
    1,
    event_root="other-pvp-events",
  )
  let other_verified = open_replay_witness_checkpoint(
    hasher, verifier, referee, other,
  )
  let other_collector = EvidenceCollector::new(hasher, verifier, other, [])
  match
    other_collector.finalize(
      other_verified,
      0,
      replay_match=None,
      witness_certificate=certificate,
    ) {
    Deferred(@audit.CheckpointDecision::Pending) => ()
    _ => fail("witness certificate crossed checkpoint digests")
  }
}

///|
test "witness certificate resolves a challenged participant checkpoint" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let challenger = @bft.MockSigner::new("challenger")
  let (signers, roster) = replay_witness_roster(4)
  let prepared = replay_witness_prepared(hasher, referee, roster, 1)
  let verified = open_replay_witness_checkpoint(
    hasher, verifier, referee, prepared,
  )
  let witnesses = replay_witness_collector_or_fail(
    hasher, verifier, prepared, referee, roster, 1,
  )
  for index in 0..<3 {
    ignore(
      witnesses.deliver(
        sign_replay_witness_attestation(
          hasher,
          signers[index],
          prepared,
          roster[index].id,
          Approve,
        ),
      ),
    )
  }
  let certificate = match witnesses.certify(verified) {
    WitnessCertified(value) => value
    _ => fail("expected replay witness certificate")
  }
  let participants = EvidenceCollector::new(hasher, verifier, prepared, [
    { id: "challenger", key: challenger.public_key() },
  ])
  ignore(
    participants.deliver(
      sign_attestation(hasher, challenger, prepared, "challenger", Challenge),
    ),
  )
  match
    participants.finalize(
      verified,
      1,
      replay_match=None,
      witness_certificate=certificate,
    ) {
    Ready(finalized) => assert_eq(finalized.digest(), prepared.digest())
    _ => fail("witness replay did not resolve challenged checkpoint")
  }
}
