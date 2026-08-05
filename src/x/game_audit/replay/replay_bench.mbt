///|
fn benchmark_replay_input() -> (@bft.AuthenticatedEvent, AssetEffect) {
  let effect = AssetEffect::Create(
    asset_id="asset-777",
    recipient_id="player-1",
    item_type="loot",
    quantity=1,
    output_index=0,
  )
  let adapter = @bft.BFTAdapter::new(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    session_id="benchmark",
  )
  let signer = @bft.MockSigner::new("game-server")
  ignore(
    adapter.register_peer(@types.PeerId("game-server"), signer.public_key()),
  )
  let event = make_asset_effect_event(
    peer=@types.PeerId("game-server"),
    counter=777,
    lamport=778,
    deps=[],
    effect~,
  )
  match adapter.deliver(adapter.sign(signer, event, [])) {
    Accepted(source) => (source, effect)
    _ => abort("benchmark source authentication failed")
  }
}

///|
test "bench: replay 1000 canonical asset effects" (b : @bench.T) {
  let (source, effect) = benchmark_replay_input()
  let kernel = CanonicalAssetKernel::new(
    @bft.FnvHasher::new(),
    effect_author=@bft.PublicKey("game-server"),
  )
  let engine = ReplayEngine::new(kernel, session_id="benchmark")
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(engine.replay(source, effect))
    }
  })
}

///|
test "bench: match 1000 replay capabilities" (b : @bench.T) {
  let (source, effect) = benchmark_replay_input()
  let kernel = CanonicalAssetKernel::new(
    @bft.FnvHasher::new(),
    effect_author=@bft.PublicKey("game-server"),
  )
  let engine = ReplayEngine::new(kernel, session_id="benchmark")
  let capability = match engine.replay(source, effect) {
    Replayed(value) => value
    Refused(_) => abort("benchmark replay failed")
  }
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        capability.matches(
          session_id="benchmark",
          manifest_digest=capability.manifest_digest(),
          source_digest=source.digest(),
          effect~,
        ),
      )
    }
  })
}

///|
priv struct DungeonBenchmarkInput {
  config : TelegraphDungeonConfig
  players : Array[DungeonPlayer]
  checkpoint : @checkpoint.VerifiedCheckpoint
  telegraph : @bft.AuthenticatedEvent
  attack : TelegraphedAttack
  evidence : Array[DodgeEvidence]
}

///|
fn benchmark_dungeon_input(player_count : Int) -> DungeonBenchmarkInput {
  let hasher = @bft.FnvHasher::new()
  let adapter = @bft.BFTAdapter::new(
    hasher,
    @bft.MockVerifier::new(),
    session_id="dungeon-benchmark",
  )
  let authority = @bft.MockSigner::new("game-server")
  ignore(
    adapter.register_peer(@types.PeerId("game-server"), authority.public_key()),
  )
  let config = TelegraphDungeonConfig::{
    min_reaction_ticks: 2,
    max_backdate_ticks: 2,
    max_dodge_distance: 5,
    arena_min_x: -10,
    arena_max_x: 10,
    loot_item_type: "benchmark-token",
  }
  let attack = TelegraphedAttack::{
    attack_id: "boss-cleave",
    visible_tick: 10,
    resolve_tick: 16,
    center_x: 0,
    radius: 2,
  }
  let telegraph_event = make_dungeon_telegraph_event(
    peer=@types.PeerId("game-server"),
    counter=0,
    lamport=1,
    deps=[],
    attack~,
  )
  let telegraph = match
    adapter.deliver(adapter.sign(authority, telegraph_event, [])) {
    Accepted(source) => source
    _ => abort("benchmark telegraph authentication failed")
  }
  let players : Array[DungeonPlayer] = []
  let evidence : Array[DodgeEvidence] = []
  for index in 0..<player_count {
    let player_id = "player-" + index.to_string()
    let signer = @bft.MockSigner::new(player_id)
    ignore(adapter.register_peer(@types.PeerId(player_id), signer.public_key()))
    players.push({ player_id, public_key: signer.public_key(), initial_x: 0 })
    let intent = DodgeIntent::{
      attack_id: attack.attack_id,
      player_id,
      telegraph_digest: telegraph.digest(),
      client_tick: 13,
      to_x: 5,
    }
    let input_event = make_dungeon_dodge_event(
      peer=@types.PeerId(player_id),
      counter=0,
      lamport=2,
      deps=[telegraph_event.id],
      intent~,
    )
    let input = match
      adapter.deliver(adapter.sign(signer, input_event, [telegraph.digest()])) {
      Accepted(source) => source
      _ => abort("benchmark dodge authentication failed")
    }
    let observed = DodgeReceipt::{
      input_digest: input.digest(),
      received_tick: 14,
    }
    let receipt_event = make_dungeon_receipt_event(
      peer=@types.PeerId("game-server"),
      counter=index + 1,
      lamport=index + 3,
      deps=[input_event.id],
      receipt=observed,
    )
    let receipt = match
      adapter.deliver(adapter.sign(authority, receipt_event, [input.digest()])) {
      Accepted(source) => source
      _ => abort("benchmark receipt authentication failed")
    }
    evidence.push({ input, receipt, intent, observed })
  }
  let manifest = telegraph_dungeon_manifest(
    hasher,
    authority.public_key(),
    config,
    players,
  )
  let event_root = dungeon_transcript_root(hasher, telegraph, evidence)
  let signed_checkpoint = @checkpoint.sign_checkpoint(hasher, authority, @checkpoint.Checkpoint::{
    session_id: "dungeon-benchmark",
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    manifest_digest: manifest,
    event_root,
    public_state_root: @bft.Digest("state"),
    asset_delta_root: @bft.Digest("delta"),
    hidden_state_commitment: None,
  })
  let checkpoint = match
    @checkpoint.open_checkpoint(
      hasher,
      @bft.MockVerifier::new(),
      authority.public_key(),
      signed_checkpoint,
    ) {
    Opened(value) => value
    _ => abort("benchmark checkpoint verification failed")
  }
  { config, players, checkpoint, telegraph, attack, evidence }
}

