///|
priv struct PvpCentralReplayFixture {
  session_id : String
  referee_key : @bft.PublicKey
  checkpoint_digest : @bft.Digest
  bundle : @wire.PvpReplayBundle
}

///|
fn accepted_pvp_central_event(
  adapter : @bft.BFTAdapter,
  signed : @bft.SignedEvent,
) -> @bft.AuthenticatedEvent raise Error {
  match adapter.deliver(signed) {
    Accepted(source) => source
    _ => fail("expected authenticated PvP fixture event")
  }
}

///|
fn pvp_central_replay_fixture() -> PvpCentralReplayFixture raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let alice = @bft.MockSigner::new("alice")
  let bob = @bft.MockSigner::new("bob")
  let session_id = "pvp:central-replay"
  let adapter = @bft.BFTAdapter::new(hasher, verifier, session_id~)
  assert_true(
    adapter.register_peer(@types.PeerId("referee"), referee.public_key()),
  )
  assert_true(adapter.register_peer(@types.PeerId("alice"), alice.public_key()))
  assert_true(adapter.register_peer(@types.PeerId("bob"), bob.public_key()))
  let config = @replay.PvpEpochConfig::{
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
  let teams : Array[@replay.PvpTeam] = [
    { team_id: "blue", initial_score: 0 },
    { team_id: "orange", initial_score: 0 },
  ]
  let players : Array[@replay.PvpPlayer] = [
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
  ]
  let intent = @replay.PvpCommandIntent::{
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
  let signed_input = adapter.sign(alice, input_event, [])
  let input = accepted_pvp_central_event(adapter, signed_input)
  let observed = @replay.PvpCommandReceipt::{
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
  let signed_receipt = adapter.sign(referee, receipt_event, [input.digest()])
  let receipt = accepted_pvp_central_event(adapter, signed_receipt)
  let witness_signers : Array[@bft.MockSigner] = []
  let witnesses : Array[@witness_manifest.ReplayWitnessIdentity] = []
  for index in 0..<4 {
    let id = "witness-" + index.to_string()
    let signer = @bft.MockSigner::new(id)
    witness_signers.push(signer)
    witnesses.push({ id, key: signer.public_key() })
  }
  let command = @replay.PvpCommandEvidence::{ input, receipt, intent, observed }
  let candidate = match
    @replay.prepare_pvp_epoch(
      hasher,
      session_id~,
      referee_key=referee.public_key(),
      config~,
      teams~,
      players~,
      transcript=[command],
      witnesses~,
      max_faults=1,
    ) {
    PvpCandidateReady(value) => value
    _ => fail("expected PvP central replay candidate")
  }
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id,
    epoch: config.epoch,
    previous_checkpoint: config.previous_checkpoint,
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: candidate.public_state_root(),
    asset_delta_root: candidate.asset_delta_root(),
    hidden_state_commitment: None,
  })
  let signed_checkpoint = @checkpoint.sign_prepared_checkpoint(
    referee, prepared,
  )
  let attestations : Array[@attestation.SignedAttestation] = []
  for index in 0..<3 {
    attestations.push(
      @attestation.sign_replay_witness_attestation(
        hasher,
        witness_signers[index],
        prepared,
        witnesses[index].id,
        @attestation.AttestationChoice::Approve,
      ),
    )
  }
  {
    session_id,
    referee_key: referee.public_key(),
    checkpoint_digest: signed_checkpoint.digest,
    bundle: {
      referee_peer_id: "referee",
      signed_checkpoint,
      config,
      teams,
      players,
      witnesses,
      max_faults: 1,
      commands: [
        { input: signed_input, receipt: signed_receipt, intent, observed },
      ],
      attestations,
    },
  }
}

///|
fn verify_pvp_fixture(
  fixture : PvpCentralReplayFixture,
  bundle : @wire.PvpReplayBundle,
) -> PvpCentralReplayResult {
  verify_pvp_replay_bundle(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    @wire.encode_pvp_replay_bundle(bundle),
    expected_session_id=fixture.session_id,
    expected_referee_key=fixture.referee_key,
    expected_checkpoint_digest=fixture.checkpoint_digest,
    limits=@wire.PvpReplayWireLimits::default(),
  )
}

///|
test "central PvP worker authenticates replay and n-f witness certificate" {
  let fixture = pvp_central_replay_fixture()
  match verify_pvp_fixture(fixture, fixture.bundle) {
    PvpReplayVerified(verified) => {
      assert_eq(verified.checkpoint_digest(), fixture.checkpoint_digest)
      assert_eq(verified.session_id(), fixture.session_id)
      assert_eq(verified.accepted_command_count(), 1)
      assert_eq(verified.approval_count(), 3)
      assert_eq(verified.required_approvals(), 3)
      assert_eq(verified.player_states(), [
        { player_id: "alice", team_id: "blue", position_x: 0, hp: 10 },
        { player_id: "bob", team_id: "orange", position_x: 2, hp: 0 },
      ])
      assert_eq(verified.team_states(), [
        { team_id: "orange", score: 0 },
        { team_id: "blue", score: 1 },
      ])
    }
    _ => fail("expected verified central PvP replay")
  }
}

///|
test "central PvP worker fails closed below witness quorum" {
  let fixture = pvp_central_replay_fixture()
  let attestations = fixture.bundle.attestations
  let bundle = @wire.PvpReplayBundle::{
    ..fixture.bundle,
    attestations: [attestations[0], attestations[1]],
  }
  assert_eq(
    verify_pvp_fixture(fixture, bundle),
    PvpCentralReplayResult::PvpReplayRefused(
      PvpCentralReplayRefusal::PvpWitnessQuorumPending(2, 3),
    ),
  )
}

///|
test "central PvP worker rejects invalid event and witness signatures" {
  let fixture = pvp_central_replay_fixture()
  let command = fixture.bundle.commands[0]
  let invalid_event = @wire.PvpReplayBundle::{
    ..fixture.bundle,
    commands: [
      {
        ..command,
        input: { ..command.input, signature: @bft.Signature("forged") },
      },
    ],
  }
  match verify_pvp_fixture(fixture, invalid_event) {
    PvpReplayRefused(PvpEventAuthenticationRefused(_)) => ()
    _ => fail("expected PvP event authentication refusal")
  }
  let attestations = fixture.bundle.attestations
  let invalid_attestation = @wire.PvpReplayBundle::{
    ..fixture.bundle,
    attestations: [
      { ..attestations[0], signature: @bft.Signature("forged-witness") },
      attestations[1],
      attestations[2],
    ],
  }
  match verify_pvp_fixture(fixture, invalid_attestation) {
    PvpReplayRefused(PvpWitnessEvidenceRefused(_)) => ()
    _ => fail("expected PvP witness authentication refusal")
  }
}

///|
test "central PvP worker rejects a foreign expected checkpoint" {
  let fixture = pvp_central_replay_fixture()
  assert_eq(
    verify_pvp_replay_bundle(
      @bft.FnvHasher::new(),
      @bft.MockVerifier::new(),
      @wire.encode_pvp_replay_bundle(fixture.bundle),
      expected_session_id=fixture.session_id,
      expected_referee_key=fixture.referee_key,
      expected_checkpoint_digest=@bft.Digest("other-checkpoint"),
      limits=@wire.PvpReplayWireLimits::default(),
    ),
    PvpCentralReplayResult::PvpReplayRefused(
      PvpCentralReplayRefusal::PvpExpectedCheckpointMismatch,
    ),
  )
}
