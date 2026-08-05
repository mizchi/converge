///|
priv struct TestPvpCommand {
  player_id : String
  counter : Int
  tick : Int
  to_x : Int
  target_id : String?
}

///|
fn pvp_config(damage? : Int = 6) -> PvpEpochConfig {
  {
    match_id: "match-1",
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    player_max_hp: 10,
    ticks_per_epoch: 8,
    max_late_ticks: 2,
    max_move_distance: 3,
    arena_min_x: -10,
    arena_max_x: 10,
    attack_range: 3,
    attack_damage: damage,
    score_per_elimination: 1,
  }
}

///|
fn pvp_teams() -> Array[PvpTeam] {
  [
    { team_id: "blue", initial_score: 0 },
    { team_id: "orange", initial_score: 0 },
  ]
}

///|
fn pvp_players() -> Array[PvpPlayer] {
  [
    {
      player_id: "alice",
      public_key: @bft.PublicKey("alice"),
      team_id: "blue",
      initial_x: 0,
      initial_hp: 10,
    },
    {
      player_id: "bob",
      public_key: @bft.PublicKey("bob"),
      team_id: "orange",
      initial_x: 2,
      initial_hp: 10,
    },
  ]
}

///|
fn pvp_witnesses() -> Array[@witness_manifest.ReplayWitnessIdentity] {
  [
    { id: "witness-0", key: @bft.PublicKey("witness-0") },
    { id: "witness-1", key: @bft.PublicKey("witness-1") },
    { id: "witness-2", key: @bft.PublicKey("witness-2") },
    { id: "witness-3", key: @bft.PublicKey("witness-3") },
  ]
}

///|
fn accept_pvp_event(
  adapter : @bft.BFTAdapter,
  signer : &@bft.Signer,
  event : @types.Event,
  dependency_hashes : Array[@bft.Digest],
) -> @bft.AuthenticatedEvent raise Error {
  match adapter.deliver(adapter.sign(signer, event, dependency_hashes)) {
    Accepted(source) => source
    _ => fail("expected authenticated PvP event")
  }
}

///|
fn pvp_transcript(
  specs : Array[TestPvpCommand],
  damage? : Int = 6,
) -> Array[PvpCommandEvidence] raise Error {
  let config = pvp_config(damage~)
  let hasher = @bft.FnvHasher::new()
  let adapter = @bft.BFTAdapter::new(
    hasher,
    @bft.MockVerifier::new(),
    session_id="pvp-session",
  )
  let referee = @bft.MockSigner::new("referee")
  let alice = @bft.MockSigner::new("alice")
  let bob = @bft.MockSigner::new("bob")
  assert_true(
    adapter.register_peer(@types.PeerId("referee"), referee.public_key()),
  )
  assert_true(adapter.register_peer(@types.PeerId("alice"), alice.public_key()))
  assert_true(adapter.register_peer(@types.PeerId("bob"), bob.public_key()))
  let transcript : Array[PvpCommandEvidence] = []
  for index, spec in specs {
    let signer : &@bft.Signer = if spec.player_id == "alice" {
      alice
    } else {
      bob
    }
    let intent = PvpCommandIntent::{
      match_id: config.match_id,
      epoch: config.epoch,
      base_checkpoint_digest: config.previous_checkpoint,
      tick: spec.tick,
      player_id: spec.player_id,
      move_to_x: spec.to_x,
      attack_target_id: spec.target_id,
    }
    let input_event = make_pvp_command_event(
      peer=@types.PeerId(spec.player_id),
      counter=spec.counter,
      lamport=index * 2,
      deps=[],
      intent~,
    )
    let input = accept_pvp_event(adapter, signer, input_event, [])
    let observed = PvpCommandReceipt::{
      command_digest: input.digest(),
      received_tick: spec.tick + 1,
    }
    let receipt_event = make_pvp_command_receipt_event(
      peer=@types.PeerId("referee"),
      counter=index,
      lamport=index * 2 + 1,
      deps=[input_event.id],
      receipt=observed,
    )
    let receipt = accept_pvp_event(adapter, referee, receipt_event, [
      input.digest(),
    ])
    transcript.push({ input, receipt, intent, observed })
  }
  transcript
}

///|
fn prepare_pvp(
  transcript : Array[PvpCommandEvidence],
  damage? : Int = 6,
) -> PvpEpochCandidateResult {
  prepare_pvp_epoch(
    @bft.FnvHasher::new(),
    session_id="pvp-session",
    referee_key=@bft.PublicKey("referee"),
    config=pvp_config(damage~),
    teams=pvp_teams(),
    players=pvp_players(),
    transcript~,
    witnesses=pvp_witnesses(),
    max_faults=1,
  )
}