///|
fn run_dungeon_benchmark(
  b : @bench.T,
  input : DungeonBenchmarkInput,
  iterations : Int,
) -> Unit {
  let hasher = @bft.FnvHasher::new()
  b.bench(fn() {
    for _ in 0..<iterations {
      b.keep(
        replay_checkpointed_telegraphed_attack(
          hasher,
          session_id="dungeon-benchmark",
          authority_key=@bft.PublicKey("game-server"),
          config=input.config,
          players=input.players,
          checkpoint=input.checkpoint,
          telegraph_source=input.telegraph,
          attack=input.attack,
          dodge_evidence=input.evidence,
        ),
      )
    }
  })
}

///|
test "bench: replay 1000 checkpointed 8-player telegraphs" (b : @bench.T) {
  run_dungeon_benchmark(b, benchmark_dungeon_input(8), 1000)
}

///|
test "bench: replay 100 checkpointed 64-player telegraphs" (b : @bench.T) {
  run_dungeon_benchmark(b, benchmark_dungeon_input(64), 100)
}

///|
priv struct EncounterBenchmarkInput {
  config : DungeonEncounterConfig
  players : Array[DungeonPlayer]
  attacks : Array[DungeonEncounterAttack]
  transcripts : Array[DungeonAttackTranscript]
}

