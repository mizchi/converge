///|
fn dungeon_attack() -> TelegraphedAttack {
  {
    attack_id: "boss-cleave-1",
    visible_tick: 10,
    resolve_tick: 16,
    center_x: 0,
    radius: 2,
  }
}

///|
fn dungeon_config() -> TelegraphDungeonConfig {
  {
    min_reaction_ticks: 2,
    max_backdate_ticks: 2,
    max_dodge_distance: 5,
    arena_min_x: -10,
    arena_max_x: 10,
    loot_item_type: "cleave-token",
  }
}

///|
fn dungeon_players() -> Array[DungeonPlayer] {
  [
    { player_id: "alice", public_key: @bft.PublicKey("alice"), initial_x: 0 },
    { player_id: "bob", public_key: @bft.PublicKey("bob"), initial_x: 0 },
  ]
}

///|
fn accept_dungeon_event(
  adapter : @bft.BFTAdapter,
  signer : &@bft.Signer,
  event : @types.Event,
  dep_hashes : Array[@bft.Digest],
) -> @bft.AuthenticatedEvent raise Error {
  match adapter.deliver(adapter.sign(signer, event, dep_hashes)) {
    Accepted(source) => source
    _ => fail("expected authenticated dungeon event")
  }
}

///|
struct DungeonSources {
  telegraph : @bft.AuthenticatedEvent
  evidence : DodgeEvidence
}

///|
fn dungeon_sources(
  intent~ : DodgeIntent,
  signed_intent? : DodgeIntent,
  received_tick~ : Int,
  input_counter? : Int = 0,
  receipt_counter? : Int = 1,
  input_signer? : String = "alice",
  depend_on_telegraph? : Bool = true,
) -> DungeonSources raise Error {
  let adapter = @bft.BFTAdapter::new(
    @bft.FnvHasher::new(),
    @bft.MockVerifier::new(),
    session_id="dungeon-42",
  )
  let authority = @bft.MockSigner::new("game-server")
  let alice = @bft.MockSigner::new("alice")
  let bob = @bft.MockSigner::new("bob")
  assert_true(
    adapter.register_peer(@types.PeerId("game-server"), authority.public_key()),
  )
  assert_true(adapter.register_peer(@types.PeerId("alice"), alice.public_key()))
  assert_true(adapter.register_peer(@types.PeerId("bob"), bob.public_key()))
  let attack = dungeon_attack()
  let telegraph_event = make_dungeon_telegraph_event(
    peer=@types.PeerId("game-server"),
    counter=0,
    lamport=1,
    deps=[],
    attack~,
  )
  let telegraph = accept_dungeon_event(adapter, authority, telegraph_event, [])
  let declared_intent = signed_intent.unwrap_or(intent)
  let input_deps = if depend_on_telegraph { [telegraph_event.id] } else { [] }
  let input_hashes = if depend_on_telegraph { [telegraph.digest()] } else { [] }
  let input_event = make_dungeon_dodge_event(
    peer=@types.PeerId(input_signer),
    counter=input_counter,
    lamport=2 + input_counter,
    deps=input_deps,
    intent=declared_intent,
  )
  let input_signer_ref : &@bft.Signer = if input_signer == "bob" {
    bob
  } else {
    alice
  }
  let input = accept_dungeon_event(
    adapter, input_signer_ref, input_event, input_hashes,
  )
  let receipt = DodgeReceipt::{ input_digest: input.digest(), received_tick }
  let receipt_event = make_dungeon_receipt_event(
    peer=@types.PeerId("game-server"),
    counter=receipt_counter,
    lamport=10 + receipt_counter,
    deps=[input_event.id],
    receipt~,
  )
  let receipt_source = accept_dungeon_event(adapter, authority, receipt_event, [
    input.digest(),
  ])
  {
    telegraph,
    evidence: { input, receipt: receipt_source, intent, observed: receipt },
  }
}

///|
fn alice_dodge(client_tick? : Int = 13, to_x? : Int = 5) -> DodgeIntent {
  {
    attack_id: "boss-cleave-1",
    player_id: "alice",
    telegraph_digest: @bft.Digest("placeholder"),
    client_tick,
    to_x,
  }
}

///|
fn bind_telegraph(
  intent : DodgeIntent,
  telegraph : @bft.AuthenticatedEvent,
) -> DodgeIntent {
  { ..intent, telegraph_digest: telegraph.digest() }
}

