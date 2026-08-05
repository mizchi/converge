///|
fn pve_wire_signed_event(
  session_id : String,
  peer_id : String,
  counter : Int,
  digest : String,
  dependencies : Array[(@types.EventId, @bft.Digest)],
) -> @bft.SignedEvent {
  let event_dependencies : Array[@types.EventId] = []
  let digest_dependencies : Array[@bft.Digest] = []
  for dependency in dependencies {
    event_dependencies.push(dependency.0)
    digest_dependencies.push(dependency.1)
  }
  {
    session_id,
    digest: @bft.Digest(digest),
    signature: @bft.Signature("signature:" + digest),
    author_key: @bft.PublicKey("key:" + peer_id),
    dep_hashes: digest_dependencies,
    event: {
      id: { peer: @types.PeerId(peer_id), counter },
      deps: event_dependencies,
      lamport: counter + 1,
      op: @types.RowOp::Insert(tbl="wire.events", row_id=digest, values=[
        ("null", @types.Value::Null),
        ("bool", @types.Value::Bool(true)),
        ("int", @types.Value::Int(-7)),
        ("float", @types.Value::Float(1.5)),
        ("str", @types.Value::Str("payload:" + digest)),
      ]),
    },
  }
}

///|
fn pve_wire_bundle() -> PveReplayBundle {
  let session = "dungeon:wire-v1"
  let telegraph = pve_wire_signed_event(
    session,
    "authority",
    0,
    "telegraph-digest",
    [],
  )
  let input = pve_wire_signed_event(session, "alice", 0, "input-digest", [
    (telegraph.event.id, telegraph.digest),
  ])
  let receipt = pve_wire_signed_event(
    session,
    "authority",
    1,
    "receipt-digest",
    [(input.event.id, input.digest)],
  )
  let loot_effect = @replay.AssetEffect::Create(
    asset_id="loot:alice",
    recipient_id="alice",
    item_type="boss-token",
    quantity=1,
    output_index=0,
  )
  let loot_source = pve_wire_signed_event(
    session,
    "authority",
    2,
    "loot-digest",
    [(receipt.event.id, receipt.digest)],
  )
  {
    authority_peer_id: "authority",
    signed_checkpoint: {
      checkpoint: {
        session_id: session,
        epoch: 3,
        previous_checkpoint: @bft.Digest("checkpoint-2"),
        manifest_digest: @bft.Digest("manifest"),
        event_root: @bft.Digest("event-root"),
        public_state_root: @bft.Digest("public-state-root"),
        asset_delta_root: @bft.Digest("asset-delta-root"),
        hidden_state_commitment: Some(@bft.Digest("hidden")),
      },
      digest: @bft.Digest("checkpoint-3"),
      signature: @bft.Signature("checkpoint-signature"),
      authority_key: @bft.PublicKey("key:authority"),
    },
    config: {
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
    },
    players: [
      {
        player_id: "alice",
        public_key: @bft.PublicKey("key:alice"),
        initial_x: 0,
      },
    ],
    attacks: [
      {
        attack: {
          attack_id: "cleave-1",
          visible_tick: 10,
          resolve_tick: 16,
          center_x: 0,
          radius: 2,
        },
        damage: 6,
      },
    ],
    transcripts: [
      {
        attack_id: "cleave-1",
        telegraph,
        dodge_evidence: [
          {
            input,
            receipt,
            intent: {
              attack_id: "cleave-1",
              player_id: "alice",
              telegraph_digest: telegraph.digest,
              client_tick: 13,
              to_x: 5,
            },
            observed: { input_digest: input.digest, received_tick: 14 },
          },
        ],
      },
    ],
    asset_effects: [{ source: loot_source, effect: loot_effect }],
  }
}