///|
fn benchmark_encounter_input(
  player_count : Int,
  attack_count : Int,
) -> EncounterBenchmarkInput {
  let hasher = @bft.FnvHasher::new()
  let adapter = @bft.BFTAdapter::new(
    hasher,
    @bft.MockVerifier::new(),
    session_id="encounter-benchmark",
  )
  let authority = @bft.MockSigner::new("game-server")
  ignore(
    adapter.register_peer(@types.PeerId("game-server"), authority.public_key()),
  )
  let config = DungeonEncounterConfig::{
    encounter_id: "benchmark-boss",
    player_max_hp: attack_count + 1,
    attack_rules: {
      min_reaction_ticks: 2,
      max_backdate_ticks: 2,
      max_dodge_distance: 5,
      arena_min_x: -10,
      arena_max_x: 10,
      loot_item_type: "benchmark-token",
    },
  }
  let players : Array[DungeonPlayer] = []
  for index in 0..<player_count {
    let player_id = "player-" + index.to_string()
    let signer = @bft.MockSigner::new(player_id)
    ignore(adapter.register_peer(@types.PeerId(player_id), signer.public_key()))
    players.push({ player_id, public_key: signer.public_key(), initial_x: 0 })
  }
  let attacks : Array[DungeonEncounterAttack] = []
  let transcripts : Array[DungeonAttackTranscript] = []
  for index in 0..<attack_count {
    let attack = TelegraphedAttack::{
      attack_id: "attack-" + index.to_string(),
      visible_tick: 10 + index * 10,
      resolve_tick: 16 + index * 10,
      center_x: 0,
      radius: 2,
    }
    let spec = DungeonEncounterAttack::{ attack, damage: 1 }
    let event = make_dungeon_telegraph_event(
      peer=@types.PeerId("game-server"),
      counter=index,
      lamport=index + 1,
      deps=[],
      attack~,
    )
    let telegraph = match adapter.deliver(adapter.sign(authority, event, [])) {
      Accepted(source) => source
      _ => abort("benchmark encounter telegraph authentication failed")
    }
    let evidence : Array[DodgeEvidence] = []
    for player_index in 0..<player_count {
      let player_id = "player-" + player_index.to_string()
      let signer = @bft.MockSigner::new(player_id)
      let intent = DodgeIntent::{
        attack_id: attack.attack_id,
        player_id,
        telegraph_digest: telegraph.digest(),
        client_tick: attack.visible_tick + 3,
        to_x: 5,
      }
      let input_event = make_dungeon_dodge_event(
        peer=@types.PeerId(player_id),
        counter=index,
        lamport=attack.visible_tick + 3,
        deps=[event.id],
        intent~,
      )
      let input = match
        adapter.deliver(adapter.sign(signer, input_event, [telegraph.digest()])) {
        Accepted(source) => source
        _ => abort("benchmark encounter dodge authentication failed")
      }
      let observed = DodgeReceipt::{
        input_digest: input.digest(),
        received_tick: attack.visible_tick + 4,
      }
      let receipt_event = make_dungeon_receipt_event(
        peer=@types.PeerId("game-server"),
        counter=attack_count + index * player_count + player_index,
        lamport=attack.visible_tick + 4,
        deps=[input_event.id],
        receipt=observed,
      )
      let receipt = match
        adapter.deliver(
          adapter.sign(authority, receipt_event, [input.digest()]),
        ) {
        Accepted(source) => source
        _ => abort("benchmark encounter receipt authentication failed")
      }
      evidence.push({ input, receipt, intent, observed })
    }
    attacks.push(spec)
    transcripts.push({
      attack_id: attack.attack_id,
      telegraph,
      dodge_evidence: evidence,
    })
  }
  { config, players, attacks, transcripts }
}

///|
fn run_encounter_benchmark(
  b : @bench.T,
  input : EncounterBenchmarkInput,
  iterations : Int,
) -> Unit {
  let hasher = @bft.FnvHasher::new()
  b.bench(fn() {
    for _ in 0..<iterations {
      match
        prepare_dungeon_encounter(
          hasher,
          session_id="encounter-benchmark",
          authority_key=@bft.PublicKey("game-server"),
          config=input.config,
          players=input.players,
          attacks=input.attacks,
          transcripts=input.transcripts,
        ) {
        CandidateReady(candidate) => b.keep(candidate.public_state_root())
        Refused(_) => abort("benchmark encounter replay failed")
      }
    }
  })
}

///|
test "bench: prepare 100 8-player 8-attack encounters" (b : @bench.T) {
  run_encounter_benchmark(b, benchmark_encounter_input(8, 8), 100)
}

///|
test "bench: prepare 10 64-player 8-attack encounters" (b : @bench.T) {
  run_encounter_benchmark(b, benchmark_encounter_input(64, 8), 10)
}

///|
priv struct PvpEpochBenchmarkInput {
  config : PvpEpochConfig
  teams : Array[PvpTeam]
  players : Array[PvpPlayer]
  transcript : Array[PvpCommandEvidence]
  witnesses : Array[@witness_manifest.ReplayWitnessIdentity]
}