///|
fn pvp_checkpoint(
  candidate : PvpEpochCandidate,
  public_state_root? : @bft.Digest,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let hasher = @bft.FnvHasher::new()
  let referee = @bft.MockSigner::new("referee")
  let signed = @checkpoint.sign_checkpoint(hasher, referee, {
    session_id: "pvp-session",
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: public_state_root.unwrap_or(
      candidate.public_state_root(),
    ),
    asset_delta_root: candidate.asset_delta_root(),
    hidden_state_commitment: None,
  })
  match
    @checkpoint.open_checkpoint(
      hasher,
      @bft.MockVerifier::new(),
      referee.public_key(),
      signed,
    ) {
    Opened(verified) => verified
    _ => fail("expected verified PvP checkpoint")
  }
}

///|
test "simultaneous PvP wipe and roots are independent of transcript order" {
  let transcript = pvp_transcript([
    { player_id: "alice", counter: 0, tick: 0, to_x: 0, target_id: Some("bob") },
    { player_id: "bob", counter: 0, tick: 0, to_x: 2, target_id: Some("alice") },
    { player_id: "alice", counter: 1, tick: 1, to_x: 0, target_id: Some("bob") },
    { player_id: "bob", counter: 1, tick: 1, to_x: 2, target_id: Some("alice") },
  ])
  let reverse = [transcript[3], transcript[2], transcript[1], transcript[0]]
  match (prepare_pvp(transcript), prepare_pvp(reverse)) {
    (PvpCandidateReady(left), PvpCandidateReady(right)) => {
      assert_eq(left.game_manifest_digest(), right.game_manifest_digest())
      assert_eq(left.manifest_digest(), right.manifest_digest())
      assert_eq(left.event_root(), right.event_root())
      assert_eq(left.public_state_root(), right.public_state_root())
      let checkpoint = pvp_checkpoint(left)
      match finalize_pvp_epoch(left, checkpoint) {
        PvpEpochFinalized(resolution) => {
          assert_eq(resolution.player_states(), [
            { player_id: "alice", team_id: "blue", position_x: 0, hp: 0 },
            { player_id: "bob", team_id: "orange", position_x: 2, hp: 0 },
          ])
          assert_eq(resolution.team_states(), [
            { team_id: "orange", score: 1 },
            { team_id: "blue", score: 1 },
          ])
          assert_eq(resolution.accepted_command_count(), 4)
          assert_eq(resolution.equivocator_ids(), [])
          assert_eq(
            resolution.replay_match().checkpoint_digest(),
            checkpoint.digest(),
          )
        }
        _ => fail("valid PvP epoch did not finalize")
      }
    }
    _ => fail("valid PvP epoch did not prepare")
  }
}

///|
test "movement resolves before attacks so telegraphed range has client-time agency" {
  let transcript = pvp_transcript([
    { player_id: "alice", counter: 0, tick: 0, to_x: 0, target_id: Some("bob") },
    { player_id: "bob", counter: 0, tick: 0, to_x: 5, target_id: None },
  ])
  match prepare_pvp(transcript) {
    PvpCandidateReady(candidate) =>
      match finalize_pvp_epoch(candidate, pvp_checkpoint(candidate)) {
        PvpEpochFinalized(resolution) => {
          assert_eq(resolution.player_states(), [
            { player_id: "alice", team_id: "blue", position_x: 0, hp: 10 },
            { player_id: "bob", team_id: "orange", position_x: 5, hp: 10 },
          ])
          assert_eq(resolution.team_states(), [
            { team_id: "orange", score: 0 },
            { team_id: "blue", score: 0 },
          ])
        }
        _ => fail("moving-target epoch did not finalize")
      }
    _ => fail("moving-target epoch did not prepare")
  }
}

///|
test "two commands in one player tick become an order-independent equivocation" {
  let transcript = pvp_transcript(
    [
      {
        player_id: "alice",
        counter: 0,
        tick: 0,
        to_x: 0,
        target_id: Some("bob"),
      },
      { player_id: "alice", counter: 1, tick: 0, to_x: 3, target_id: None },
      {
        player_id: "bob",
        counter: 0,
        tick: 0,
        to_x: 2,
        target_id: Some("alice"),
      },
    ],
    damage=10,
  )
  let reverse = [transcript[2], transcript[1], transcript[0]]
  match (prepare_pvp(transcript, damage=10), prepare_pvp(reverse, damage=10)) {
    (PvpCandidateReady(left), PvpCandidateReady(right)) => {
      assert_eq(left.public_state_root(), right.public_state_root())
      match finalize_pvp_epoch(left, pvp_checkpoint(left)) {
        PvpEpochFinalized(resolution) => {
          assert_eq(resolution.equivocator_ids(), ["alice"])
          assert_eq(resolution.accepted_command_count(), 1)
          assert_eq(resolution.player_states(), [
            { player_id: "alice", team_id: "blue", position_x: 0, hp: 0 },
            { player_id: "bob", team_id: "orange", position_x: 2, hp: 10 },
          ])
          assert_eq(resolution.team_states(), [
            { team_id: "orange", score: 1 },
            { team_id: "blue", score: 0 },
          ])
        }
        _ => fail("equivocation epoch did not finalize")
      }
    }
    _ => fail("equivocation epoch did not prepare deterministically")
  }
}

