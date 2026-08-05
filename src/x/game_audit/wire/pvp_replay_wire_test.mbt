///|
fn pvp_wire_signed_event(
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
      op: @types.RowOp::Insert(tbl="wire.pvp", row_id=digest, values=[
        ("payload", @types.Value::Str("payload:" + digest)),
      ]),
    },
  }
}

///|
fn pvp_wire_bundle() -> PvpReplayBundle {
  let session = "pvp:wire-v1"
  let input = pvp_wire_signed_event(session, "alice", 0, "command", [])
  let receipt = pvp_wire_signed_event(session, "referee", 0, "receipt", [
    (input.event.id, input.digest),
  ])
  let checkpoint_digest = @bft.Digest("checkpoint-3")
  {
    referee_peer_id: "referee",
    signed_checkpoint: {
      checkpoint: {
        session_id: session,
        epoch: 3,
        previous_checkpoint: @bft.Digest("checkpoint-2"),
        manifest_digest: @bft.Digest("manifest"),
        event_root: @bft.Digest("event-root"),
        public_state_root: @bft.Digest("public-state-root"),
        asset_delta_root: @bft.Digest("no-assets"),
        hidden_state_commitment: None,
      },
      digest: checkpoint_digest,
      signature: @bft.Signature("checkpoint-signature"),
      authority_key: @bft.PublicKey("key:referee"),
    },
    config: {
      match_id: "match-1",
      epoch: 3,
      previous_checkpoint: @bft.Digest("checkpoint-2"),
      player_max_hp: 10,
      ticks_per_epoch: 8,
      max_late_ticks: 2,
      max_move_distance: 3,
      arena_min_x: -10,
      arena_max_x: 10,
      attack_range: 3,
      attack_damage: 6,
      score_per_elimination: 1,
    },
    teams: [
      { team_id: "blue", initial_score: 2 },
      { team_id: "orange", initial_score: 1 },
    ],
    players: [
      {
        player_id: "alice",
        public_key: @bft.PublicKey("key:alice"),
        team_id: "blue",
        initial_x: 0,
        initial_hp: 10,
      },
      {
        player_id: "bob",
        public_key: @bft.PublicKey("key:bob"),
        team_id: "orange",
        initial_x: 2,
        initial_hp: 10,
      },
    ],
    witnesses: [{ id: "witness-0", key: @bft.PublicKey("key:witness-0") }],
    max_faults: 0,
    commands: [
      {
        input,
        receipt,
        intent: {
          match_id: "match-1",
          epoch: 3,
          base_checkpoint_digest: @bft.Digest("checkpoint-2"),
          tick: 0,
          player_id: "alice",
          move_to_x: 0,
          attack_target_id: Some("bob"),
        },
        observed: { command_digest: input.digest, received_tick: 1 },
      },
    ],
    attestations: [
      {
        attestation: {
          checkpoint_digest,
          participant_id: "witness-0",
          purpose: @attestation.AttestationPurpose::ReplayWitness,
          choice: @attestation.AttestationChoice::Approve,
        },
        digest: @bft.Digest("attestation-digest"),
        signature: @bft.Signature("attestation-signature"),
        signer_key: @bft.PublicKey("key:witness-0"),
      },
    ],
  }
}

///|
test "PvP replay bundle has a canonical versioned round trip" {
  let bundle = pvp_wire_bundle()
  let encoded = encode_pvp_replay_bundle(bundle)
  let decoded = match
    decode_pvp_replay_bundle(encoded, limits=PvpReplayWireLimits::default()) {
    Ok(value) => value
    Err(_) => fail("expected PvP replay bundle decode")
  }
  assert_eq(encode_pvp_replay_bundle(decoded), encoded)
  assert_eq(decoded.referee_peer_id, bundle.referee_peer_id)
  assert_eq(decoded.signed_checkpoint, bundle.signed_checkpoint)
  assert_eq(decoded.config, bundle.config)
  assert_eq(decoded.teams, bundle.teams)
  assert_eq(decoded.players, bundle.players)
  assert_eq(decoded.witnesses, bundle.witnesses)
  assert_eq(decoded.max_faults, bundle.max_faults)
  assert_eq(decoded.commands[0].intent, bundle.commands[0].intent)
  assert_eq(decoded.commands[0].input.event, bundle.commands[0].input.event)
  assert_eq(decoded.attestations, bundle.attestations)
}

///|
test "PvP replay decoder rejects unsupported and noncanonical versions" {
  let encoded = encode_pvp_replay_bundle(pvp_wire_bundle())
  match
    decode_pvp_replay_bundle(
      replace_canonical_version(encoded, b'\x02'),
      limits=PvpReplayWireLimits::default(),
    ) {
    Err(PvpReplayWireError::PvpWireUnsupportedVersion(2)) => ()
    _ => fail("expected unsupported PvP wire version refusal")
  }
  match
    decode_pvp_replay_bundle(
      make_noncanonical_version(encoded),
      limits=PvpReplayWireLimits::default(),
    ) {
    Err(PvpReplayWireError::PvpWireNonCanonicalEncoding) => ()
    _ => fail("expected noncanonical PvP wire refusal")
  }
}

///|
test "PvP replay decoder enforces byte and collection budgets" {
  let encoded = encode_pvp_replay_bundle(pvp_wire_bundle())
  let defaults = PvpReplayWireLimits::default()
  match
    decode_pvp_replay_bundle(encoded, limits={
      ..defaults,
      max_bundle_bytes: encoded.length() - 1,
    }) {
    Err(PvpReplayWireError::PvpWireInputTooLarge(actual, maximum)) => {
      assert_eq(actual, encoded.length())
      assert_eq(maximum, encoded.length() - 1)
    }
    _ => fail("expected PvP byte-budget refusal")
  }
  match
    decode_pvp_replay_bundle(encoded, limits={ ..defaults, max_players: 1 }) {
    Err(PvpReplayWireError::PvpWirePlayersTooMany(2, 1)) => ()
    _ => fail("expected PvP player-budget refusal")
  }
  match
    decode_pvp_replay_bundle(encoded, limits={ ..defaults, max_commands: 0 }) {
    Err(PvpReplayWireError::PvpWireCommandsTooMany(1, 0)) => ()
    _ => fail("expected PvP command-budget refusal")
  }
  match
    decode_pvp_replay_bundle(encoded, limits={ ..defaults, max_attestations: 0 }) {
    Err(PvpReplayWireError::PvpWireAttestationsTooMany(1, 0)) => ()
    _ => fail("expected PvP attestation-budget refusal")
  }
  match
    decode_pvp_replay_bundle(encoded, limits={
      ..defaults,
      max_dependencies_per_event: 0,
    }) {
    Err(
      PvpReplayWireError::PvpWireCodecRefused(
        PveReplayWireError::PveWireDependenciesTooMany(1, 0)
      )
    ) => ()
    _ => fail("expected PvP dependency-budget refusal")
  }
}
