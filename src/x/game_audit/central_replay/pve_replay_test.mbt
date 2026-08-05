///|
priv struct PveReplayFixture {
  session_id : String
  authority_key : @bft.PublicKey
  checkpoint_digest : @bft.Digest
  bundle : @wire.PveReplayBundle
}

///|
fn accepted_for_fixture(
  adapter : @bft.BFTAdapter,
  signed : @bft.SignedEvent,
) -> @bft.AuthenticatedEvent raise Error {
  match adapter.deliver(signed) {
    Accepted(source) => source
    _ => fail("expected fixture event authentication")
  }
}

///|
fn pve_replay_fixture() -> PveReplayFixture raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let alice = @bft.MockSigner::new("alice")
  let session_id = "dungeon:central-replay"
  let adapter = @bft.BFTAdapter::new(hasher, verifier, session_id~)
  assert_true(
    adapter.register_peer(@types.PeerId("authority"), authority.public_key()),
  )
  assert_true(adapter.register_peer(@types.PeerId("alice"), alice.public_key()))
  let config = @replay.DungeonEncounterConfig::{
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
  let players = [
    @replay.DungeonPlayer::{
      player_id: "alice",
      public_key: alice.public_key(),
      initial_x: 0,
    },
  ]
  let attack = @replay.DungeonEncounterAttack::{
    attack: {
      attack_id: "cleave-1",
      visible_tick: 10,
      resolve_tick: 16,
      center_x: 0,
      radius: 2,
    },
    damage: 6,
  }
  let telegraph_event = @replay.make_dungeon_telegraph_event(
    peer=@types.PeerId("authority"),
    counter=0,
    lamport=1,
    deps=[],
    attack=attack.attack,
  )
  let signed_telegraph = adapter.sign(authority, telegraph_event, [])
  let telegraph = accepted_for_fixture(adapter, signed_telegraph)
  let intent = @replay.DodgeIntent::{
    attack_id: attack.attack.attack_id,
    player_id: "alice",
    telegraph_digest: telegraph.digest(),
    client_tick: 13,
    to_x: 5,
  }
  let input_event = @replay.make_dungeon_dodge_event(
    peer=@types.PeerId("alice"),
    counter=0,
    lamport=2,
    deps=[telegraph_event.id],
    intent~,
  )
  let signed_input = adapter.sign(alice, input_event, [telegraph.digest()])
  let input = accepted_for_fixture(adapter, signed_input)
  let observed = @replay.DodgeReceipt::{
    input_digest: input.digest(),
    received_tick: 14,
  }
  let receipt_event = @replay.make_dungeon_receipt_event(
    peer=@types.PeerId("authority"),
    counter=1,
    lamport=3,
    deps=[input_event.id],
    receipt=observed,
  )
  let signed_receipt = adapter.sign(authority, receipt_event, [input.digest()])
  let receipt = accepted_for_fixture(adapter, signed_receipt)
  let transcript = @replay.DungeonAttackTranscript::{
    attack_id: attack.attack.attack_id,
    telegraph,
    dodge_evidence: [{ input, receipt, intent, observed }],
  }
  let candidate = match
    @replay.prepare_dungeon_encounter(
      hasher,
      session_id~,
      authority_key=authority.public_key(),
      config~,
      players~,
      attacks=[attack],
      transcripts=[transcript],
    ) {
    CandidateReady(candidate) => candidate
    _ => fail("expected fixture encounter candidate")
  }
  let loot_effect = @replay.AssetEffect::Create(
    asset_id=@replay.dungeon_encounter_loot_asset_id(
      session_id,
      config.encounter_id,
      "alice",
    ),
    recipient_id="alice",
    item_type=config.attack_rules.loot_item_type,
    quantity=1,
    output_index=0,
  )
  let loot_event = @replay.make_asset_effect_event(
    peer=@types.PeerId("authority"),
    counter=2,
    lamport=4,
    deps=[receipt_event.id],
    effect=loot_effect,
  )
  let signed_loot = adapter.sign(authority, loot_event, [receipt.digest()])
  let loot_batch = match
    @market.build_receipt_batch(hasher, [
      {
        asset_id: @replay.dungeon_encounter_loot_asset_id(
          session_id,
          config.encounter_id,
          "alice",
        ),
        recipient_id: "alice",
        item_type: config.attack_rules.loot_item_type,
        quantity: 1,
        source_event: signed_loot.digest,
        output_index: 0,
      },
    ]) {
    Built(value) => value
    _ => fail("expected fixture loot receipt batch")
  }
  let signed_checkpoint = @checkpoint.sign_checkpoint(hasher, authority, {
    session_id,
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: candidate.public_state_root(),
    asset_delta_root: loot_batch.root(),
    hidden_state_commitment: None,
  })
  {
    session_id,
    authority_key: authority.public_key(),
    checkpoint_digest: signed_checkpoint.digest,
    bundle: {
      authority_peer_id: "authority",
      signed_checkpoint,
      config,
      players,
      attacks: [attack],
      transcripts: [
        {
          attack_id: attack.attack.attack_id,
          telegraph: signed_telegraph,
          dodge_evidence: [
            { input: signed_input, receipt: signed_receipt, intent, observed },
          ],
        },
      ],
      asset_effects: [{ source: signed_loot, effect: loot_effect }],
    },
  }
}

