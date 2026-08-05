///|
fn bridge_boundary(
  protocol_version : Int,
  purpose : String,
  manifest_digest : String,
  scope_id : String,
  unit_id : String,
) -> @audit_runtime.AuditBoundary {
  {
    protocol_version,
    purpose,
    manifest_digest: @commitment.AuditDigest(manifest_digest),
    scope_id,
    unit_id,
  }
}

///|
/// Stable primitive-only bridge to the proof-checked head classifier.
pub fn audit_classify_checkpoint_head(
  boundary_matches : Bool,
  epoch_known : Bool,
  known_digest_matches : Bool,
  current_epoch : Int,
  incoming_epoch : Int,
  parent_matches : Bool,
) -> String {
  match
    @checkpoint_audit.classify_checkpoint_head(
      boundary_matches~,
      epoch_known~,
      known_digest_matches~,
      current_epoch~,
      incoming_epoch~,
      parent_matches~,
    ) {
    @checkpoint_audit.CheckpointHeadDecision::Advance => "advance"
    @checkpoint_audit.CheckpointHeadDecision::Duplicate => "duplicate"
    @checkpoint_audit.CheckpointHeadDecision::SameEpochFork => "same_epoch_fork"
    @checkpoint_audit.CheckpointHeadDecision::ParentFork => "wrong_parent_fork"
    @checkpoint_audit.CheckpointHeadDecision::Gap => "gap"
    @checkpoint_audit.CheckpointHeadDecision::Stale => "stale"
    @checkpoint_audit.CheckpointHeadDecision::BoundaryMismatch =>
      "boundary_rejected"
  }
}

///|
/// Stable bridge for persisting only closure evidence that can mint the
/// runtime's opaque `TrustedEpochClosure` capability.
pub fn audit_open_checkpoint_closure(
  protocol_version : Int,
  purpose : String,
  manifest_digest : String,
  scope_id : String,
  unit_id : String,
  epoch : Int,
  roster_digest : String,
  frontier_digest : String,
  certificate_digest : String,
  frontier_complete : Bool,
  conflict_free : Bool,
  quorum_satisfied : Bool,
) -> String {
  let boundary = bridge_boundary(
    protocol_version, purpose, manifest_digest, scope_id, unit_id,
  )
  let evidence = @audit_runtime.EpochClosureEvidence::{
    boundary,
    epoch,
    roster_digest: @commitment.AuditDigest(roster_digest),
    frontier_digest: @commitment.AuditDigest(frontier_digest),
    certificate_digest: @commitment.AuditDigest(certificate_digest),
  }
  match
    @audit_runtime.open_trusted_epoch_closure(
      evidence,
      frontier_complete~,
      conflict_free~,
      quorum_satisfied~,
    ) {
    @audit_runtime.EpochClosureOpenResult::EpochClosureReady(_) => "ready"
    @audit_runtime.EpochClosureOpenResult::EpochClosurePending(reason) =>
      match reason {
        @audit_runtime.EpochClosurePendingReason::MissingFrontierEvents =>
          "pending_missing_frontier"
        @audit_runtime.EpochClosurePendingReason::UnderQuorum =>
          "pending_under_quorum"
      }
    @audit_runtime.EpochClosureOpenResult::EpochClosureConflict(_) =>
      "conflict_equivocation"
    @audit_runtime.EpochClosureOpenResult::EpochClosureRefused(_) =>
      "refused_invalid_evidence"
  }
}

///|
fn bridge_checkpoint_seal_conflict_code(
  reason : @audit_runtime.CheckpointSealConflictReason,
) -> String {
  match reason {
    @audit_runtime.CheckpointSealConflictReason::SealSameEpochFork =>
      "same_epoch_fork"
    @audit_runtime.CheckpointSealConflictReason::SealParentFork => "parent_fork"
    @audit_runtime.CheckpointSealConflictReason::SealIncompleteKnownCommit =>
      "incomplete_known_commit"
  }
}

