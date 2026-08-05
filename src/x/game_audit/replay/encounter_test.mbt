///|
fn encounter_config() -> DungeonEncounterConfig {
  {
    encounter_id: "boss-1",
    player_max_hp: 10,
    attack_rules: {
      min_reaction_ticks: 2,
      max_backdate_ticks: 2,
      max_dodge_distance: 5,
      arena_min_x: -10,
      arena_max_x: 10,
      loot_item_type: "boss-token",
    },
  }
}

///|
fn encounter_players() -> Array[DungeonPlayer] {
  [
    { player_id: "alice", public_key: @bft.PublicKey("alice"), initial_x: 0 },
    { player_id: "bob", public_key: @bft.PublicKey("bob"), initial_x: 0 },
  ]
}

///|
fn encounter_attack(
  attack_id : String,
  visible_tick : Int,
  resolve_tick : Int,
  center_x : Int,
  damage? : Int = 6,
) -> DungeonEncounterAttack {
  {
    attack: { attack_id, visible_tick, resolve_tick, center_x, radius: 2 },
    damage,
  }
}

///|
fn accept_encounter_event(
  adapter : @bft.BFTAdapter,
  signer : &@bft.Signer,
  event : @types.Event,
  dependency_hashes : Array[@bft.Digest],
) -> @bft.AuthenticatedEvent raise Error {
  match adapter.deliver(adapter.sign(signer, event, dependency_hashes)) {
    Accepted(source) => source
    _ => fail("expected authenticated encounter event")
  }
}

///|
fn encounter_transcript(
  spec : DungeonEncounterAttack,
  counter_base : Int,
  dodge_player? : String = "",
  dodge_to_x? : Int = 0,
) -> DungeonAttackTranscript raise Error {
  let adapter = @bft.BFTAdapter::new(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    session_id="encounter-session",
  )
  let authority = @bft.MockSigner::new("game-server")
  let alice = @bft.MockSigner::new("alice")
  let bob = @bft.MockSigner::new("bob")
  assert_true(
    adapter.register_peer(@types.PeerId("game-server"), authority.public_key()),
  )
  assert_true(adapter.register_peer(@types.PeerId("alice"), alice.public_key()))
  assert_true(adapter.register_peer(@types.PeerId("bob"), bob.public_key()))
  let attack = spec.attack
  let telegraph_event = make_dungeon_telegraph_event(
    peer=@types.PeerId("game-server"),
    counter=counter_base,
    lamport=counter_base + 1,
    deps=[],
    attack~,
  )
  let telegraph = accept_encounter_event(adapter, authority, telegraph_event, [])
  let evidence : Array[DodgeEvidence] = []
  if dodge_player != "" {
    let signer : &@bft.Signer = if dodge_player == "alice" {
      alice
    } else {
      bob
    }
    let intent = DodgeIntent::{
      attack_id: attack.attack_id,
      player_id: dodge_player,
      telegraph_digest: telegraph.digest(),
      client_tick: attack.visible_tick + 3,
      to_x: dodge_to_x,
    }
    let input_event = make_dungeon_dodge_event(
      peer=@types.PeerId(dodge_player),
      counter=counter_base + 1,
      lamport=counter_base + 2,
      deps=[telegraph_event.id],
      intent~,
    )
    let input = accept_encounter_event(adapter, signer, input_event, [
      telegraph.digest(),
    ])
    let observed = DodgeReceipt::{
      input_digest: input.digest(),
      received_tick: intent.client_tick + 1,
    }
    let receipt_event = make_dungeon_receipt_event(
      peer=@types.PeerId("game-server"),
      counter=counter_base + 2,
      lamport=counter_base + 3,
      deps=[input_event.id],
      receipt=observed,
    )
    let receipt = accept_encounter_event(adapter, authority, receipt_event, [
      input.digest(),
    ])
    evidence.push({ input, receipt, intent, observed })
  }
  { attack_id: attack.attack_id, telegraph, dodge_evidence: evidence }
}

///|
fn prepare_encounter(
  attacks : Array[DungeonEncounterAttack],
  transcripts : Array[DungeonAttackTranscript],
) -> DungeonEncounterCandidateResult {
  prepare_dungeon_encounter(
    @bft.FnvHasher::new(),
    session_id="encounter-session",
    authority_key=@bft.PublicKey("game-server"),
    config=encounter_config(),
    players=encounter_players(),
    attacks~,
    transcripts~,
  )
}

