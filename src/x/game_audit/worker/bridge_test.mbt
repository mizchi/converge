///|
test "worker bridge creates and verifies a real-crypto anchor envelope" {
  let fixture = audit_benchmark_make_anchor_envelope(
    "000102030405060708090a0b0c0d0e0f" + "101112131415161718191a1b1c1d1e1f",
    "cf:pve:room-1",
    "observer-1",
    7,
    "checkpoint-6",
  )
  guard @json.parse(fixture) is Object(fixture_fields) else {
    fail("expected fixture object")
  }
  guard fixture_fields["ok"] is True &&
    fixture_fields["envelope_hex"] is String(envelope_hex) &&
    fixture_fields["authority_key"] is String(authority_key) else {
    fail("expected fixture fields")
  }
  let verified = audit_verify_anchor_envelope(
    envelope_hex, authority_key, "cf:pve:room-1",
  )
  guard @json.parse(verified) is Object(fields) else {
    fail("expected verification object")
  }
  guard fields["ok"] is True &&
    fields["epoch"] is Number(7.0, ..) &&
    fields["previous_digest"] is String("checkpoint-6") else {
    fail("expected verified metadata")
  }
}

///|
test "worker bridge rejects a tampered anchor envelope" {
  let fixture = audit_benchmark_make_anchor_envelope(
    "000102030405060708090a0b0c0d0e0f" + "101112131415161718191a1b1c1d1e1f",
    "cf:pvp:match-1",
    "observer-2",
    1,
    "genesis",
  )
  guard @json.parse(fixture) is Object(fields) &&
    fields["envelope_hex"] is String(envelope_hex) &&
    fields["authority_key"] is String(authority_key) else {
    fail("expected fixture fields")
  }
  let last = envelope_hex.length() - 1
  let replacement = if envelope_hex[last] == '0' { "1" } else { "0" }
  let tampered = envelope_hex[:last].to_owned() + replacement
  let verified = audit_verify_anchor_envelope(
    tampered, authority_key, "cf:pvp:match-1",
  )
  guard @json.parse(verified) is Object(verified_fields) else {
    fail("expected verification result")
  }
  guard verified_fields["ok"] is False else {
    fail("expected tampered envelope refusal")
  }
}

///|
test "worker bridge exposes the proved head classifier" {
  assert_eq(
    audit_classify_anchor_head(true, false, false, 7, 8, true),
    "advance",
  )
  assert_eq(
    audit_classify_anchor_head(true, true, false, 8, 8, false),
    "same_epoch_fork",
  )
  assert_eq(
    audit_classify_anchor_head(true, false, false, 8, 9, false),
    "wrong_parent_fork",
  )
  assert_eq(audit_classify_anchor_head(true, false, false, 8, 11, false), "gap")
}

///|
test "worker bridge exposes trusted closure and opaque atomic seal plan" {
  assert_eq(
    audit_open_checkpoint_closure(
      1, "checkpoint-v1", "manifest-1", "scope-1", "unit-1", 0, "roster-0", "frontier-0",
      "certificate-0", true, true, true,
    ),
    "ready",
  )
  let prepared = audit_prepare_atomic_checkpoint_seal(
    1,
    "checkpoint-v1",
    "manifest-1",
    "scope-1",
    "unit-1",
    0,
    "roster-0",
    "frontier-0",
    "certificate-0",
    -1,
    "genesis",
    false,
    false,
    false,
    false,
    0,
    8,
    0,
    0,
    "genesis",
    "checkpoint-0",
    "canonical-envelope-0",
    ["authority-1", "peer-2"],
  )
  guard @json.parse(prepared) is Object(fields) &&
    fields["decision"] is String("prepared") &&
    fields["epoch"] is Number(0.0, ..) &&
    fields["next_created_order"] is Number(2.0, ..) &&
    fields["outbox"] is Array(entries) &&
    entries.length() == 2 else {
    fail("expected prepared atomic seal plan")
  }
  assert_eq(
    audit_prepare_atomic_checkpoint_seal(
      1,
      "checkpoint-v1",
      "manifest-1",
      "scope-1",
      "unit-1",
      0,
      "roster-0",
      "frontier-0",
      "certificate-0",
      -1,
      "genesis",
      false,
      false,
      false,
      false,
      0,
      1,
      0,
      0,
      "genesis",
      "checkpoint-0",
      "canonical-envelope-0",
      ["authority-1", "peer-2"],
    ),
    "{\"decision\":\"refused\",\"reason\":\"outbox_capacity_exceeded\"}",
  )
}