///|
fn bridge_checkpoint_seal_refusal_code(
  reason : @audit_runtime.CheckpointSealRefusal,
) -> String {
  match reason {
    @audit_runtime.CheckpointSealRefusal::SealInvalidStorageSnapshot =>
      "invalid_storage_snapshot"
    @audit_runtime.CheckpointSealRefusal::SealInvalidCheckpointDraft =>
      "invalid_checkpoint_draft"
    @audit_runtime.CheckpointSealRefusal::SealBoundaryMismatch =>
      "boundary_mismatch"
    @audit_runtime.CheckpointSealRefusal::SealClosureEpochMismatch =>
      "closure_epoch_mismatch"
    @audit_runtime.CheckpointSealRefusal::SealClosureAlreadyConsumed =>
      "closure_already_consumed"
    @audit_runtime.CheckpointSealRefusal::SealEpochGap => "epoch_gap"
    @audit_runtime.CheckpointSealRefusal::SealStaleEpoch => "stale_epoch"
    @audit_runtime.CheckpointSealRefusal::SealDestinationsEmpty =>
      "destinations_empty"
    @audit_runtime.CheckpointSealRefusal::SealDestinationEmpty =>
      "destination_empty"
    @audit_runtime.CheckpointSealRefusal::SealDestinationDuplicate =>
      "destination_duplicate"
    @audit_runtime.CheckpointSealRefusal::SealOutboxCapacityExceeded =>
      "outbox_capacity_exceeded"
    @audit_runtime.CheckpointSealRefusal::SealCreatedOrderOverflow =>
      "created_order_overflow"
  }
}

///|
/// Recreate an admitted closure capability and expose a prepared opaque write
/// set as JSON. Transaction/CAS and durable mutation remain adapter concerns.
pub fn audit_prepare_atomic_checkpoint_seal(
  protocol_version : Int,
  purpose : String,
  manifest_digest : String,
  scope_id : String,
  unit_id : String,
  closure_epoch : Int,
  roster_digest : String,
  frontier_digest : String,
  certificate_digest : String,
  current_epoch : Int,
  current_digest : String,
  incoming_epoch_known : Bool,
  known_digest_matches : Bool,
  known_seal_complete : Bool,
  closure_consumed : Bool,
  outbox_entry_count : Int,
  outbox_capacity : Int,
  next_created_order : Int,
  checkpoint_epoch : Int,
  previous_checkpoint : String,
  checkpoint_digest : String,
  canonical_envelope : String,
  destinations : Array[String],
) -> String {
  let boundary = bridge_boundary(
    protocol_version, purpose, manifest_digest, scope_id, unit_id,
  )
  let closure_evidence = @audit_runtime.EpochClosureEvidence::{
    boundary,
    epoch: closure_epoch,
    roster_digest: @commitment.AuditDigest(roster_digest),
    frontier_digest: @commitment.AuditDigest(frontier_digest),
    certificate_digest: @commitment.AuditDigest(certificate_digest),
  }
  let closure = match
    @audit_runtime.open_trusted_epoch_closure(
      closure_evidence,
      frontier_complete=true,
      conflict_free=true,
      quorum_satisfied=true,
    ) {
    @audit_runtime.EpochClosureOpenResult::EpochClosureReady(value) => value
    _ =>
      return Json::object({
        "decision": Json::string("refused"),
        "reason": Json::string("stored_closure_invalid"),
      }).stringify()
  }
  let snapshot = @audit_runtime.CheckpointSealStorageSnapshot::{
    boundary,
    current_epoch,
    current_digest: @commitment.AuditDigest(current_digest),
    incoming_epoch_known,
    known_digest_matches,
    known_seal_complete,
    closure_consumed,
    outbox_entry_count,
    outbox_capacity,
    next_created_order,
  }
  let draft = @audit_runtime.CheckpointSealDraft::{
    boundary,
    epoch: checkpoint_epoch,
    previous_checkpoint: @commitment.AuditDigest(previous_checkpoint),
    checkpoint_digest: @commitment.AuditDigest(checkpoint_digest),
    canonical_envelope,
  }
  match
    @audit_runtime.prepare_atomic_checkpoint_seal(
      snapshot, draft, closure, destinations,
    ) {
    @audit_runtime.AtomicCheckpointSealResult::AtomicCheckpointSealPrepared(
      plan
    ) => {
      let outbox = Json::array(
        plan
        .outbox_entries()
        .map(fn(entry) {
          Json::object({
            "destination_id": Json::string(entry.destination_id()),
            "epoch": Json::number(entry.epoch().to_double()),
            "checkpoint_digest": Json::string(entry.checkpoint_digest().0),
            "canonical_envelope": Json::string(entry.canonical_envelope()),
            "created_order": Json::number(entry.created_order().to_double()),
          })
        }),
      )
      Json::object({
        "decision": Json::string("prepared"),
        "epoch": Json::number(plan.next_head().epoch.to_double()),
        "digest": Json::string(plan.next_head().checkpoint_digest.0),
        "closure_epoch": Json::number(plan.consumed_closure_epoch().to_double()),
        "next_outbox_entry_count": Json::number(
          plan.next_outbox_entry_count().to_double(),
        ),
        "next_created_order": Json::number(
          plan.next_created_order().to_double(),
        ),
        "outbox": outbox,
      }).stringify()
    }
    @audit_runtime.AtomicCheckpointSealResult::CheckpointSealAlreadyCommitted =>
      Json::object({ "decision": Json::string("duplicate") }).stringify()
    @audit_runtime.AtomicCheckpointSealResult::CheckpointSealConflict(reason) =>
      Json::object({
        "decision": Json::string("conflict"),
        "reason": Json::string(bridge_checkpoint_seal_conflict_code(reason)),
      }).stringify()
    @audit_runtime.AtomicCheckpointSealResult::CheckpointSealRefused(reason) =>
      Json::object({
        "decision": Json::string("refused"),
        "reason": Json::string(bridge_checkpoint_seal_refusal_code(reason)),
      }).stringify()
  }
}