///|
test "PvE replay bundle has a canonical versioned round trip" {
  let bundle = pve_wire_bundle()
  let encoded = encode_pve_replay_bundle(bundle)
  let decoded = match
    decode_pve_replay_bundle(encoded, limits=PveReplayWireLimits::default()) {
    Ok(value) => value
    Err(_) => fail("expected PvE replay bundle decode")
  }
  assert_eq(encode_pve_replay_bundle(decoded), encoded)
  assert_eq(decoded.authority_peer_id, bundle.authority_peer_id)
  assert_eq(decoded.signed_checkpoint, bundle.signed_checkpoint)
  assert_eq(decoded.config, bundle.config)
  assert_eq(decoded.players, bundle.players)
  assert_eq(decoded.asset_effects.length(), 1)
  assert_eq(
    decoded.asset_effects[0].source.digest,
    bundle.asset_effects[0].source.digest,
  )
  assert_eq(
    decoded.asset_effects[0].source.event,
    bundle.asset_effects[0].source.event,
  )
  assert_eq(decoded.asset_effects[0].effect, bundle.asset_effects[0].effect)
  assert_eq(decoded.attacks, bundle.attacks)
  assert_eq(decoded.transcripts.length(), 1)
  assert_eq(decoded.transcripts[0].dodge_evidence.length(), 1)
  assert_eq(
    decoded.transcripts[0].dodge_evidence[0].input.event,
    bundle.transcripts[0].dodge_evidence[0].input.event,
  )
}

///|
test "PvE replay decoder rejects unsupported and noncanonical versions" {
  let encoded = encode_pve_replay_bundle(pve_wire_bundle())
  match
    decode_pve_replay_bundle(
      replace_canonical_version(encoded, b'\x03'),
      limits=PveReplayWireLimits::default(),
    ) {
    Err(PveReplayWireError::PveWireUnsupportedVersion(3)) => ()
    _ => fail("expected unsupported PvE wire version refusal")
  }
  match
    decode_pve_replay_bundle(
      make_noncanonical_version(encoded),
      limits=PveReplayWireLimits::default(),
    ) {
    Err(PveReplayWireError::PveWireNonCanonicalEncoding) => ()
    _ => fail("expected noncanonical PvE wire refusal")
  }
}

///|
test "PvE replay decoder enforces byte and collection budgets" {
  let encoded = encode_pve_replay_bundle(pve_wire_bundle())
  let defaults = PveReplayWireLimits::default()
  match
    decode_pve_replay_bundle(encoded, limits={
      ..defaults,
      max_bundle_bytes: encoded.length() - 1,
    }) {
    Err(PveReplayWireError::PveWireInputTooLarge(actual, maximum)) => {
      assert_eq(actual, encoded.length())
      assert_eq(maximum, encoded.length() - 1)
    }
    _ => fail("expected PvE byte-budget refusal")
  }
  match
    decode_pve_replay_bundle(encoded, limits={ ..defaults, max_players: 0 }) {
    Err(PveReplayWireError::PveWirePlayersTooMany(1, 0)) => ()
    _ => fail("expected PvE player-budget refusal")
  }
  match
    decode_pve_replay_bundle(encoded, limits={
      ..defaults,
      max_total_dodge_evidence: 0,
    }) {
    Err(PveReplayWireError::PveWireDodgeEvidenceTooMany(1, 0)) => ()
    _ => fail("expected PvE evidence-budget refusal")
  }
  match
    decode_pve_replay_bundle(encoded, limits={
      ..defaults,
      max_asset_effects: 0,
    }) {
    Err(PveReplayWireError::PveWireAssetEffectsTooMany(1, 0)) => ()
    _ => fail("expected PvE asset-effect-budget refusal")
  }
  match
    decode_pve_replay_bundle(encoded, limits={
      ..defaults,
      max_dependencies_per_event: 0,
    }) {
    Err(PveReplayWireError::PveWireDependenciesTooMany(1, 0)) => ()
    _ => fail("expected PvE dependency-budget refusal")
  }
}