///|
test "worker bridge acknowledges only exact authenticated successful checkpoint ACKs" {
  let acknowledge = fn(
    authority_id : String,
    ack_decision : String,
    authentication_succeeded : Bool,
  ) {
    audit_acknowledge_checkpoint_outbox(
      1, "checkpoint-v1", "manifest-1", "scope-1", "unit-1", "authority-1", 0, "checkpoint-0",
      "canonical-envelope-0", 0, 1, "checkpoint-v1", "manifest-1", "scope-1", "unit-1",
      authority_id, 0, "checkpoint-0", ack_decision, authentication_succeeded,
    )
  }
  assert_eq(acknowledge("authority-1", "accepted", true), "acknowledged")
  assert_eq(acknowledge("authority-1", "duplicate", true), "acknowledged")
  assert_eq(
    acknowledge("authority-2", "duplicate", true),
    "refused_authority_mismatch",
  )
  assert_eq(
    acknowledge("authority-1", "accepted", false),
    "refused_ack_authentication_failed",
  )
  assert_eq(
    acknowledge("authority-1", "gap", true),
    "refused_decision_not_successful",
  )
}

///|
test "worker bridge never treats anchor-only delivery as replay verification" {
  assert_eq(
    audit_classify_central_replay(true, false, false, false, false),
    "awaiting_transcript",
  )
  assert_eq(
    audit_classify_central_replay(true, true, true, true, true),
    "verified",
  )
  assert_eq(
    audit_classify_central_replay(true, true, true, true, false),
    "replay_mismatch",
  )
}

///|
test "worker bridge persists marketplace creation only through every proved binding" {
  assert_true(
    audit_marketplace_creation_persist_allowed(true, true, true, true, true),
  )
  assert_false(
    audit_marketplace_creation_persist_allowed(true, true, true, true, false),
  )
  assert_false(
    audit_marketplace_creation_persist_allowed(false, true, true, true, true),
  )
}

///|
test "worker bridge executes a real-crypto PvE checkpoint replay" {
  let authority_seed = "000102030405060708090a0b0c0d0e0f" +
    "101112131415161718191a1b1c1d1e1f"
  let player_seed = "202122232425262728292a2b2c2d2e2f" +
    "303132333435363738393a3b3c3d3e3f"
  let fixture = audit_benchmark_make_pve_replay_bundle(
    authority_seed, player_seed, "cf:pve:real-replay",
  )
  guard @json.parse(fixture) is Object(fields) &&
    fields["ok"] is True &&
    fields["bundle_hex"] is String(bundle_hex) &&
    fields["authority_key"] is String(authority_key) &&
    fields["checkpoint_digest"] is String(checkpoint_digest) else {
    fail("expected real replay fixture")
  }
  let verified = audit_verify_pve_replay_bundle(
    bundle_hex, "cf:pve:real-replay", authority_key, checkpoint_digest,
  )
  guard @json.parse(verified) is Object(result) &&
    result["ok"] is True &&
    result["complete"] is True &&
    result["cleared"] is True &&
    result["accepted_dodges"] is Number(1.0, ..) &&
    result["replayed_assets"] is Number(1.0, ..) else {
    fail("expected real deterministic replay verification")
  }
  let refused = audit_verify_pve_replay_bundle(
    bundle_hex,
    "cf:pve:real-replay",
    authority_key,
    "00" + checkpoint_digest[2:].to_owned(),
  )
  guard @json.parse(refused) is Object(refusal) &&
    refusal["ok"] is False &&
    refusal["error"] is String("expected_checkpoint_mismatch") else {
    fail("expected replay job-boundary refusal")
  }
}

///|
test "worker bridge executes real-crypto PvP replay and witness certification" {
  let referee_seed = "000102030405060708090a0b0c0d0e0f" +
    "101112131415161718191a1b1c1d1e1f"
  let participant_seed = "202122232425262728292a2b2c2d2e2f" +
    "303132333435363738393a3b3c3d3e3f"
  let fixture = audit_benchmark_make_pvp_replay_bundle(
    referee_seed, participant_seed, "cf:pvp:real-replay",
  )
  guard @json.parse(fixture) is Object(fields) &&
    fields["ok"] is True &&
    fields["bundle_hex"] is String(bundle_hex) &&
    fields["referee_key"] is String(referee_key) &&
    fields["checkpoint_digest"] is String(checkpoint_digest) else {
    fail("expected real PvP replay fixture")
  }
  let verified = audit_verify_pvp_replay_bundle(
    bundle_hex, "cf:pvp:real-replay", referee_key, checkpoint_digest,
  )
  guard @json.parse(verified) is Object(result) &&
    result["ok"] is True &&
    result["complete"] is True &&
    result["accepted_commands"] is Number(1.0, ..) &&
    result["approval_count"] is Number(3.0, ..) &&
    result["required_approvals"] is Number(3.0, ..) else {
    fail("expected real PvP replay witness verification")
  }
  let refused = audit_verify_pvp_replay_bundle(
    bundle_hex,
    "cf:pvp:real-replay",
    referee_key,
    "00" + checkpoint_digest[2:].to_owned(),
  )
  guard @json.parse(refused) is Object(refusal) &&
    refusal["ok"] is False &&
    refusal["error"] is String("expected_checkpoint_mismatch") else {
    fail("expected PvP replay job-boundary refusal")
  }
}