///|
fn bridge_peer_route_json(route : @audit_runtime.PeerRouteState) -> Json {
  Json::object({
    "peer_id": Json::string(route.peer_id),
    "available": Json::boolean(route.available),
    "quarantined": Json::boolean(route.quarantined),
    "failures": Json::number(route.failures.to_double()),
    "next_retry_at_ms": Json::number(route.next_retry_at_ms.to_double()),
    "last_attempt_order": Json::number(route.last_attempt_order.to_double()),
  })
}

///|
fn bridge_peer_route(
  peer_id : String,
  available : Bool,
  quarantined : Bool,
  failures : Int,
  next_retry_at_ms : Int,
  last_attempt_order : Int,
) -> @audit_runtime.PeerRouteState {
  {
    peer_id,
    available,
    quarantined,
    failures,
    next_retry_at_ms,
    last_attempt_order,
  }
}

///|
/// JS adapter for the pure bounded-fanout selector. Parallel arrays avoid
/// trusting JSON decoding inside the proof-facing package.
pub fn audit_select_peer_delivery_batch(
  peer_ids : Array[String],
  available : Array[Bool],
  quarantined : Array[Bool],
  failures : Array[Int],
  next_retry_at_ms : Array[Int],
  last_attempt_order : Array[Int],
  now_ms : Int,
  in_flight_count : Int,
  max_in_flight : Int,
  max_parallel : Int,
) -> String {
  let count = peer_ids.length()
  if available.length() != count ||
    quarantined.length() != count ||
    failures.length() != count ||
    next_retry_at_ms.length() != count ||
    last_attempt_order.length() != count {
    return Json::object({
      "decision": Json::string("refused"),
      "reason": Json::string("parallel_array_length_mismatch"),
    }).stringify()
  }
  let routes : Array[@audit_runtime.PeerRouteState] = []
  for index = 0; index < count; index = index + 1 {
    routes.push(
      bridge_peer_route(
        peer_ids[index],
        available[index],
        quarantined[index],
        failures[index],
        next_retry_at_ms[index],
        last_attempt_order[index],
      ),
    )
  }
  match
    @audit_runtime.select_peer_delivery_batch(
      routes,
      now_ms~,
      in_flight_count~,
      max_in_flight~,
      max_parallel~,
    ) {
    @audit_runtime.PeerDeliverySelectionResult::PeerDeliverySelected(indices) =>
      Json::object({
        "decision": Json::string("selected"),
        "indices": Json::array(
          indices.map(fn(index) { Json::number(index.to_double()) }),
        ),
      }).stringify()
    @audit_runtime.PeerDeliverySelectionResult::PeerDeliveryUnavailable =>
      Json::object({ "decision": Json::string("unavailable") }).stringify()
    @audit_runtime.PeerDeliverySelectionResult::PeerDeliveryBackpressured =>
      Json::object({ "decision": Json::string("backpressured") }).stringify()
    @audit_runtime.PeerDeliverySelectionResult::PeerDeliveryRefused(_) =>
      Json::object({
        "decision": Json::string("refused"),
        "reason": Json::string("invalid_delivery_selection"),
      }).stringify()
  }
}

