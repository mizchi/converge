///|
fn open_world_replay_wire_bundle() -> OpenWorldPveReplayBundle {
  let encounter = pve_wire_bundle()
  let audit_digest = @bft.Digest("open-world-audit-plan")
  let encounter_digest = encounter.signed_checkpoint.digest
  let observation = @open_world.OpenWorldRegistrationObservation::{
    audit_checkpoint_digest: audit_digest,
    observer_id: "observer-0",
    registration_index: 0,
    encounter_digest,
  }
  {
    signed_audit_checkpoint: {
      checkpoint: {
        session_id: "world:wire-v1",
        epoch: 10,
        previous_checkpoint: @bft.Digest("world-9"),
        manifest_digest: @bft.Digest("audit-manifest"),
        event_root: @bft.Digest("audit-events"),
        public_state_root: @bft.Digest("audit-state"),
        asset_delta_root: @bft.Digest("audit-assets"),
        hidden_state_commitment: Some(@bft.Digest("seed-commitment")),
      },
      digest: audit_digest,
      signature: @bft.Signature("audit-signature"),
      authority_key: @bft.PublicKey("world-authority"),
    },
    signed_anchor_seal_checkpoint: {
      checkpoint: {
        session_id: "world:wire-v1",
        epoch: 11,
        previous_checkpoint: audit_digest,
        manifest_digest: @bft.Digest("seal-manifest"),
        event_root: @bft.Digest("eligible-root"),
        public_state_root: @bft.Digest("registry-root"),
        asset_delta_root: @bft.Digest("seal-assets"),
        hidden_state_commitment: None,
      },
      digest: @bft.Digest("open-world-anchor-seal"),
      signature: @bft.Signature("seal-signature"),
      authority_key: @bft.PublicKey("world-authority"),
    },
    audit_transparency: {
      signed_checkpoint: {
        checkpoint: {
          session_id: "world:wire-v1:transparency",
          epoch: 4,
          previous_checkpoint: @bft.Digest("transparency-3"),
          manifest_digest: @bft.Digest("transparency-manifest"),
          event_root: @bft.Digest("transparency-events"),
          public_state_root: @bft.Digest("transparency-root"),
          asset_delta_root: @bft.Digest("transparency-assets"),
          hidden_state_commitment: None,
        },
        digest: @bft.Digest("transparency-checkpoint"),
        signature: @bft.Signature("transparency-signature"),
        authority_key: @bft.PublicKey("transparency-publisher"),
      },
      audit_membership_proof: {
        key: "audit-key",
        value: "audit-value",
        left_digest: @bft.Digest("audit-left"),
        right_digest: @bft.Digest("audit-right"),
        entry_count: 2,
        path: [],
      },
      seal_membership_proof: {
        key: "seal-key",
        value: "seal-value",
        left_digest: @bft.Digest("seal-left"),
        right_digest: @bft.Digest("seal-right"),
        entry_count: 2,
        path: [],
      },
    },
    game_manifest_digest: @bft.Digest("open-world-game-v1"),
    sample_numerator: 1,
    sample_denominator: 16,
    registered_count: 1,
    seed: "revealed-seed",
    observers: [{ id: "observer-0", key: @bft.PublicKey("observer-key-0") }],
    max_faults: 0,
    observations: [
      {
        observation,
        digest: @bft.Digest("observation-digest"),
        signature: @bft.Signature("observation-signature"),
        signer_key: @bft.PublicKey("observer-key-0"),
      },
    ],
    eligibility_proof: { leaf_index: 0, leaf_count: 1, path: [] },
    encounter,
  }
}

///|
test "open-world replay bundle has a canonical versioned round trip" {
  let bundle = open_world_replay_wire_bundle()
  let encoded = encode_open_world_pve_replay_bundle(bundle)
  let decoded = match
    decode_open_world_pve_replay_bundle(
      encoded,
      limits=OpenWorldPveReplayWireLimits::default(),
    ) {
    Ok(value) => value
    Err(_) => fail("expected open-world replay bundle decode")
  }
  assert_eq(encode_open_world_pve_replay_bundle(decoded), encoded)
  assert_eq(decoded.signed_audit_checkpoint, bundle.signed_audit_checkpoint)
  assert_eq(
    decoded.signed_anchor_seal_checkpoint,
    bundle.signed_anchor_seal_checkpoint,
  )
  assert_eq(decoded.audit_transparency, bundle.audit_transparency)
  assert_eq(decoded.observers, bundle.observers)
  assert_eq(decoded.observations, bundle.observations)
  assert_eq(decoded.eligibility_proof, bundle.eligibility_proof)
  assert_eq(
    encode_pve_replay_bundle(decoded.encounter),
    encode_pve_replay_bundle(bundle.encounter),
  )
}

