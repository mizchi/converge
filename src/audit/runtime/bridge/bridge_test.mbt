///|
test "runtime bridge exposes the generic checkpoint and peer contracts" {
  assert_eq(
    audit_classify_checkpoint_head(true, false, false, 7, 8, true),
    "advance",
  )
  let selected = audit_select_peer_delivery_batch(
    ["peer-1"],
    [true],
    [false],
    [0],
    [0],
    [0],
    10,
    0,
    2,
    1,
  )
  guard @json.parse(selected) is Object(fields) &&
    fields["decision"] is String("selected") else {
    fail("expected generic peer selection")
  }
}

///|
test "runtime bridge opens closure and prepares an atomic seal" {
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
    ["receiver-1", "peer-2"],
  )
  guard @json.parse(prepared) is Object(fields) &&
    fields["decision"] is String("prepared") &&
    fields["epoch"] is Number(0.0, ..) &&
    fields["next_created_order"] is Number(2.0, ..) &&
    fields["outbox"] is Array(entries) &&
    entries.length() == 2 else {
    fail("expected prepared atomic seal")
  }
}

///|
test "runtime bridge ACK remains exactly bound to its outbox entry" {
  let acknowledge = fn(
    receiver_id : String,
    decision : String,
    authentication_succeeded : Bool,
  ) {
    audit_acknowledge_checkpoint_outbox(
      1, "checkpoint-v1", "manifest-1", "scope-1", "unit-1", "receiver-1", 0, "checkpoint-0",
      "canonical-envelope-0", 0, 1, "checkpoint-v1", "manifest-1", "scope-1", "unit-1",
      receiver_id, 0, "checkpoint-0", decision, authentication_succeeded,
    )
  }
  assert_eq(acknowledge("receiver-1", "accepted", true), "acknowledged")
  assert_eq(
    acknowledge("receiver-2", "accepted", true),
    "refused_authority_mismatch",
  )
  assert_eq(
    acknowledge("receiver-1", "accepted", false),
    "refused_ack_authentication_failed",
  )
  assert_eq(
    acknowledge("receiver-1", "gap", true),
    "refused_decision_not_successful",
  )
}

///|
test "runtime bridge persists peer backoff and prioritizes authenticated forks" {
  let failed = audit_record_peer_delivery_failure(
    "peer-1", true, false, 0, 0, 0, 100, 1, 10, 100,
  )
  guard @json.parse(failed) is Object(failed_fields) &&
    failed_fields["decision"] is String("updated") &&
    failed_fields["route"] is Object(route) &&
    route["next_retry_at_ms"] is Number(110.0, ..) else {
    fail("expected persisted peer backoff")
  }
  let succeeded = audit_record_peer_delivery_success(
    "peer-1", true, false, 1, 110, 1, 2,
  )
  guard @json.parse(succeeded) is Object(success_fields) &&
    success_fields["decision"] is String("updated") else {
    fail("expected success reset")
  }
  let selected = audit_select_peer_checkpoint_response(
    ["peer-1", "peer-2"],
    ["expected", "fork"],
    [true, true],
    [10, 20],
    "expected",
  )
  guard @json.parse(selected) is Object(selection) &&
    selection["decision"] is String("fork_detected") &&
    selection["fork_count"] is Number(1.0, ..) else {
    fail("expected authenticated fork priority")
  }
}