///|
test "PvP checkpoint must commit the replayed public state" {
  let transcript = pvp_transcript([
    { player_id: "alice", counter: 0, tick: 0, to_x: 0, target_id: Some("bob") },
  ])
  match prepare_pvp(transcript) {
    PvpCandidateReady(candidate) =>
      assert_eq(
        finalize_pvp_epoch(
          candidate,
          pvp_checkpoint(
            candidate,
            public_state_root=@bft.Digest("forged-state"),
          ),
        ),
        PvpEpochFinalizeResult::PvpFinalizeRefused(
          PvpEpochRefusal::CheckpointPublicStateRootMismatch,
        ),
      )
    _ => fail("valid PvP transcript did not prepare")
  }
}

///|
test "PvP game manifest is independent of team and player roster order" {
  let hasher = @bft.FnvHasher::new()
  let teams = pvp_teams()
  let players = pvp_players()
  assert_eq(
    pvp_epoch_game_manifest(
      hasher,
      "pvp-session",
      @bft.PublicKey("referee"),
      pvp_config(),
      teams,
      players,
    ),
    pvp_epoch_game_manifest(
      hasher,
      "pvp-session",
      @bft.PublicKey("referee"),
      pvp_config(),
      [teams[1], teams[0]],
      [players[1], players[0]],
    ),
  )
}

///|
test "out-of-arena movement is rejected before unsafe distance arithmetic" {
  let transcript = pvp_transcript([
    {
      player_id: "alice",
      counter: 0,
      tick: 0,
      to_x: 2147483647,
      target_id: Some("bob"),
    },
  ])
  match prepare_pvp(transcript) {
    PvpCandidateReady(candidate) =>
      match finalize_pvp_epoch(candidate, pvp_checkpoint(candidate)) {
        PvpEpochFinalized(resolution) => {
          assert_eq(resolution.accepted_command_count(), 0)
          assert_eq(resolution.player_states(), [
            { player_id: "alice", team_id: "blue", position_x: 0, hp: 10 },
            { player_id: "bob", team_id: "orange", position_x: 2, hp: 10 },
          ])
        }
        _ => fail("bounded invalid-command epoch did not finalize")
      }
    _ => fail("authenticated invalid command should remain auditable")
  }
}

///|
test "PvP cooldown suppresses only the illegal attack and commits the violator" {
  let transcript = pvp_transcript([
    { player_id: "alice", counter: 0, tick: 0, to_x: 0, target_id: Some("bob") },
    { player_id: "alice", counter: 1, tick: 1, to_x: 1, target_id: Some("bob") },
  ])
  match
    prepare_pvp_epoch(
      @bft.FnvHasher::new(),
      session_id="pvp-session",
      referee_key=@bft.PublicKey("referee"),
      config=pvp_config(),
      teams=pvp_teams(),
      players=pvp_players(),
      transcript~,
      witnesses=pvp_witnesses(),
      max_faults=1,
      attack_cooldown_ticks=2,
    ) {
    PvpCandidateReady(candidate) =>
      match finalize_pvp_epoch(candidate, pvp_checkpoint(candidate)) {
        PvpEpochFinalized(resolution) => {
          assert_eq(resolution.player_states(), [
            { player_id: "alice", team_id: "blue", position_x: 1, hp: 10 },
            { player_id: "bob", team_id: "orange", position_x: 2, hp: 4 },
          ])
          assert_eq(resolution.cooldown_violator_ids(), ["alice"])
          assert_eq(resolution.accepted_command_count(), 2)
        }
        _ => fail("cooldown epoch did not finalize")
      }
    _ => fail("cooldown epoch did not prepare")
  }
}

///|
test "PvP objective scores only uncontested living-team occupation" {
  let config = { ..pvp_config(), ticks_per_epoch: 3 }
  let objective = PvpObjectiveRule::{
    center_x: 0,
    radius: 1,
    score_per_tick: 2,
  }
  match
    prepare_pvp_epoch(
      @bft.FnvHasher::new(),
      session_id="pvp-session",
      referee_key=@bft.PublicKey("referee"),
      config~,
      teams=pvp_teams(),
      players=pvp_players(),
      transcript=[],
      witnesses=pvp_witnesses(),
      max_faults=1,
      objective_rule=Some(objective),
    ) {
    PvpCandidateReady(candidate) =>
      match finalize_pvp_epoch(candidate, pvp_checkpoint(candidate)) {
        PvpEpochFinalized(resolution) =>
          assert_eq(resolution.team_states(), [
            { team_id: "orange", score: 0 },
            { team_id: "blue", score: 6 },
          ])
        _ => fail("objective epoch did not finalize")
      }
    _ => fail("objective epoch did not prepare")
  }
  assert_true(
    pvp_epoch_game_manifest(
      @bft.FnvHasher::new(),
      "pvp-session",
      @bft.PublicKey("referee"),
      config,
      pvp_teams(),
      pvp_players(),
      objective_rule=Some(objective),
    ) !=
    pvp_epoch_game_manifest(
      @bft.FnvHasher::new(),
      "pvp-session",
      @bft.PublicKey("referee"),
      config,
      pvp_teams(),
      pvp_players(),
    ),
  )
}