///|
pub fn audit_record_peer_delivery_failure(
  peer_id : String,
  available : Bool,
  quarantined : Bool,
  failures : Int,
  next_retry_at_ms : Int,
  last_attempt_order : Int,
  now_ms : Int,
  attempt_order : Int,
  base_backoff_ms : Int,
  max_backoff_ms : Int,
) -> String {
  match
    @audit_runtime.record_peer_delivery_failure(
      bridge_peer_route(
        peer_id, available, quarantined, failures, next_retry_at_ms, last_attempt_order,
      ),
      now_ms~,
      attempt_order~,
      base_backoff_ms~,
      max_backoff_ms~,
    ) {
    @audit_runtime.PeerRouteUpdateResult::PeerRouteUpdated(route) =>
      Json::object({
        "decision": Json::string("updated"),
        "route": bridge_peer_route_json(route),
      }).stringify()
    @audit_runtime.PeerRouteUpdateResult::PeerRouteUpdateRefused =>
      Json::object({ "decision": Json::string("refused") }).stringify()
  }
}

///|
pub fn audit_record_peer_delivery_success(
  peer_id : String,
  available : Bool,
  quarantined : Bool,
  failures : Int,
  next_retry_at_ms : Int,
  last_attempt_order : Int,
  attempt_order : Int,
) -> String {
  match
    @audit_runtime.record_peer_delivery_success(
      bridge_peer_route(
        peer_id, available, quarantined, failures, next_retry_at_ms, last_attempt_order,
      ),
      attempt_order~,
    ) {
    @audit_runtime.PeerRouteUpdateResult::PeerRouteUpdated(route) =>
      Json::object({
        "decision": Json::string("updated"),
        "route": bridge_peer_route_json(route),
      }).stringify()
    @audit_runtime.PeerRouteUpdateResult::PeerRouteUpdateRefused =>
      Json::object({ "decision": Json::string("refused") }).stringify()
  }
}

///|
pub fn audit_select_peer_checkpoint_response(
  peer_ids : Array[String],
  checkpoint_digests : Array[String],
  authenticated : Array[Bool],
  received_at_ms : Array[Int],
  expected_digest : String,
) -> String {
  let count = peer_ids.length()
  if checkpoint_digests.length() != count ||
    authenticated.length() != count ||
    received_at_ms.length() != count {
    return Json::object({ "decision": Json::string("refused") }).stringify()
  }
  let responses : Array[@audit_runtime.PeerCheckpointResponse] = []
  for index = 0; index < count; index = index + 1 {
    responses.push({
      peer_id: peer_ids[index],
      checkpoint_digest: @commitment.AuditDigest(checkpoint_digests[index]),
      authenticated: authenticated[index],
      received_at_ms: received_at_ms[index],
    })
  }
  match
    @audit_runtime.select_peer_checkpoint_response(
      responses,
      expected_digest=@commitment.AuditDigest(expected_digest),
    ) {
    @audit_runtime.PeerCheckpointResponseSelection::PeerCheckpointResponseAccepted(
      index
    ) =>
      Json::object({
        "decision": Json::string("accepted"),
        "index": Json::number(index.to_double()),
      }).stringify()
    @audit_runtime.PeerCheckpointResponseSelection::PeerCheckpointForkDetected(
      count
    ) =>
      Json::object({
        "decision": Json::string("fork_detected"),
        "fork_count": Json::number(count.to_double()),
      }).stringify()
    @audit_runtime.PeerCheckpointResponseSelection::PeerCheckpointResponseUnavailable =>
      Json::object({ "decision": Json::string("unavailable") }).stringify()
    @audit_runtime.PeerCheckpointResponseSelection::PeerCheckpointResponseRefused =>
      Json::object({ "decision": Json::string("refused") }).stringify()
  }
}

///|
fn bridge_checkpoint_ack_decision(
  value : String,
) -> @audit_runtime.CheckpointAckDecision? {
  match value {
    "accepted" => Some(@audit_runtime.CheckpointAckDecision::CheckpointAccepted)
    "duplicate" =>
      Some(@audit_runtime.CheckpointAckDecision::CheckpointDuplicate)
    "gap" => Some(@audit_runtime.CheckpointAckDecision::CheckpointGap)
    "same_epoch_fork" =>
      Some(@audit_runtime.CheckpointAckDecision::CheckpointSameEpochFork)
    "parent_fork" =>
      Some(@audit_runtime.CheckpointAckDecision::CheckpointParentFork)
    "stale_unknown" =>
      Some(@audit_runtime.CheckpointAckDecision::CheckpointStaleUnknown)
    "boundary_mismatch" =>
      Some(@audit_runtime.CheckpointAckDecision::CheckpointBoundaryMismatch)
    "refused" => Some(@audit_runtime.CheckpointAckDecision::CheckpointRefused)
    _ => None
  }
}