///|
test "open-world replay decoder rejects unsupported and noncanonical versions" {
  let encoded = encode_open_world_pve_replay_bundle(
    open_world_replay_wire_bundle(),
  )
  match
    decode_open_world_pve_replay_bundle(
      replace_canonical_version(encoded, b'\x03'),
      limits=OpenWorldPveReplayWireLimits::default(),
    ) {
    Err(OpenWorldPveReplayWireError::OpenWorldReplayUnsupportedVersion(3)) => ()
    _ => fail("expected unsupported open-world replay version")
  }
  match
    decode_open_world_pve_replay_bundle(
      make_noncanonical_version(encoded),
      limits=OpenWorldPveReplayWireLimits::default(),
    ) {
    Err(OpenWorldPveReplayWireError::OpenWorldReplayNonCanonicalEncoding) => ()
    _ => fail("expected noncanonical open-world replay refusal")
  }
}

///|
test "open-world replay decoder enforces outer proof and nested replay budgets" {
  let bundle = open_world_replay_wire_bundle()
  let encoded = encode_open_world_pve_replay_bundle(bundle)
  let defaults = OpenWorldPveReplayWireLimits::default()
  match
    decode_open_world_pve_replay_bundle(encoded, limits={
      ..defaults,
      max_bundle_bytes: encoded.length() - 1,
    }) {
    Err(OpenWorldPveReplayWireError::OpenWorldReplayInputTooLarge(_, _)) => ()
    _ => fail("expected open-world byte-budget refusal")
  }
  match
    decode_open_world_pve_replay_bundle(encoded, limits={
      ..defaults,
      max_observers: 0,
    }) {
    Err(OpenWorldPveReplayWireError::OpenWorldReplayObserversTooMany(1, 0)) =>
      ()
    _ => fail("expected open-world observer-budget refusal")
  }
  match
    decode_open_world_pve_replay_bundle(encoded, limits={
      ..defaults,
      max_observations: 0,
    }) {
    Err(OpenWorldPveReplayWireError::OpenWorldReplayObservationsTooMany(1, 0)) =>
      ()
    _ => fail("expected open-world observation-budget refusal")
  }
  let with_transparency_step = OpenWorldPveReplayBundle::{
    ..bundle,
    audit_transparency: {
      ..bundle.audit_transparency,
      audit_membership_proof: {
        ..bundle.audit_transparency.audit_membership_proof,
        path: [
          @authmap.AuthMapStep::DescendedLeft(
            "sibling-key",
            "sibling-value",
            @bft.Digest("sibling-digest"),
          ),
        ],
      },
    },
  }
  match
    decode_open_world_pve_replay_bundle(
      encode_open_world_pve_replay_bundle(with_transparency_step),
      limits={ ..defaults, max_transparency_proof_steps: 0 },
    ) {
    Err(
      OpenWorldPveReplayWireError::OpenWorldReplayTransparencyCodecRefused(
        OpenWorldAuditWireError::WireProofTooLong(1, 0)
      )
    ) => ()
    _ => fail("expected transparency proof-budget refusal")
  }
  let with_step = OpenWorldPveReplayBundle::{
    ..bundle,
    eligibility_proof: {
      leaf_index: 0,
      leaf_count: 2,
      path: [@merkle.MerkleStep::SiblingRight(@bft.Digest("sibling"))],
    },
  }
  match
    decode_open_world_pve_replay_bundle(
      encode_open_world_pve_replay_bundle(with_step),
      limits={ ..defaults, max_merkle_steps: 0 },
    ) {
    Err(OpenWorldPveReplayWireError::OpenWorldReplayProofTooLong(1, 0)) => ()
    _ => fail("expected open-world proof-budget refusal")
  }
  match
    decode_open_world_pve_replay_bundle(encoded, limits={
      ..defaults,
      pve: { ..defaults.pve, max_players: 0 },
    }) {
    Err(
      OpenWorldPveReplayWireError::OpenWorldReplayPveCodecRefused(
        PveReplayWireError::PveWirePlayersTooMany(1, 0)
      )
    ) => ()
    _ => fail("expected nested PvE player-budget refusal")
  }
}
