///|
fn raid_rules() -> DungeonRaidRules {
  {
    boss_max_hp: 10,
    player_attack_damage: 6,
    player_attack_cooldown_ticks: 2,
    damage_phase_start_tick: 20,
    enrage_tick: 30,
  }
}

///|
fn raid_player_attack(
  player_id : String,
  tick : Int,
  counter : Int,
) -> DungeonPlayerAttackEvidence raise Error {
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
  let signer : &@bft.Signer = if player_id == "alice" { alice } else { bob }
  let intent = DungeonPlayerAttackIntent::{
    encounter_id: "boss-1",
    player_id,
    tick,
  }
  let input_event = make_dungeon_player_attack_event(
    peer=@types.PeerId(player_id),
    counter~,
    lamport=counter * 2,
    deps=[],
    intent~,
  )
  let input = accept_encounter_event(adapter, signer, input_event, [])
  let observed = DungeonPlayerAttackReceipt::{
    input_digest: input.digest(),
    received_tick: tick + 1,
  }
  let receipt_event = make_dungeon_player_attack_receipt_event(
    peer=@types.PeerId("game-server"),
    counter=counter + 100,
    lamport=counter * 2 + 1,
    deps=[input_event.id],
    receipt=observed,
  )
  let receipt = accept_encounter_event(adapter, authority, receipt_event, [
    input.digest(),
  ])
  { input, receipt, intent, observed }
}

///|
fn raid_checkpoint(
  candidate : DungeonRaidCandidate,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let hasher = @bft.FnvHasher::new()
  let authority = @bft.MockSigner::new("game-server")
  let signed = @checkpoint.sign_checkpoint(hasher, authority, {
    session_id: "encounter-session",
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: candidate.public_state_root(),
    asset_delta_root: @bft.Digest("pending-raid-loot"),
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
    _ => fail("expected verified raid checkpoint")
  }
}

///|
test "raid phase replays boss HP and player cooldown before checkpoint finality" {
  let cleave = encounter_attack("cleave", 10, 16, 0, damage=10)
  let defense = encounter_transcript(
    cleave,
    0,
    dodge_player="alice",
    dodge_to_x=5,
  )
  let first = raid_player_attack("alice", 20, 0)
  let second = raid_player_attack("alice", 22, 1)
  match
    prepare_dungeon_raid(
      @bft.FnvHasher::new(),
      session_id="encounter-session",
      authority_key=@bft.PublicKey("game-server"),
      encounter_config=encounter_config(),
      raid_rules=raid_rules(),
      players=encounter_players(),
      attacks=[cleave],
      defense_transcripts=[defense],
      player_attacks=[second, first],
    ) {
    RaidCandidateReady(candidate) => {
      assert_eq(candidate.boss_hp(), 0)
      assert_true(candidate.cleared())
      assert_eq(candidate.accepted_player_attack_count(), 2)
      assert_eq(candidate.cooldown_violator_ids(), [])
      match finalize_dungeon_raid(candidate, raid_checkpoint(candidate)) {
        RaidFinalized(resolution) => {
          assert_eq(resolution.boss_hp(), 0)
          assert_true(resolution.cleared())
          assert_eq(resolution.survivor_ids(), ["alice"])
        }
        _ => fail("valid raid checkpoint did not finalize")
      }
    }
    _ => fail("valid raid did not prepare")
  }
}

///|
test "raid cooldown violation cannot create boss damage but remains auditable" {
  let cleave = encounter_attack("cleave", 10, 16, 0, damage=10)
  let defense = encounter_transcript(
    cleave,
    0,
    dodge_player="alice",
    dodge_to_x=5,
  )
  let first = raid_player_attack("alice", 20, 0)
  let too_soon = raid_player_attack("alice", 21, 1)
  match
    prepare_dungeon_raid(
      @bft.FnvHasher::new(),
      session_id="encounter-session",
      authority_key=@bft.PublicKey("game-server"),
      encounter_config=encounter_config(),
      raid_rules=raid_rules(),
      players=encounter_players(),
      attacks=[cleave],
      defense_transcripts=[defense],
      player_attacks=[first, too_soon],
    ) {
    RaidCandidateReady(candidate) => {
      assert_eq(candidate.boss_hp(), 4)
      assert_false(candidate.cleared())
      assert_eq(candidate.accepted_player_attack_count(), 1)
      assert_eq(candidate.cooldown_violator_ids(), ["alice"])
    }
    _ => fail("auditable cooldown violation refused the whole raid")
  }
}