///|
fn benchmark_pvp_epoch_input(
  player_count : Int,
  tick_count : Int,
) -> PvpEpochBenchmarkInput {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let adapter = @bft.BFTAdapter::new(
    hasher,
    verifier,
    session_id="pvp-benchmark",
  )
  let referee = @bft.MockSigner::new("referee")
  ignore(adapter.register_peer(@types.PeerId("referee"), referee.public_key()))
  let config = PvpEpochConfig::{
    match_id: "benchmark-match",
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    player_max_hp: 1000,
    ticks_per_epoch: tick_count,
    max_late_ticks: 2,
    max_move_distance: 3,
    arena_min_x: -10,
    arena_max_x: 10,
    attack_range: 3,
    attack_damage: 1,
    score_per_elimination: 1,
  }
  let teams : Array[PvpTeam] = [
    { team_id: "blue", initial_score: 0 },
    { team_id: "orange", initial_score: 0 },
  ]
  let players : Array[PvpPlayer] = []
  for player_index in 0..<player_count {
    let player_id = "player-" + player_index.to_string()
    let signer = @bft.MockSigner::new(player_id)
    ignore(adapter.register_peer(@types.PeerId(player_id), signer.public_key()))
    players.push({
      player_id,
      public_key: signer.public_key(),
      team_id: if player_index % 2 == 0 {
        "blue"
      } else {
        "orange"
      },
      initial_x: if player_index % 2 == 0 {
        0
      } else {
        1
      },
      initial_hp: config.player_max_hp,
    })
  }
  let transcript : Array[PvpCommandEvidence] = []
  for tick in 0..<tick_count {
    for player_index in 0..<player_count {
      let player = players[player_index]
      let target_index = if player_index % 2 == 0 {
        (player_index + 1) % player_count
      } else {
        player_index - 1
      }
      let signer = @bft.MockSigner::new(player.player_id)
      let intent = PvpCommandIntent::{
        match_id: config.match_id,
        epoch: config.epoch,
        base_checkpoint_digest: config.previous_checkpoint,
        tick,
        player_id: player.player_id,
        move_to_x: player.initial_x,
        attack_target_id: Some(players[target_index].player_id),
      }
      let input_event = make_pvp_command_event(
        peer=@types.PeerId(player.player_id),
        counter=tick,
        lamport=tick * 2,
        deps=[],
        intent~,
      )
      let input = match adapter.deliver(adapter.sign(signer, input_event, [])) {
        Accepted(source) => source
        _ => abort("benchmark PvP command authentication failed")
      }
      let observed = PvpCommandReceipt::{
        command_digest: input.digest(),
        received_tick: tick + 1,
      }
      let receipt_counter = tick * player_count + player_index
      let receipt_event = make_pvp_command_receipt_event(
        peer=@types.PeerId("referee"),
        counter=receipt_counter,
        lamport=tick * 2 + 1,
        deps=[input_event.id],
        receipt=observed,
      )
      let receipt = match
        adapter.deliver(adapter.sign(referee, receipt_event, [input.digest()])) {
        Accepted(source) => source
        _ => abort("benchmark PvP receipt authentication failed")
      }
      transcript.push({ input, receipt, intent, observed })
    }
  }
  let witnesses : Array[@witness_manifest.ReplayWitnessIdentity] = []
  for index in 0..<4 {
    let id = "witness-" + index.to_string()
    witnesses.push({ id, key: @bft.PublicKey(id) })
  }
  { config, teams, players, transcript, witnesses }
}

///|
fn run_pvp_epoch_benchmark(
  b : @bench.T,
  input : PvpEpochBenchmarkInput,
  iterations : Int,
) -> Unit {
  let hasher = @bft.FnvHasher::new()
  b.bench(fn() {
    for _ in 0..<iterations {
      match
        prepare_pvp_epoch(
          hasher,
          session_id="pvp-benchmark",
          referee_key=@bft.PublicKey("referee"),
          config=input.config,
          teams=input.teams,
          players=input.players,
          transcript=input.transcript,
          witnesses=input.witnesses,
          max_faults=1,
        ) {
        PvpCandidateReady(candidate) => b.keep(candidate.public_state_root())
        PvpCandidateRefused(_) => abort("benchmark PvP replay failed")
      }
    }
  })
}

///|
test "bench: replay public PvP epoch for 8 players x 16 ticks" (b : @bench.T) {
  run_pvp_epoch_benchmark(b, benchmark_pvp_epoch_input(8, 16), 20)
}

///|
test "bench: replay public PvP epoch for 64 players x 16 ticks" (b : @bench.T) {
  run_pvp_epoch_benchmark(b, benchmark_pvp_epoch_input(64, 16), 5)
}