///|
fn replay_dungeon(
  telegraph : @bft.AuthenticatedEvent,
  evidence : Array[DodgeEvidence],
) -> DungeonReplayResult raise Error {
  let hasher = @bft.FnvHasher::new()
  let config = dungeon_config()
  let players = dungeon_players()
  let checkpoint = verified_dungeon_checkpoint(
    telegraph_dungeon_manifest(
      hasher,
      @bft.PublicKey("game-server"),
      config,
      players,
    ),
    dungeon_transcript_root(hasher, telegraph, evidence),
  )
  replay_checkpointed_telegraphed_attack(
    hasher,
    session_id="dungeon-42",
    authority_key=@bft.PublicKey("game-server"),
    config~,
    players~,
    checkpoint~,
    telegraph_source=telegraph,
    attack=dungeon_attack(),
    dodge_evidence=evidence,
  )
}

///|
fn verified_dungeon_checkpoint(
  manifest : @bft.Digest,
  event_root : @bft.Digest,
  session_id? : String = "dungeon-42",
  signer_name? : String = "game-server",
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let hasher = @bft.FnvHasher::new()
  let authority = @bft.MockSigner::new(signer_name)
  let signed = @checkpoint.sign_checkpoint(hasher, authority, @checkpoint.Checkpoint::{
    session_id,
    epoch: 1,
    previous_checkpoint: @bft.Digest("genesis"),
    manifest_digest: manifest,
    event_root,
    public_state_root: @bft.Digest("pending-public-state"),
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
    Opened(verified) => verified
    _ => fail("expected verified dungeon checkpoint")
  }
}

///|
test "checkpoint authority must match the dungeon authority" {
  let seed = dungeon_sources(intent=alice_dodge(), received_tick=14)
  let hasher = @bft.FnvHasher::new()
  let manifest = telegraph_dungeon_manifest(
    hasher,
    @bft.PublicKey("game-server"),
    dungeon_config(),
    dungeon_players(),
  )
  let checkpoint = verified_dungeon_checkpoint(
    manifest,
    dungeon_transcript_root(hasher, seed.telegraph, []),
    signer_name="mallory",
  )
  assert_eq(
    replay_checkpointed_telegraphed_attack(
      hasher,
      session_id="dungeon-42",
      authority_key=@bft.PublicKey("game-server"),
      config=dungeon_config(),
      players=dungeon_players(),
      checkpoint~,
      telegraph_source=seed.telegraph,
      attack=dungeon_attack(),
      dodge_evidence=[],
    ),
    DungeonReplayResult::Refused(
      DungeonReplayRefusal::CheckpointAuthorityMismatch,
    ),
  )
}

///|
fn replay_checkpointed_dungeon(
  telegraph : @bft.AuthenticatedEvent,
  evidence : Array[DodgeEvidence],
) -> DungeonReplayResult raise Error {
  replay_dungeon(telegraph, evidence)
}

///|
test "bounded client-time dodge survives and authorizes deterministic loot" {
  let first = dungeon_sources(intent=alice_dodge(), received_tick=14)
  let intent = bind_telegraph(first.evidence.intent, first.telegraph)
  let sources = dungeon_sources(intent~, received_tick=14)
  match replay_checkpointed_dungeon(sources.telegraph, [sources.evidence]) {
    Resolved(resolution) => {
      assert_eq(resolution.survivor_ids(), ["alice"])
      assert_eq(resolution.hit_ids(), ["bob"])
      assert_eq(resolution.equivocator_ids(), [])
      assert_eq(resolution.accepted_dodge_count(), 1)
      match resolution.loot_effect("alice") {
        Some(effect) => {
          assert_eq(
            effect,
            AssetEffect::Create(
              asset_id=dungeon_loot_asset_id(
                "dungeon-42", "boss-cleave-1", "alice",
              ),
              recipient_id="alice",
              item_type="cleave-token",
              quantity=1,
              output_index=0,
            ),
          )
          let asset_adapter = @bft.BFTAdapter::new(
            @bft.FnvHasher::new(),
            @bft.MockVerifier::new(),
            session_id="dungeon-42",
          )
          let authority = @bft.MockSigner::new("game-server")
          assert_true(
            asset_adapter.register_peer(
              @types.PeerId("game-server"),
              authority.public_key(),
            ),
          )
          let event = make_asset_effect_event(
            peer=@types.PeerId("game-server"),
            counter=20,
            lamport=30,
            deps=[],
            effect~,
          )
          let source = accept_dungeon_event(asset_adapter, authority, event, [])
          let kernel = resolution.loot_kernel()
          match
            ReplayEngine::new(kernel, session_id="dungeon-42").replay(
              source, effect,
            ) {
            Replayed(capability) => assert_eq(capability.effect(), effect)
            _ => fail("survivor loot was not replay-authorized")
          }
          let ineligible = AssetEffect::Create(
            asset_id=dungeon_loot_asset_id("dungeon-42", "boss-cleave-1", "bob"),
            recipient_id="bob",
            item_type="cleave-token",
            quantity=1,
            output_index=0,
          )
          let ineligible_event = make_asset_effect_event(
            peer=@types.PeerId("game-server"),
            counter=21,
            lamport=31,
            deps=[],
            effect=ineligible,
          )
          let ineligible_source = accept_dungeon_event(
            asset_adapter,
            authority,
            ineligible_event,
            [],
          )
          assert_eq(
            ReplayEngine::new(resolution.loot_kernel(), session_id="dungeon-42").replay(
              ineligible_source, ineligible,
            ),
            ReplayResult::Refused(ReplayRefusal::KernelRejected),
          )
        }
        None => fail("survivor did not receive deterministic loot")
      }
      assert_eq(resolution.loot_effect("bob"), None)
    }
    _ => fail("valid telegraphed attack did not replay")
  }
}

///|
test "dungeon loot id is unambiguous across delimiter-shaped identifiers" {
  assert_not_eq(
    dungeon_loot_asset_id("a:b", "c", "d"),
    dungeon_loot_asset_id("a", "b:c", "d"),
  )
}

///|
test "checkpoint event root prevents omission of a conflicting input" {
  let seed = dungeon_sources(intent=alice_dodge(), received_tick=14)
  let left_intent = bind_telegraph(alice_dodge(to_x=-5), seed.telegraph)
  let right_intent = bind_telegraph(alice_dodge(to_x=5), seed.telegraph)
  let left = dungeon_sources(
    intent=left_intent,
    received_tick=14,
    input_counter=0,
    receipt_counter=1,
  )
  let right = dungeon_sources(
    intent=right_intent,
    received_tick=14,
    input_counter=1,
    receipt_counter=2,
  )
  let full = [left.evidence, right.evidence]
  let hasher = @bft.FnvHasher::new()
  let manifest = telegraph_dungeon_manifest(
    hasher,
    @bft.PublicKey("game-server"),
    dungeon_config(),
    dungeon_players(),
  )
  let checkpoint = verified_dungeon_checkpoint(
    manifest,
    dungeon_transcript_root(hasher, left.telegraph, full),
  )
  assert_eq(
    replay_checkpointed_telegraphed_attack(
      hasher,
      session_id="dungeon-42",
      authority_key=@bft.PublicKey("game-server"),
      config=dungeon_config(),
      players=dungeon_players(),
      checkpoint~,
      telegraph_source=left.telegraph,
      attack=dungeon_attack(),
      dodge_evidence=[left.evidence],
    ),
    DungeonReplayResult::Refused(
      DungeonReplayRefusal::CheckpointEventRootMismatch,
    ),
  )
  match
    replay_checkpointed_telegraphed_attack(
      hasher,
      session_id="dungeon-42",
      authority_key=@bft.PublicKey("game-server"),
      config=dungeon_config(),
      players=dungeon_players(),
      checkpoint~,
      telegraph_source=left.telegraph,
      attack=dungeon_attack(),
      dodge_evidence=full,
    ) {
    Resolved(resolution) => assert_eq(resolution.equivocator_ids(), ["alice"])
    _ => fail("complete checkpoint transcript did not replay")
  }
}

///|
test "dodge timing rejects early future and excessive-backdate claims" {
  let cases = [
    (alice_dodge(client_tick=11), 11),
    (alice_dodge(client_tick=14), 13),
    (alice_dodge(client_tick=13), 16),
    (alice_dodge(client_tick=16), 16),
  ]
  for case in cases {
    let (raw_intent, received_tick) = case
    let seed = dungeon_sources(intent=raw_intent, received_tick~)
    let intent = bind_telegraph(raw_intent, seed.telegraph)
    let sources = dungeon_sources(intent~, received_tick~)
    match replay_dungeon(sources.telegraph, [sources.evidence]) {
      Resolved(resolution) => {
        assert_eq(resolution.survivor_ids(), [])
        assert_eq(resolution.hit_ids(), ["alice", "bob"])
        assert_eq(resolution.accepted_dodge_count(), 0)
      }
      _ => fail("invalid dodge should be ignored, not abort replay")
    }
  }
}

///|
test "dodge requires exact player signature payload movement and causality" {
  let valid_seed = dungeon_sources(intent=alice_dodge(), received_tick=14)
  let valid_intent = bind_telegraph(alice_dodge(), valid_seed.telegraph)
  let wrong_author = dungeon_sources(
    intent=valid_intent,
    received_tick=14,
    input_signer="bob",
  )
  let tampered = dungeon_sources(
    intent=valid_intent,
    signed_intent={ ..valid_intent, to_x: -5 },
    received_tick=14,
  )
  let too_far = dungeon_sources(
    intent={ ..valid_intent, to_x: 6 },
    received_tick=14,
  )
  let no_dependency = dungeon_sources(
    intent=valid_intent,
    received_tick=14,
    depend_on_telegraph=false,
  )
  for sources in [wrong_author, tampered, too_far, no_dependency] {
    match replay_dungeon(sources.telegraph, [sources.evidence]) {
      Resolved(resolution) => {
        assert_eq(resolution.accepted_dodge_count(), 0)
        assert_eq(resolution.hit_ids(), ["alice", "bob"])
      }
      _ => fail("bad player evidence should be ignored")
    }
  }
}

///|
test "two valid dodges become an order-independent player equivocation" {
  let seed = dungeon_sources(intent=alice_dodge(), received_tick=14)
  let left_intent = bind_telegraph(alice_dodge(to_x=-5), seed.telegraph)
  let right_intent = bind_telegraph(alice_dodge(to_x=5), seed.telegraph)
  let left = dungeon_sources(
    intent=left_intent,
    received_tick=14,
    input_counter=0,
    receipt_counter=1,
  )
  let right = dungeon_sources(
    intent=right_intent,
    received_tick=14,
    input_counter=1,
    receipt_counter=2,
  )
  let forward = replay_dungeon(left.telegraph, [left.evidence, right.evidence])
  let reverse = replay_dungeon(left.telegraph, [right.evidence, left.evidence])
  assert_eq(forward, reverse)
  match forward {
    Resolved(resolution) => {
      assert_eq(resolution.survivor_ids(), [])
      assert_eq(resolution.hit_ids(), ["alice", "bob"])
      assert_eq(resolution.equivocator_ids(), ["alice"])
      assert_eq(resolution.accepted_dodge_count(), 0)
      assert_eq(resolution.loot_effect("alice"), None)
    }
    _ => fail("equivocation should produce a deterministic resolution")
  }
}

///|
test "telegraph replay fails closed on an invalid encounter contract" {
  let seed = dungeon_sources(intent=alice_dodge(), received_tick=14)
  let hasher = @bft.FnvHasher::new()
  let checkpoint = verified_dungeon_checkpoint(
    telegraph_dungeon_manifest(
      hasher,
      @bft.PublicKey("game-server"),
      dungeon_config(),
      dungeon_players(),
    ),
    dungeon_transcript_root(hasher, seed.telegraph, []),
  )
  assert_eq(
    replay_checkpointed_telegraphed_attack(
      hasher,
      session_id="dungeon-42",
      authority_key=@bft.PublicKey("game-server"),
      config={ ..dungeon_config(), min_reaction_ticks: -1 },
      players=dungeon_players(),
      checkpoint~,
      telegraph_source=seed.telegraph,
      attack=dungeon_attack(),
      dodge_evidence=[],
    ),
    DungeonReplayResult::Refused(DungeonReplayRefusal::InvalidConfiguration),
  )
  let mallory_checkpoint = verified_dungeon_checkpoint(
    telegraph_dungeon_manifest(
      hasher,
      @bft.PublicKey("mallory"),
      dungeon_config(),
      dungeon_players(),
    ),
    dungeon_transcript_root(hasher, seed.telegraph, []),
    signer_name="mallory",
  )
  assert_eq(
    replay_checkpointed_telegraphed_attack(
      hasher,
      session_id="dungeon-42",
      authority_key=@bft.PublicKey("mallory"),
      config=dungeon_config(),
      players=dungeon_players(),
      checkpoint=mallory_checkpoint,
      telegraph_source=seed.telegraph,
      attack=dungeon_attack(),
      dodge_evidence=[],
    ),
    DungeonReplayResult::Refused(DungeonReplayRefusal::InvalidTelegraph),
  )
}
