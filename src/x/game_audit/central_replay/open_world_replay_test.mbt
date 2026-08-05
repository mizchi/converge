///|
priv struct OpenWorldCentralReplayFixture {
  world_id : String
  encounter_session_id : String
  authority_key : @bft.PublicKey
  transparency_log_session_id : String
  transparency_publisher_key : @bft.PublicKey
  transparency_checkpoint_digest : @bft.Digest
  audit_checkpoint_digest : @bft.Digest
  seal_checkpoint_digest : @bft.Digest
  encounter_checkpoint_digest : @bft.Digest
  bundle : @wire.OpenWorldPveReplayBundle
}

///|
fn open_world_central_replay_fixture(
  observation_count? : Int = 3,
) -> OpenWorldCentralReplayFixture raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("open-world-authority")
  let transparency_publisher = @bft.MockSigner::new(
    "open-world-transparency-publisher",
  )
  let world_id = "world:central-replay"
  let transparency_log_session_id = world_id + ":transparency"
  let encounter_session_id = "world:central-replay:encounter-0"
  let game_manifest_digest = @bft.Digest("open-world-pve-v1")
  let seed = "delayed-open-world-seed"
  let observers : Array[@attestation.Participant] = []
  let observer_signers : Array[@bft.MockSigner] = []
  for index in 0..<4 {
    let id = "observer-" + index.to_string()
    let signer = @bft.MockSigner::new(id)
    observer_signers.push(signer)
    observers.push({ id, key: signer.public_key() })
  }
  let observer_manifest_digest = @open_world.open_world_observer_manifest(
    hasher,
    observers~,
    max_faults=1,
  )
  let signed_audit_checkpoint = @checkpoint.sign_checkpoint(hasher, authority, {
    session_id: world_id,
    epoch: 10,
    previous_checkpoint: @bft.Digest("world-9"),
    manifest_digest: @open_world.open_world_audit_manifest(
      hasher,
      game_manifest_digest~,
      observer_manifest_digest~,
      sample_numerator=1,
      sample_denominator=1,
    ),
    event_root: @bft.Digest("audit-start-events"),
    public_state_root: @bft.Digest("audit-start-state"),
    asset_delta_root: @bft.Digest("audit-start-assets"),
    hidden_state_commitment: Some(
      @open_world.open_world_audit_seed_commitment(
        hasher,
        world_id~,
        epoch=10,
        seed~,
      ),
    ),
  })
  let adapter = @bft.BFTAdapter::new(
    hasher,
    verifier,
    session_id=encounter_session_id,
  )
  assert_true(
    adapter.register_peer(@types.PeerId("authority"), authority.public_key()),
  )
  let alice = @bft.MockSigner::new("alice")
  assert_true(adapter.register_peer(@types.PeerId("alice"), alice.public_key()))
  let config = @replay.DungeonEncounterConfig::{
    encounter_id: "open-world-encounter-0",
    player_max_hp: 2,
    attack_rules: {
      min_reaction_ticks: 2,
      max_backdate_ticks: 2,
      max_dodge_distance: 4,
      arena_min_x: -10,
      arena_max_x: 10,
      loot_item_type: "open-world-token",
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
      attack_id: "open-world-cleave",
      visible_tick: 10,
      resolve_tick: 14,
      center_x: 0,
      radius: 1,
    },
    damage: 1,
  }
  let event = @replay.make_dungeon_telegraph_event(
    peer=@types.PeerId("authority"),
    counter=0,
    lamport=1,
    deps=[],
    attack=attack.attack,
  )
  let signed_telegraph = adapter.sign(authority, event, [])
  let telegraph = match adapter.deliver(signed_telegraph) {
    Accepted(value) => value
    _ => fail("expected authenticated open-world telegraph")
  }
  let candidate = match
    @replay.prepare_dungeon_encounter(
      hasher,
      session_id=encounter_session_id,
      authority_key=authority.public_key(),
      config~,
      players~,
      attacks=[attack],
      transcripts=[
        { attack_id: attack.attack.attack_id, telegraph, dodge_evidence: [] },
      ],
    ) {
    CandidateReady(value) => value
    _ => fail("expected open-world encounter replay candidate")
  }
  let loot_effect = @replay.AssetEffect::Create(
    asset_id=@replay.dungeon_encounter_loot_asset_id(
      encounter_session_id,
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
    counter=1,
    lamport=2,
    deps=[event.id],
    effect=loot_effect,
  )
  let signed_loot = adapter.sign(authority, loot_event, [telegraph.digest()])
  let loot_batch = match
    @market.build_receipt_batch(hasher, [
      {
        asset_id: @replay.dungeon_encounter_loot_asset_id(
          encounter_session_id,
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
    _ => fail("expected open-world loot receipt batch")
  }
  let signed_encounter_checkpoint = @checkpoint.sign_checkpoint(
    hasher,
    authority,
    {
      session_id: encounter_session_id,
      epoch: 0,
      previous_checkpoint: signed_audit_checkpoint.digest,
      manifest_digest: candidate.manifest_digest(),
      event_root: candidate.event_root(),
      public_state_root: candidate.public_state_root(),
      asset_delta_root: loot_batch.root(),
      hidden_state_commitment: None,
    },
  )
  let eligible = @merkle.MerkleTree::build(hasher, [
    @open_world.open_world_encounter_anchor_payload(
      0,
      signed_encounter_checkpoint.digest,
    ),
  ])
  let eligibility_proof = match eligible.proof(0) {
    Some(value) => value
    None => fail("expected open-world eligibility proof")
  }
  let signed_anchor_seal_checkpoint = @checkpoint.sign_checkpoint(
    hasher,
    authority,
    {
      session_id: world_id,
      epoch: 11,
      previous_checkpoint: signed_audit_checkpoint.digest,
      manifest_digest: @open_world.open_world_anchor_seal_manifest(
        hasher,
        audit_manifest_digest=signed_audit_checkpoint.checkpoint.manifest_digest,
        registered_count=1,
      ),
      event_root: eligible.root(),
      public_state_root: @bft.Digest("open-world-registry-root"),
      asset_delta_root: @bft.Digest("open-world-seal-assets"),
      hidden_state_commitment: None,
    },
  )
  let transparency_map = @authmap.AuthenticatedMap::new(hasher)
  let audit_publication_key = @open_world.open_world_audit_transparency_plan_key(
    world_id~,
    audit_epoch=signed_audit_checkpoint.checkpoint.epoch,
  )
  let seal_publication_key = @open_world.open_world_audit_transparency_seal_key(
    world_id~,
    audit_epoch=signed_audit_checkpoint.checkpoint.epoch,
  )
  ignore(
    transparency_map.put(
      audit_publication_key,
      @open_world.open_world_audit_transparency_plan_value(
        audit_checkpoint_digest=signed_audit_checkpoint.digest,
      ),
    ),
  )
  ignore(
    transparency_map.put(
      seal_publication_key,
      @open_world.open_world_audit_transparency_seal_value(
        audit_checkpoint_digest=signed_audit_checkpoint.digest,
        seal_checkpoint_digest=signed_anchor_seal_checkpoint.digest,
      ),
    ),
  )
  let signed_transparency_checkpoint = @checkpoint.sign_checkpoint(
    hasher,
    transparency_publisher,
    {
      session_id: transparency_log_session_id,
      epoch: 4,
      previous_checkpoint: @bft.Digest("transparency-3"),
      manifest_digest: @open_world.open_world_audit_transparency_log_manifest(
        hasher,
        log_session_id=transparency_log_session_id,
      ),
      event_root: @bft.Digest("transparency-events"),
      public_state_root: transparency_map.root(),
      asset_delta_root: @bft.Digest("transparency-assets"),
      hidden_state_commitment: None,
    },
  )
  let observations : Array[@open_world.SignedOpenWorldRegistrationObservation] = []
  for index in 0..<observation_count {
    let ledger = match
      @open_world.OpenWorldObserverSigningLedger::new(
        hasher,
        observer_signers[index],
        observer_id=observers[index].id,
      ) {
      ObserverSigningLedgerReady(value) => value
      _ => fail("expected observer signing ledger")
    }
    match
      ledger.sign_registration(
        audit_checkpoint_digest=signed_audit_checkpoint.digest,
        registration_index=0,
        encounter_digest=signed_encounter_checkpoint.digest,
      ) {
      ObserverObservationSigned(value) => observations.push(value)
      _ => fail("expected observer registration signature")
    }
  }
  {
    world_id,
    encounter_session_id,
    authority_key: authority.public_key(),
    transparency_log_session_id,
    transparency_publisher_key: transparency_publisher.public_key(),
    transparency_checkpoint_digest: signed_transparency_checkpoint.digest,
    audit_checkpoint_digest: signed_audit_checkpoint.digest,
    seal_checkpoint_digest: signed_anchor_seal_checkpoint.digest,
    encounter_checkpoint_digest: signed_encounter_checkpoint.digest,
    bundle: {
      signed_audit_checkpoint,
      signed_anchor_seal_checkpoint,
      audit_transparency: {
        signed_checkpoint: signed_transparency_checkpoint,
        audit_membership_proof: transparency_map
        .proof(audit_publication_key)
        .unwrap(),
        seal_membership_proof: transparency_map
        .proof(seal_publication_key)
        .unwrap(),
      },
      game_manifest_digest,
      sample_numerator: 1,
      sample_denominator: 1,
      registered_count: 1,
      seed,
      observers,
      max_faults: 1,
      observations,
      eligibility_proof,
      encounter: {
        authority_peer_id: "authority",
        signed_checkpoint: signed_encounter_checkpoint,
        config,
        players,
        attacks: [attack],
        transcripts: [
          {
            attack_id: attack.attack.attack_id,
            telegraph: signed_telegraph,
            dodge_evidence: [],
          },
        ],
        asset_effects: [{ source: signed_loot, effect: loot_effect }],
      },
    },
  }
}

///|
fn verify_open_world_fixture(
  fixture : OpenWorldCentralReplayFixture,
) -> OpenWorldPveCentralReplayResult {
  verify_open_world_pve_replay_bundle(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    @wire.encode_open_world_pve_replay_bundle(fixture.bundle),
    expected_world_id=fixture.world_id,
    expected_encounter_session_id=fixture.encounter_session_id,
    expected_authority_key=fixture.authority_key,
    expected_transparency_log_session_id=fixture.transparency_log_session_id,
    expected_transparency_publisher_key=fixture.transparency_publisher_key,
    expected_transparency_checkpoint_digest=fixture.transparency_checkpoint_digest,
    expected_audit_checkpoint_digest=fixture.audit_checkpoint_digest,
    expected_seal_checkpoint_digest=fixture.seal_checkpoint_digest,
    expected_encounter_checkpoint_digest=fixture.encounter_checkpoint_digest,
    limits=@wire.OpenWorldPveReplayWireLimits::default(),
  )
}

///|
test "open-world central replay verifies plan seal eligibility observers and encounter" {
  let fixture = open_world_central_replay_fixture()
  match verify_open_world_fixture(fixture) {
    OpenWorldPveReplayVerified(value) => {
      assert_eq(
        value.encounter_checkpoint_digest(),
        fixture.encounter_checkpoint_digest,
      )
      assert_eq(value.observer_approval_count(), 3)
      assert_eq(value.required_observer_approvals(), 3)
      assert_true(value.cleared())
      assert_eq(value.verified_item_creation_count(), 1)
      let item = value.verified_item_creations()[0]
      assert_eq(item.initial_owner_id, "alice")
      assert_eq(item.item_type, "open-world-token")
      assert_eq(item.quantity, 1)
      assert_eq(item.checkpoint_digest, fixture.encounter_checkpoint_digest)
      assert_eq(item.inventory_session_id, fixture.encounter_session_id)
      assert_eq(item.checkpoint_epoch, 0)
    }
    _ => fail("expected verified open-world central replay")
  }
}

///|
test "open-world central replay rejects under-quorum observers" {
  let fixture = open_world_central_replay_fixture(observation_count=2)
  assert_eq(
    verify_open_world_fixture(fixture),
    OpenWorldPveCentralReplayResult::OpenWorldPveReplayRefused(
      OpenWorldPveCentralReplayRefusal::OpenWorldObserverQuorumPending(2, 3),
    ),
  )
}

///|
test "open-world central replay rejects untrusted plan and seal substitutions" {
  let fixture = open_world_central_replay_fixture()
  let bytes = @wire.encode_open_world_pve_replay_bundle(fixture.bundle)
  let result = verify_open_world_pve_replay_bundle(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    bytes,
    expected_world_id=fixture.world_id,
    expected_encounter_session_id=fixture.encounter_session_id,
    expected_authority_key=fixture.authority_key,
    expected_transparency_log_session_id=fixture.transparency_log_session_id,
    expected_transparency_publisher_key=fixture.transparency_publisher_key,
    expected_transparency_checkpoint_digest=fixture.transparency_checkpoint_digest,
    expected_audit_checkpoint_digest=@bft.Digest("another-audit-plan"),
    expected_seal_checkpoint_digest=fixture.seal_checkpoint_digest,
    expected_encounter_checkpoint_digest=fixture.encounter_checkpoint_digest,
    limits=@wire.OpenWorldPveReplayWireLimits::default(),
  )
  assert_eq(
    result,
    OpenWorldPveCentralReplayResult::OpenWorldPveReplayRefused(
      OpenWorldPveCentralReplayRefusal::OpenWorldExpectedAuditCheckpointMismatch,
    ),
  )
}

///|
test "open-world central replay rejects an untrusted transparency head" {
  let fixture = open_world_central_replay_fixture()
  let result = verify_open_world_pve_replay_bundle(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    @wire.encode_open_world_pve_replay_bundle(fixture.bundle),
    expected_world_id=fixture.world_id,
    expected_encounter_session_id=fixture.encounter_session_id,
    expected_authority_key=fixture.authority_key,
    expected_transparency_log_session_id=fixture.transparency_log_session_id,
    expected_transparency_publisher_key=fixture.transparency_publisher_key,
    expected_transparency_checkpoint_digest=@bft.Digest("foreign-head"),
    expected_audit_checkpoint_digest=fixture.audit_checkpoint_digest,
    expected_seal_checkpoint_digest=fixture.seal_checkpoint_digest,
    expected_encounter_checkpoint_digest=fixture.encounter_checkpoint_digest,
    limits=@wire.OpenWorldPveReplayWireLimits::default(),
  )
  assert_eq(
    result,
    OpenWorldPveCentralReplayResult::OpenWorldPveReplayRefused(
      OpenWorldPveCentralReplayRefusal::OpenWorldAuditTransparencyRefused(
        @open_world.OpenWorldAuditTransparencyRefusal::AuditTransparencyExpectedCheckpointMismatch,
      ),
    ),
  )
}

///|
test "open-world central replay rejects an eligibility proof for another leaf" {
  let fixture = open_world_central_replay_fixture()
  let bundle = @wire.OpenWorldPveReplayBundle::{
    ..fixture.bundle,
    eligibility_proof: {
      leaf_index: 0,
      leaf_count: 1,
      path: [@merkle.MerkleStep::SiblingRight(@bft.Digest("forged-sibling"))],
    },
  }
  let tampered = OpenWorldCentralReplayFixture::{ ..fixture, bundle, }
  match verify_open_world_fixture(tampered) {
    OpenWorldPveReplayRefused(OpenWorldEncounterGateRefused(_)) => ()
    _ => fail("expected open-world eligibility refusal")
  }
}