///|
fn bridge_checkpoint_ack_open_refusal_code(
  reason : @audit_runtime.CheckpointAckRefusal,
) -> String {
  match reason {
    @audit_runtime.CheckpointAckRefusal::InvalidAckBoundary =>
      "invalid_ack_boundary"
    @audit_runtime.CheckpointAckRefusal::EmptyAckAuthorityId =>
      "empty_ack_authority"
    @audit_runtime.CheckpointAckRefusal::NegativeAckEpoch =>
      "negative_ack_epoch"
    @audit_runtime.CheckpointAckRefusal::EmptyAckDigest => "empty_ack_digest"
    @audit_runtime.CheckpointAckRefusal::AckAuthenticationFailed =>
      "ack_authentication_failed"
  }
}

///|
fn bridge_outbox_ack_refusal_code(
  reason : @audit_runtime.OutboxAckRefusal,
) -> String {
  match reason {
    @audit_runtime.OutboxAckRefusal::AckAuthorityMismatch =>
      "authority_mismatch"
    @audit_runtime.OutboxAckRefusal::AckBoundaryMismatch => "boundary_mismatch"
    @audit_runtime.OutboxAckRefusal::AckEpochMismatch => "epoch_mismatch"
    @audit_runtime.OutboxAckRefusal::AckDigestMismatch => "digest_mismatch"
    @audit_runtime.OutboxAckRefusal::AckDecisionNotSuccessful =>
      "decision_not_successful"
  }
}

///|
/// Enforce exact authority/boundary/epoch/digest binding and the successful
/// ACK decision set after the adapter authenticates its ACK channel.
pub fn audit_acknowledge_checkpoint_outbox(
  protocol_version : Int,
  purpose : String,
  manifest_digest : String,
  scope_id : String,
  unit_id : String,
  destination_id : String,
  epoch : Int,
  checkpoint_digest : String,
  canonical_envelope : String,
  created_order : Int,
  ack_protocol_version : Int,
  ack_purpose : String,
  ack_manifest_digest : String,
  ack_scope_id : String,
  ack_unit_id : String,
  ack_authority_id : String,
  ack_epoch : Int,
  ack_checkpoint_digest : String,
  ack_decision : String,
  authentication_succeeded : Bool,
) -> String {
  let boundary = bridge_boundary(
    protocol_version, purpose, manifest_digest, scope_id, unit_id,
  )
  let entry = match
    @audit_runtime.open_checkpoint_outbox_entry(
      boundary~,
      destination_id~,
      epoch~,
      checkpoint_digest=@commitment.AuditDigest(checkpoint_digest),
      canonical_envelope~,
      created_order~,
    ) {
    @audit_runtime.CheckpointOutboxOpenResult::OutboxEntryReady(value) => value
    @audit_runtime.CheckpointOutboxOpenResult::OutboxEntryRefused(_) =>
      return "refused_invalid_outbox_entry"
  }
  let decision = match bridge_checkpoint_ack_decision(ack_decision) {
    Some(value) => value
    None => return "refused_invalid_ack_decision"
  }
  let ack_boundary = bridge_boundary(
    ack_protocol_version, ack_purpose, ack_manifest_digest, ack_scope_id, ack_unit_id,
  )
  let evidence = @audit_runtime.CheckpointAckEvidence::{
    boundary: ack_boundary,
    authority_id: ack_authority_id,
    epoch: ack_epoch,
    checkpoint_digest: @commitment.AuditDigest(ack_checkpoint_digest),
    decision,
  }
  let ack = match
    @audit_runtime.open_authenticated_checkpoint_ack(
      evidence,
      authentication_succeeded~,
    ) {
    @audit_runtime.CheckpointAckOpenResult::CheckpointAckReady(value) => value
    @audit_runtime.CheckpointAckOpenResult::CheckpointAckRefused(reason) =>
      return "refused_" + bridge_checkpoint_ack_open_refusal_code(reason)
  }
  match @audit_runtime.acknowledge_checkpoint_outbox(entry, ack) {
    @audit_runtime.CheckpointOutboxAckResult::OutboxAcknowledged(_) =>
      "acknowledged"
    @audit_runtime.CheckpointOutboxAckResult::OutboxAlreadyAcknowledged =>
      "already_acknowledged"
    @audit_runtime.CheckpointOutboxAckResult::OutboxAckRefused(reason) =>
      "refused_" + bridge_outbox_ack_refusal_code(reason)
  }
}