///|
fn encounter_checkpoint(
  candidate : DungeonEncounterCandidate,
  public_state_root? : @bft.Digest,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let hasher = @bft.FnvHasher::new()
  let authority = @bft.MockSigner::new("game-server")
  let signed = @checkpoint.sign_checkpoint(hasher, authority, {
    session_id: "encounter-session",
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: public_state_root.unwrap_or(
      candidate.public_state_root(),
    ),
    asset_delta_root: @bft.Digest("pending-asset-delta"),
    hidden_state_commitment: None,
  })
  match
    @checkpoint.open_checkpoint(
      hasher,
      @bft.MockVerifier::new(),
      authority.public_key(),
      signed,
    ) {
    Opened(checkpoint) => checkpoint
    _ => fail("expected verified encounter checkpoint")
  }
}

///|
fn encounter_asset_source(
  effect : AssetEffect,
  counter? : Int = 100,
) -> @bft.AuthenticatedEvent raise Error {
  let adapter = @bft.BFTAdapter::new(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    session_id="encounter-session",
  )
  let authority = @bft.MockSigner::new("game-server")
  assert_true(
    adapter.register_peer(@types.PeerId("game-server"), authority.public_key()),
  )
  let event = make_asset_effect_event(
    peer=@types.PeerId("game-server"),
    counter~,
    lamport=counter + 1,
    deps=[],
    effect~,
  )
  accept_encounter_event(adapter, authority, event, [])
}

///|
test "multi-attack replay carries position and hp and authorizes clear loot" {
  let first = encounter_attack("cleave-1", 10, 16, 0)
  let second = encounter_attack("cleave-2", 20, 26, 0)
  let first_log = encounter_transcript(
    first,
    0,
    dodge_player="alice",
    dodge_to_x=5,
  )
  let second_log = encounter_transcript(
    second,
    10,
    dodge_player="alice",
    dodge_to_x=5,
  )
  match prepare_encounter([second, first], [second_log, first_log]) {
    CandidateReady(candidate) => {
      let checkpoint = encounter_checkpoint(candidate)
      match finalize_dungeon_encounter(candidate, checkpoint) {
        EncounterFinalized(resolution) => {
          assert_eq(
            resolution.replay_match().checkpoint_digest(),
            checkpoint.digest(),
          )
          assert_eq(
            resolution.replay_match().authority_key(),
            checkpoint.authority_key(),
          )
          assert_true(resolution.cleared())
          assert_eq(resolution.survivor_ids(), ["alice"])
          assert_eq(resolution.defeated_ids(), ["bob"])
          assert_eq(resolution.player_states(), [
            { player_id: "alice", position_x: 5, hp: 10 },
            { player_id: "bob", position_x: 0, hp: 0 },
          ])
          assert_eq(resolution.accepted_dodge_count(), 2)
          assert_eq(resolution.loot_effect("bob"), None)
          match resolution.loot_effect("alice") {
            Some(effect) => {
              let source = encounter_asset_source(effect)
              match
                ReplayEngine::new(
                  resolution.loot_kernel(),
                  session_id="encounter-session",
                ).replay(source, effect) {
                Replayed(capability) => assert_eq(capability.effect(), effect)
                _ => fail("finalized survivor loot was not replay-authorized")
              }
            }
            None => fail("surviving player did not receive encounter loot")
          }
          let forged = AssetEffect::Create(
            asset_id=dungeon_encounter_loot_asset_id(
              "encounter-session", "boss-1", "bob",
            ),
            recipient_id="bob",
            item_type="boss-token",
            quantity=1,
            output_index=0,
          )
          assert_eq(
            ReplayEngine::new(
              resolution.loot_kernel(),
              session_id="encounter-session",
            ).replay(encounter_asset_source(forged, counter=101), forged),
            ReplayResult::Refused(ReplayRefusal::KernelRejected),
          )
        }
        _ => fail("valid encounter checkpoint did not finalize")
      }
    }
    _ => fail("valid encounter did not prepare")
  }
}

///|
test "failed encounter cannot mint loot" {
  let lethal = encounter_attack("enrage", 10, 16, 0, damage=10)
  let transcript = encounter_transcript(lethal, 0)
  match prepare_encounter([lethal], [transcript]) {
    CandidateReady(candidate) => {
      let checkpoint = encounter_checkpoint(candidate)
      match finalize_dungeon_encounter(candidate, checkpoint) {
        EncounterFinalized(resolution) => {
          assert_false(resolution.cleared())
          assert_eq(resolution.survivor_ids(), [])
          assert_eq(resolution.defeated_ids(), ["alice", "bob"])
          assert_eq(resolution.loot_effect("alice"), None)
          assert_eq(resolution.loot_effect("bob"), None)
        }
        _ => fail("failed encounter state did not finalize")
      }
    }
    _ => fail("valid lethal attack did not prepare")
  }
}