///|
fn verify_fixture(
  fixture : PveReplayFixture,
  bytes : Bytes,
) -> PveCentralReplayResult {
  verify_pve_replay_bundle(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    bytes,
    expected_session_id=fixture.session_id,
    expected_authority_key=fixture.authority_key,
    expected_checkpoint_digest=fixture.checkpoint_digest,
    limits=@wire.PveReplayWireLimits::default(),
  )
}

///|
test "central PvE worker authenticates every event and matches checkpoint" {
  let fixture = pve_replay_fixture()
  match
    verify_fixture(fixture, @wire.encode_pve_replay_bundle(fixture.bundle)) {
    ReplayVerified(verified) => {
      assert_eq(verified.checkpoint_digest(), fixture.checkpoint_digest)
      assert_eq(verified.session_id(), fixture.session_id)
      assert_true(verified.cleared())
      assert_eq(verified.accepted_dodge_count(), 1)
      assert_eq(verified.survivor_ids(), ["alice"])
      assert_eq(verified.replayed_asset_count(), 1)
    }
    _ => fail("expected verified central PvE replay")
  }
}

///|
test "central PvE worker rejects a checkpoint asset root without replay evidence" {
  let fixture = pve_replay_fixture()
  let bundle = @wire.PveReplayBundle::{ ..fixture.bundle, asset_effects: [] }
  assert_eq(
    verify_fixture(fixture, @wire.encode_pve_replay_bundle(bundle)),
    PveCentralReplayResult::ReplayRefused(
      PveCentralReplayRefusal::AssetDeltaRootMismatch,
    ),
  )
}

///|
test "central PvE worker rejects a loot declaration not accepted by the kernel" {
  let fixture = pve_replay_fixture()
  let evidence = fixture.bundle.asset_effects[0]
  let forged = @replay.AssetEffect::Create(
    asset_id=@replay.dungeon_encounter_loot_asset_id(
      fixture.session_id,
      fixture.bundle.config.encounter_id,
      "alice",
    ),
    recipient_id="alice",
    item_type="forged-token",
    quantity=1,
    output_index=0,
  )
  let bundle = @wire.PveReplayBundle::{
    ..fixture.bundle,
    asset_effects: [{ ..evidence, effect: forged }],
  }
  assert_eq(
    verify_fixture(fixture, @wire.encode_pve_replay_bundle(bundle)),
    PveCentralReplayResult::ReplayRefused(
      PveCentralReplayRefusal::AssetEffectReplayRefused(
        0,
        @replay.ReplayRefusal::KernelRejected,
      ),
    ),
  )
}

///|
test "central PvE worker fails closed on job boundary mismatch" {
  let fixture = pve_replay_fixture()
  let bytes = @wire.encode_pve_replay_bundle(fixture.bundle)
  assert_eq(
    verify_pve_replay_bundle(
      @bft.FnvHasher::new(),
      @bft.MockVerifier::new(),
      bytes,
      expected_session_id=fixture.session_id,
      expected_authority_key=fixture.authority_key,
      expected_checkpoint_digest=@bft.Digest("different-checkpoint"),
      limits=@wire.PveReplayWireLimits::default(),
    ),
    PveCentralReplayResult::ReplayRefused(
      PveCentralReplayRefusal::ExpectedCheckpointMismatch,
    ),
  )
}

///|
test "central PvE worker rejects a signed-event signature failure" {
  let fixture = pve_replay_fixture()
  let transcript = fixture.bundle.transcripts[0]
  let invalid_telegraph = @bft.SignedEvent::{
    ..transcript.telegraph,
    signature: @bft.Signature("forged"),
  }
  let bundle = @wire.PveReplayBundle::{
    ..fixture.bundle,
    transcripts: [{ ..transcript, telegraph: invalid_telegraph }],
  }
  match verify_fixture(fixture, @wire.encode_pve_replay_bundle(bundle)) {
    ReplayRefused(EventAuthenticationRefused(_)) => ()
    _ => fail("expected signed-event authentication refusal")
  }
}

///|
test "central PvE worker rejects duplicate event reuse" {
  let fixture = pve_replay_fixture()
  let transcript = fixture.bundle.transcripts[0]
  let evidence = transcript.dodge_evidence[0]
  let bundle = @wire.PveReplayBundle::{
    ..fixture.bundle,
    transcripts: [{ ..transcript, dodge_evidence: [evidence, evidence] }],
  }
  assert_eq(
    verify_fixture(fixture, @wire.encode_pve_replay_bundle(bundle)),
    PveCentralReplayResult::ReplayRefused(
      PveCentralReplayRefusal::DuplicateEventDigest(evidence.input.digest.0),
    ),
  )
}

///|
test "central PvE worker distinguishes valid signatures from kernel mismatch" {
  let fixture = pve_replay_fixture()
  let bundle = @wire.PveReplayBundle::{
    ..fixture.bundle,
    config: { ..fixture.bundle.config, player_max_hp: 11 },
  }
  match verify_fixture(fixture, @wire.encode_pve_replay_bundle(bundle)) {
    ReplayRefused(EncounterReplayRefused(_)) => ()
    _ => fail("expected checkpoint-bound kernel mismatch refusal")
  }
}