///|
test "worker bridge executes real-crypto open-world eligibility and observer replay" {
  let authority_seed = "000102030405060708090a0b0c0d0e0f" +
    "101112131415161718191a1b1c1d1e1f"
  let participant_seed = "202122232425262728292a2b2c2d2e2f" +
    "303132333435363738393a3b3c3d3e3f"
  let world_id = "cf:open:real-replay"
  let encounter_session_id = world_id + ":encounter-0"
  let fixture = audit_benchmark_make_open_world_pve_replay_bundle(
    authority_seed, participant_seed, world_id, encounter_session_id,
  )
  guard @json.parse(fixture) is Object(fields) &&
    fields["ok"] is True &&
    fields["bundle_hex"] is String(bundle_hex) &&
    fields["authority_key"] is String(authority_key) &&
    fields["transparency_log_session_id"] is String(transparency_log_session_id) &&
    fields["transparency_publisher_key"] is String(transparency_publisher_key) &&
    fields["transparency_checkpoint_digest"] is String(transparency_digest) &&
    fields["audit_checkpoint_digest"] is String(audit_digest) &&
    fields["seal_checkpoint_digest"] is String(seal_digest) &&
    fields["checkpoint_digest"] is String(encounter_digest) else {
    fail("expected real open-world replay fixture")
  }
  let verified = audit_verify_open_world_pve_replay_bundle(
    bundle_hex, world_id, encounter_session_id, authority_key, transparency_log_session_id,
    transparency_publisher_key, transparency_digest, audit_digest, seal_digest, encounter_digest,
  )
  guard @json.parse(verified) is Object(result) &&
    result["ok"] is True &&
    result["complete"] is True &&
    result["cleared"] is True &&
    result["observer_approvals"] is Number(3.0, ..) &&
    result["required_observer_approvals"] is Number(3.0, ..) &&
    result["verified_item_creations"] is Array([Object(item)]) &&
    item["initial_owner_id"] is String("alice") &&
    item["item_type"] is String("benchmark-open-world-token") else {
    fail("expected real open-world selective replay verification")
  }
  let refused = audit_verify_open_world_pve_replay_bundle(
    bundle_hex,
    world_id,
    encounter_session_id,
    authority_key,
    transparency_log_session_id,
    transparency_publisher_key,
    transparency_digest,
    "00" + audit_digest[2:].to_owned(),
    seal_digest,
    encounter_digest,
  )
  guard @json.parse(refused) is Object(refusal) &&
    refusal["ok"] is False &&
    refusal["error"] is String("expected_audit_checkpoint_mismatch") else {
    fail("expected open-world trusted-plan refusal")
  }
  let unpublished = audit_verify_open_world_pve_replay_bundle(
    bundle_hex,
    world_id,
    encounter_session_id,
    authority_key,
    transparency_log_session_id,
    transparency_publisher_key,
    "00" + transparency_digest[2:].to_owned(),
    audit_digest,
    seal_digest,
    encounter_digest,
  )
  guard @json.parse(unpublished) is Object(publication_refusal) &&
    publication_refusal["ok"] is False &&
    publication_refusal["error"] is String("audit_transparency_refused") else {
    fail("expected untrusted transparency-head refusal")
  }
}

///|
test "worker bridge verifies real-crypto current-owner inventory proof" {
  let authority_seed = "000102030405060708090a0b0c0d0e0f" +
    "101112131415161718191a1b1c1d1e1f"
  let participant_seed = "202122232425262728292a2b2c2d2e2f" +
    "303132333435363738393a3b3c3d3e3f"
  let fixture = audit_benchmark_make_inventory_listing_proof_bundle(
    authority_seed, participant_seed, "inventory-session", "creation-checkpoint",
    1, "asset-1", "alice", "bob", "raid-token", 1, "loot-event", 0, 1,
  )
  guard @json.parse(fixture) is Object(fields) &&
    fields["ok"] is True &&
    fields["bundle_hex"] is String(bundle_hex) &&
    fields["authority_key"] is String(authority_key) &&
    fields["checkpoint_digest"] is String(checkpoint_digest) &&
    fields["game_manifest_digest"] is String(game_manifest_digest) else {
    fail("expected real inventory listing fixture")
  }
  let verified = audit_verify_inventory_listing_proof_bundle(
    bundle_hex, "inventory-session", authority_key, checkpoint_digest, game_manifest_digest,
    "asset-1", "alice", "raid-token", 1, "loot-event", 0, "bob", false,
  )
  guard @json.parse(verified) is Object(result) &&
    result["ok"] is True &&
    result["current_owner_id"] is String("bob") &&
    result["version"] is Number(1.0, ..) &&
    result["previous_checkpoint"] is String("creation-checkpoint") else {
    fail("expected current-owner proof verification")
  }
  let stale_owner = audit_verify_inventory_listing_proof_bundle(
    bundle_hex, "inventory-session", authority_key, checkpoint_digest, game_manifest_digest,
    "asset-1", "alice", "raid-token", 1, "loot-event", 0, "alice", false,
  )
  guard @json.parse(stale_owner) is Object(refusal) &&
    refusal["ok"] is False &&
    refusal["error"] is String("current_owner_proof_refused") else {
    fail("expected stale owner refusal")
  }
}