///|
test "encounter plan and transcript set reject ambiguous shapes" {
  let first = encounter_attack("cleave-1", 10, 16, 0)
  let overlapping = encounter_attack("cleave-2", 15, 21, 0)
  let first_log = encounter_transcript(first, 0)
  let overlapping_log = encounter_transcript(overlapping, 10)
  assert_eq(
    prepare_encounter([first, overlapping], [first_log, overlapping_log]),
    DungeonEncounterCandidateResult::Refused(
      DungeonEncounterRefusal::InvalidAttackPlan,
    ),
  )
  assert_eq(
    prepare_encounter([first], [first_log, first_log]),
    DungeonEncounterCandidateResult::Refused(
      DungeonEncounterRefusal::DuplicateAttackTranscript("cleave-1"),
    ),
  )
  let unknown = { ..first_log, attack_id: "unknown" }
  assert_eq(
    prepare_encounter([first], [unknown]),
    DungeonEncounterCandidateResult::Refused(
      DungeonEncounterRefusal::UnknownAttackTranscript("unknown"),
    ),
  )
}

///|
test "encounter roots and outcome are independent of input array order" {
  let first = encounter_attack("cleave-1", 10, 16, 0)
  let second = encounter_attack("cleave-2", 20, 26, 0)
  let first_log = encounter_transcript(
    first,
    0,
    dodge_player="alice",
    dodge_to_x=5,
  )
  let second_log = encounter_transcript(
    second,
    10,
    dodge_player="alice",
    dodge_to_x=5,
  )
  let forward = prepare_encounter([first, second], [first_log, second_log])
  let reverse = prepare_encounter([second, first], [second_log, first_log])
  match (forward, reverse) {
    (CandidateReady(left), CandidateReady(right)) => {
      assert_eq(left.manifest_digest(), right.manifest_digest())
      assert_eq(left.event_root(), right.event_root())
      assert_eq(left.public_state_root(), right.public_state_root())
    }
    _ => fail("permuted encounter did not prepare")
  }
}

///|
test "encounter rejects a missing planned attack and a forged public state" {
  let first = encounter_attack("cleave-1", 10, 16, 0)
  let second = encounter_attack("cleave-2", 20, 26, 0)
  let first_log = encounter_transcript(first, 0)
  assert_eq(
    prepare_encounter([first, second], [first_log]),
    DungeonEncounterCandidateResult::Refused(
      DungeonEncounterRefusal::MissingAttackTranscript("cleave-2"),
    ),
  )
  let second_log = encounter_transcript(second, 10)
  match prepare_encounter([first, second], [first_log, second_log]) {
    CandidateReady(candidate) => {
      let checkpoint = encounter_checkpoint(
        candidate,
        public_state_root=@bft.Digest("forged-state"),
      )
      assert_eq(
        finalize_dungeon_encounter(candidate, checkpoint),
        DungeonEncounterFinalizeResult::Refused(
          DungeonEncounterRefusal::CheckpointPublicStateRootMismatch,
        ),
      )
    }
    _ => fail("complete encounter did not prepare")
  }
}

///|
test "movement starts from the previous resolved position" {
  let first = encounter_attack("move-1", 10, 16, 0)
  let second = encounter_attack("move-2", 20, 26, 5)
  let first_log = encounter_transcript(
    first,
    0,
    dodge_player="alice",
    dodge_to_x=5,
  )
  // -1 is legal from the encounter start (distance 1), but illegal from the
  // committed position 5 after the first attack (distance 6).
  let second_log = encounter_transcript(
    second,
    10,
    dodge_player="alice",
    dodge_to_x=-1,
  )
  match prepare_encounter([first, second], [first_log, second_log]) {
    CandidateReady(candidate) => {
      let checkpoint = encounter_checkpoint(candidate)
      match finalize_dungeon_encounter(candidate, checkpoint) {
        EncounterFinalized(resolution) => {
          assert_eq(resolution.player_states(), [
            { player_id: "alice", position_x: 5, hp: 4 },
            { player_id: "bob", position_x: 0, hp: 4 },
          ])
          assert_eq(resolution.accepted_dodge_count(), 1)
        }
        _ => fail("position-carry encounter did not finalize")
      }
    }
    _ => fail("position-carry encounter did not prepare")
  }
}
