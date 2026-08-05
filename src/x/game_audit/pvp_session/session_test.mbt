///|
struct PvpSessionFixture {
  hasher : &@bft.Hasher
  verifier : &@bft.Verifier
  referee : &@bft.Signer
  prepared : @checkpoint.PreparedCheckpoint
  verified : @checkpoint.VerifiedCheckpoint
  resolution : @replay.PvpEpochResolution
  signers : Array[@bft.MockSigner]
  participants : Array[@attestation.Participant]
}

///|
fn pvp_session_fixture() -> PvpSessionFixture raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let alice = @bft.MockSigner::new("alice")
  let bob = @bft.MockSigner::new("bob")
  let adapter = @bft.BFTAdapter::new(hasher, verifier, session_id="pvp-session")
  assert_true(
    adapter.register_peer(@types.PeerId("referee"), referee.public_key()),
  )
  assert_true(adapter.register_peer(@types.PeerId("alice"), alice.public_key()))
  assert_true(adapter.register_peer(@types.PeerId("bob"), bob.public_key()))
  let config : @replay.PvpEpochConfig = {
    match_id: "match-1",
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    player_max_hp: 10,
    ticks_per_epoch: 4,
    max_late_ticks: 2,
    max_move_distance: 3,
    arena_min_x: -10,
    arena_max_x: 10,
    attack_range: 3,
    attack_damage: 10,
    score_per_elimination: 1,
  }
  let intent : @replay.PvpCommandIntent = {
    match_id: config.match_id,
    epoch: config.epoch,
    base_checkpoint_digest: config.previous_checkpoint,
    tick: 0,
    player_id: "alice",
    move_to_x: 0,
    attack_target_id: Some("bob"),
  }
  let input_event = @replay.make_pvp_command_event(
    peer=@types.PeerId("alice"),
    counter=0,
    lamport=0,
    deps=[],
    intent~,
  )
  let input = match adapter.deliver(adapter.sign(alice, input_event, [])) {
    Accepted(source) => source
    _ => fail("expected authenticated PvP command")
  }
  let observed : @replay.PvpCommandReceipt = {
    command_digest: input.digest(),
    received_tick: 1,
  }
  let receipt_event = @replay.make_pvp_command_receipt_event(
    peer=@types.PeerId("referee"),
    counter=0,
    lamport=1,
    deps=[input_event.id],
    receipt=observed,
  )
  let receipt = match
    adapter.deliver(adapter.sign(referee, receipt_event, [input.digest()])) {
    Accepted(source) => source
    _ => fail("expected authenticated PvP receipt")
  }
  let signers : Array[@bft.MockSigner] = []
  let participants : Array[@attestation.Participant] = []
  let identities : Array[@witness_manifest.ReplayWitnessIdentity] = []
  for index in 0..<4 {
    let id = "witness-" + index.to_string()
    let signer = @bft.MockSigner::new(id)
    signers.push(signer)
    participants.push({ id, key: signer.public_key() })
    identities.push({ id, key: signer.public_key() })
  }
  let candidate = match
    @replay.prepare_pvp_epoch(
      hasher,
      session_id="pvp-session",
      referee_key=referee.public_key(),
      config~,
      teams=[
        { team_id: "blue", initial_score: 0 },
        { team_id: "orange", initial_score: 0 },
      ],
      players=[
        {
          player_id: "alice",
          public_key: alice.public_key(),
          team_id: "blue",
          initial_x: 0,
          initial_hp: 10,
        },
        {
          player_id: "bob",
          public_key: bob.public_key(),
          team_id: "orange",
          initial_x: 2,
          initial_hp: 10,
        },
      ],
      transcript=[{ input, receipt, intent, observed }],
      witnesses=identities,
      max_faults=1,
    ) {
    PvpCandidateReady(value) => value
    _ => fail("expected deterministic PvP candidate")
  }
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id: "pvp-session",
    epoch: config.epoch,
    previous_checkpoint: config.previous_checkpoint,
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: candidate.public_state_root(),
    asset_delta_root: candidate.asset_delta_root(),
    hidden_state_commitment: None,
  })
  let signed = @checkpoint.sign_prepared_checkpoint(referee, prepared)
  let verified = match
    @checkpoint.open_checkpoint(hasher, verifier, referee.public_key(), signed) {
    Opened(value) => value
    _ => fail("expected verified referee checkpoint")
  }
  let resolution = match @replay.finalize_pvp_epoch(candidate, verified) {
    PvpEpochFinalized(value) => value
    _ => fail("expected finalized PvP replay")
  }
  {
    hasher,
    verifier,
    referee,
    prepared,
    verified,
    resolution,
    signers,
    participants,
  }
}

///|
test "N:N witnesses sign only after exact PvP replay and reach n-f certificate" {
  let fixture = pvp_session_fixture()
  let session = match
    prepare_pvp_replay_witness_session(
      fixture.hasher,
      fixture.verifier,
      fixture.prepared,
      fixture.resolution,
      referee_key=fixture.referee.public_key(),
      witnesses=fixture.participants,
      max_faults=1,
    ) {
    PvpWitnessSessionReady(value) => value
    _ => fail("expected replay-linked witness session")
  }
  assert_eq(session.required_approvals(), 3)
  for index in 0..<3 {
    let signed = match
      sign_pvp_replay_witness(
        fixture.hasher,
        fixture.signers[index],
        fixture.prepared,
        fixture.resolution,
        referee_key=fixture.referee.public_key(),
        witness_id=fixture.participants[index].id,
        choice=@attestation.AttestationChoice::Approve,
      ) {
      PvpReplayWitnessSigned(value) => value
      _ => fail("exact replay was not signable")
    }
    assert_eq(
      session.deliver(signed),
      @attestation.EvidenceDeliveryResult::Accepted,
    )
  }
  match session.certify(fixture.verified) {
    WitnessCertified(certificate) => {
      assert_eq(certificate.approval_count(), 3)
      assert_eq(certificate.checkpoint_digest(), fixture.prepared.digest())
    }
    _ => fail("n-f PvP replay witnesses did not certify")
  }
}

///|
test "PvP replay witness signing cannot cross checkpoint or referee" {
  let fixture = pvp_session_fixture()
  let other = @checkpoint.prepare_checkpoint(fixture.hasher, {
    ..fixture.prepared.checkpoint(),
    event_root: @bft.Digest("other-events"),
  })
  assert_eq(
    sign_pvp_replay_witness(
      fixture.hasher,
      fixture.signers[0],
      other,
      fixture.resolution,
      referee_key=fixture.referee.public_key(),
      witness_id=fixture.participants[0].id,
      choice=@attestation.AttestationChoice::Approve,
    ),
    PvpReplayWitnessSigningResult::PvpReplayWitnessCheckpointMismatch,
  )
  assert_eq(
    sign_pvp_replay_witness(
      fixture.hasher,
      fixture.signers[0],
      fixture.prepared,
      fixture.resolution,
      referee_key=@bft.PublicKey("other-referee"),
      witness_id=fixture.participants[0].id,
      choice=@attestation.AttestationChoice::Approve,
    ),
    PvpReplayWitnessSigningResult::PvpReplayWitnessRefereeMismatch,
  )
}
