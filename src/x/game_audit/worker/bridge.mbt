///|
fn worker_hex_nibble(code : UInt16) -> Int? {
  let value = code.to_int()
  if value >= '0'.to_int() && value <= '9'.to_int() {
    Some(value - '0'.to_int())
  } else if value >= 'a'.to_int() && value <= 'f'.to_int() {
    Some(value - 'a'.to_int() + 10)
  } else if value >= 'A'.to_int() && value <= 'F'.to_int() {
    Some(value - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
fn worker_bytes_from_hex(value : String) -> Bytes? {
  if value.length() % 2 != 0 {
    return None
  }
  let output = FixedArray::make(value.length() / 2, b'\x00')
  for index in 0..<output.length() {
    let high = match worker_hex_nibble(value[index * 2]) {
      Some(nibble) => nibble
      None => return None
    }
    let low = match worker_hex_nibble(value[index * 2 + 1]) {
      Some(nibble) => nibble
      None => return None
    }
    output[index] = ((high << 4) | low).to_byte()
  }
  Some(Bytes::from_array(output))
}

///|
fn worker_bytes_to_hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let output = StringBuilder::new()
  for byte in bytes {
    let value = byte.to_int()
    output.write_char(
      digits.code_unit_at((value >> 4) & 0x0F).to_int().unsafe_to_char(),
    )
    output.write_char(
      digits.code_unit_at(value & 0x0F).to_int().unsafe_to_char(),
    )
  }
  output.to_string()
}

///|
fn worker_error(code : String) -> String {
  Json::object({ "ok": Json::boolean(false), "error": Json::string(code) }).stringify()
}

///|
fn worker_checkpoint_delivery_statement(
  protocol_version : Int,
  purpose : String,
  manifest_digest : String,
  scope_id : String,
  unit_id : String,
  destination_id : String,
  epoch : Int,
  previous_checkpoint : String,
  checkpoint_digest : String,
  canonical_envelope : String,
) -> @checkpoint_delivery.CheckpointDeliveryStatement {
  {
    boundary: {
      protocol_version,
      purpose,
      manifest_digest: @commitment.AuditDigest(manifest_digest),
      scope_id,
      unit_id,
    },
    destination_id,
    epoch,
    previous_checkpoint: @bft.Digest(previous_checkpoint),
    checkpoint_digest: @bft.Digest(checkpoint_digest),
    canonical_envelope,
  }
}

///|
fn worker_checkpoint_delivery_refusal_code(
  refusal : @checkpoint_delivery.DeliveryAuthenticationRefusal,
) -> String {
  match refusal {
    DeliveryInvalidStatement => "invalid_statement"
    DeliveryInvalidPolicy => "invalid_policy"
    DeliveryProducerIdentityMismatch => "producer_identity_mismatch"
    DeliveryStatementDigestMismatch => "statement_digest_mismatch"
    DeliveryInvalidProducerSignature => "invalid_producer_signature"
    DeliveryApprovalStatementMismatch => "approval_statement_mismatch"
    DeliveryUnknownWitness => "unknown_witness"
    DeliveryWitnessKeyMismatch => "witness_key_mismatch"
    DeliveryApprovalDigestMismatch => "approval_digest_mismatch"
    DeliveryInvalidWitnessSignature => "invalid_witness_signature"
    DeliveryDuplicateWitness => "duplicate_witness"
    DeliveryUnderQuorum(_, _) => "under_quorum"
  }
}

///|
/// Sign one checkpoint approval in a witness-owned client process.
///
/// This deliberately accepts an experimental private seed because it is a
/// client bridge for the unaudited crypto backend. Never expose it from an
/// authority Worker route or transmit the seed to a server.
pub fn audit_experimental_sign_checkpoint_delivery_approval(
  witness_seed_hex : String,
  witness_id : String,
  statement_digest : String,
) -> String {
  if witness_id == "" {
    return worker_error("invalid_witness_id")
  }
  if statement_digest == "" {
    return worker_error("invalid_statement_digest")
  }
  let witness_seed = match worker_bytes_from_hex(witness_seed_hex) {
    Some(value) => value
    None => return worker_error("invalid_witness_seed_hex")
  }
  let witness = @crypto.ExperimentalEd25519Signer::new(witness_seed) catch {
    _ => return worker_error("invalid_witness_seed")
  }
  let approval = @checkpoint_delivery.sign_checkpoint_delivery_approval(
    @crypto.ExperimentalSha256Hasher::new(),
    witness,
    witness_id,
    @bft.Digest(statement_digest),
  )
  Json::object({
    "ok": Json::boolean(true),
    "approval": Json::object({
      "statement_digest": Json::string(approval.statement_digest.0),
      "witness_id": Json::string(approval.witness_id),
      "witness_key": Json::string(approval.witness_key.0),
      "digest": Json::string(approval.digest.0),
      "signature": Json::string(approval.signature.0),
    }),
  }).stringify()
}

///|
/// Deterministic real-crypto fixture for integration tests and benchmarks.
/// Private seeds must never cross a production route.
pub fn audit_benchmark_make_checkpoint_delivery_authentication(
  producer_seed_hex : String,
  producer_id : String,
  witness_seed_hexes : Array[String],
  witness_ids : Array[String],
  required_approvals : Int,
  approval_count : Int,
  protocol_version : Int,
  purpose : String,
  manifest_digest : String,
  scope_id : String,
  unit_id : String,
  destination_id : String,
  epoch : Int,
  previous_checkpoint : String,
  checkpoint_digest : String,
  canonical_envelope : String,
) -> String {
  if witness_seed_hexes.length() != witness_ids.length() ||
    witness_ids.length() == 0 ||
    required_approvals <= 0 ||
    required_approvals > witness_ids.length() ||
    approval_count < 0 ||
    approval_count > witness_ids.length() {
    return worker_error("invalid_delivery_fixture_policy")
  }
  let producer_seed = match worker_bytes_from_hex(producer_seed_hex) {
    Some(value) => value
    None => return worker_error("invalid_producer_seed_hex")
  }
  let producer = @crypto.ExperimentalEd25519Signer::new(producer_seed) catch {
    _ => return worker_error("invalid_producer_seed")
  }
  let witness_signers : Array[@crypto.ExperimentalEd25519Signer] = []
  let witnesses : Array[@checkpoint_delivery.DeliveryWitness] = []
  for index in 0..<witness_ids.length() {
    let seed = match worker_bytes_from_hex(witness_seed_hexes[index]) {
      Some(value) => value
      None => return worker_error("invalid_witness_seed_hex")
    }
    let signer = @crypto.ExperimentalEd25519Signer::new(seed) catch {
      _ => return worker_error("invalid_witness_seed")
    }
    witness_signers.push(signer)
    witnesses.push({
      witness_id: witness_ids[index],
      witness_key: signer.public_key(),
    })
  }
  let policy = @checkpoint_delivery.DeliveryAuthenticationPolicy::{
    producer_id,
    producer_key: producer.public_key(),
    witnesses,
    required_approvals,
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let statement = worker_checkpoint_delivery_statement(
    protocol_version, purpose, manifest_digest, scope_id, unit_id, destination_id,
    epoch, previous_checkpoint, checkpoint_digest, canonical_envelope,
  )
  let signed = @checkpoint_delivery.sign_checkpoint_delivery(
    hasher, producer, producer_id, statement,
  )
  let approvals : Array[@checkpoint_delivery.SignedCheckpointDeliveryApproval] = []
  for index in 0..<approval_count {
    approvals.push(
      @checkpoint_delivery.sign_checkpoint_delivery_approval(
        hasher,
        witness_signers[index],
        witness_ids[index],
        signed.digest,
      ),
    )
  }
  Json::object({
    "ok": Json::boolean(true),
    "policy": Json::object({
      "producer_id": Json::string(policy.producer_id),
      "producer_key": Json::string(policy.producer_key.0),
      "witnesses": Json::array(
        policy.witnesses.map(fn(witness) {
          Json::object({
            "witness_id": Json::string(witness.witness_id),
            "witness_key": Json::string(witness.witness_key.0),
          })
        }),
      ),
      "required_approvals": Json::number(required_approvals.to_double()),
    }),
    "authentication": Json::object({
      "version": Json::number(1.0),
      "producer_id": Json::string(signed.producer_id),
      "producer_key": Json::string(signed.producer_key.0),
      "statement_digest": Json::string(signed.digest.0),
      "producer_signature": Json::string(signed.signature.0),
      "approvals": Json::array(
        approvals.map(fn(approval) {
          Json::object({
            "statement_digest": Json::string(approval.statement_digest.0),
            "witness_id": Json::string(approval.witness_id),
            "witness_key": Json::string(approval.witness_key.0),
            "digest": Json::string(approval.digest.0),
            "signature": Json::string(approval.signature.0),
          })
        }),
      ),
    }),
  }).stringify()
}

///|
/// Verify the exact checkpoint statement against a provisioned producer and
/// witness roster. Only an opaque authenticated capability reaches success.
pub fn audit_verify_checkpoint_delivery_authentication(
  protocol_version : Int,
  purpose : String,
  manifest_digest : String,
  scope_id : String,
  unit_id : String,
  destination_id : String,
  epoch : Int,
  previous_checkpoint : String,
  checkpoint_digest : String,
  canonical_envelope : String,
  policy_producer_id : String,
  policy_producer_key : String,
  policy_witness_ids : Array[String],
  policy_witness_keys : Array[String],
  required_approvals : Int,
  producer_id : String,
  producer_key : String,
  statement_digest : String,
  producer_signature : String,
  approval_statement_digests : Array[String],
  approval_witness_ids : Array[String],
  approval_witness_keys : Array[String],
  approval_digests : Array[String],
  approval_signatures : Array[String],
) -> String {
  if policy_witness_ids.length() != policy_witness_keys.length() ||
    approval_statement_digests.length() != approval_witness_ids.length() ||
    approval_witness_ids.length() != approval_witness_keys.length() ||
    approval_witness_keys.length() != approval_digests.length() ||
    approval_digests.length() != approval_signatures.length() {
    return worker_error("invalid_delivery_authentication_shape")
  }
  let witnesses : Array[@checkpoint_delivery.DeliveryWitness] = []
  for index in 0..<policy_witness_ids.length() {
    witnesses.push({
      witness_id: policy_witness_ids[index],
      witness_key: @bft.PublicKey(policy_witness_keys[index]),
    })
  }
  let approvals : Array[@checkpoint_delivery.SignedCheckpointDeliveryApproval] = []
  for index in 0..<approval_witness_ids.length() {
    approvals.push({
      statement_digest: @bft.Digest(approval_statement_digests[index]),
      witness_id: approval_witness_ids[index],
      witness_key: @bft.PublicKey(approval_witness_keys[index]),
      digest: @bft.Digest(approval_digests[index]),
      signature: @bft.Signature(approval_signatures[index]),
    })
  }
  let statement = worker_checkpoint_delivery_statement(
    protocol_version, purpose, manifest_digest, scope_id, unit_id, destination_id,
    epoch, previous_checkpoint, checkpoint_digest, canonical_envelope,
  )
  let signed = @checkpoint_delivery.SignedCheckpointDelivery::{
    statement,
    digest: @bft.Digest(statement_digest),
    signature: @bft.Signature(producer_signature),
    producer_id,
    producer_key: @bft.PublicKey(producer_key),
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  match
    @checkpoint_delivery.open_authenticated_checkpoint_delivery(
      hasher,
      verifier,
      {
        producer_id: policy_producer_id,
        producer_key: @bft.PublicKey(policy_producer_key),
        witnesses,
        required_approvals,
      },
      signed,
      approvals,
    ) {
    DeliveryAuthenticated(capability) =>
      Json::object({
        "ok": Json::boolean(true),
        "producer_id": Json::string(capability.producer_id()),
        "approval_count": Json::number(capability.approval_count().to_double()),
      }).stringify()
    DeliveryAuthenticationRefused(refusal) =>
      worker_error(worker_checkpoint_delivery_refusal_code(refusal))
  }
}

///|
fn worker_verified_anchor_json(
  published : @open_world.PublishedOpenWorldObserverSigningAnchor,
  envelope_bytes : Int,
) -> String {
  let anchor = published.anchor()
  Json::object({
    "ok": Json::boolean(true),
    "session_id": Json::string(published.log_session_id()),
    "publisher_key": Json::string(published.publisher_key().0),
    "epoch": Json::number(published.log_epoch().to_double()),
    "digest": Json::string(published.publication_checkpoint_digest().0),
    "previous_digest": Json::string(published.previous_checkpoint_digest().0),
    "observer_id": Json::string(anchor.observer_id),
    "anchor_root": Json::string(anchor.root.0),
    "anchor_size": Json::number(anchor.size.to_double()),
    "envelope_bytes": Json::number(envelope_bytes.to_double()),
  }).stringify()
}

///|
/// Generate deterministic real-crypto traffic for infrastructure benchmarks.
/// This helper embeds a private seed and must not be exposed by production
/// routing.
pub fn audit_benchmark_make_anchor_envelope(
  authority_seed_hex : String,
  log_session_id : String,
  observer_id : String,
  epoch : Int,
  previous_digest : String,
) -> String {
  let seed = match worker_bytes_from_hex(authority_seed_hex) {
    Some(seed) => seed
    None => return worker_error("invalid_seed_hex")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let signer = @crypto.ExperimentalEd25519Signer::new(seed) catch {
    _ => return worker_error("invalid_seed")
  }
  let anchor = @open_world.OpenWorldObserverSigningAnchor::{
    observer_id,
    signer_key: @bft.PublicKey(
      hasher.hash_string("observer-key:" + observer_id).0,
    ),
    root: hasher.hash_string(
      "observer-root:" + observer_id + ":" + epoch.to_string(),
    ),
    size: epoch + 1,
  }
  let anchor_map = @authmap.AuthenticatedMap::new(hasher)
  let key = @open_world.open_world_observer_signing_anchor_key(anchor)
  ignore(
    anchor_map.put(
      key,
      @open_world.open_world_observer_signing_anchor_value(anchor),
    ),
  )
  let signed_checkpoint = @checkpoint.sign_checkpoint(hasher, signer, {
    session_id: log_session_id,
    epoch,
    previous_checkpoint: @bft.Digest(previous_digest),
    manifest_digest: @open_world.open_world_observer_signing_anchor_log_manifest(
      hasher,
      log_session_id~,
    ),
    event_root: hasher.hash_string("events:" + epoch.to_string()),
    public_state_root: anchor_map.root(),
    asset_delta_root: hasher.hash_string("assets:" + epoch.to_string()),
    hidden_state_commitment: None,
  })
  let membership_proof = match anchor_map.proof(key) {
    Some(proof) => proof
    None => return worker_error("missing_membership_proof")
  }
  let envelope = @open_world.OpenWorldObserverSigningAnchorEnvelope::{
    signed_checkpoint,
    anchor,
    membership_proof,
  }
  let encoded = @wire.encode_open_world_observer_signing_anchor_envelope(
    envelope,
  )
  Json::object({
    "ok": Json::boolean(true),
    "envelope_hex": Json::string(worker_bytes_to_hex(encoded)),
    "authority_key": Json::string(signer.public_key().0),
    "session_id": Json::string(log_session_id),
    "epoch": Json::number(epoch.to_double()),
    "digest": Json::string(signed_checkpoint.digest.0),
    "previous_digest": Json::string(previous_digest),
    "envelope_bytes": Json::number(encoded.length().to_double()),
  }).stringify()
}

///|
/// Decode, authenticate, and open one wire envelope. Success returns only
/// metadata derived from the opaque published-anchor capability.
pub fn audit_verify_anchor_envelope(
  envelope_hex : String,
  expected_authority_key : String,
  expected_log_session_id : String,
) -> String {
  let input = match worker_bytes_from_hex(envelope_hex) {
    Some(input) => input
    None => return worker_error("invalid_envelope_hex")
  }
  let envelope = match
    @wire.decode_open_world_observer_signing_anchor_envelope(
      input,
      limits=@wire.OpenWorldAuditWireLimits::default(),
    ) {
    Ok(envelope) => envelope
    Err(_) => return worker_error("wire_refused")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  match
    @open_world.open_open_world_observer_signing_anchor_envelope(
      hasher,
      verifier,
      @bft.PublicKey(expected_authority_key),
      log_session_id=expected_log_session_id,
      envelope,
    ) {
    ObserverSigningAnchorEnvelopeOpened(published) =>
      worker_verified_anchor_json(published, input.length())
    ObserverSigningAnchorEnvelopeRefused(_) =>
      worker_error("capability_refused")
  }
}

///|
/// Stable string bridge to the MoonBit-proved head transition classifier.
pub fn audit_classify_anchor_head(
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
/// generic runtime's opaque `TrustedEpochClosure` capability.
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
  let boundary = @audit_runtime.AuditBoundary::{
    protocol_version,
    purpose,
    manifest_digest: @commitment.AuditDigest(manifest_digest),
    scope_id,
    unit_id,
  }
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
fn worker_checkpoint_seal_conflict_code(
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
fn worker_checkpoint_seal_refusal_code(
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
/// Recreate a previously admitted closure capability, then expose only the
/// getters of a successfully prepared opaque write set as JSON for a storage
/// adapter. The adapter still owns transaction/CAS and durable mutation.
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
  let boundary = @audit_runtime.AuditBoundary::{
    protocol_version,
    purpose,
    manifest_digest: @commitment.AuditDigest(manifest_digest),
    scope_id,
    unit_id,
  }
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
        "reason": Json::string(worker_checkpoint_seal_conflict_code(reason)),
      }).stringify()
    @audit_runtime.AtomicCheckpointSealResult::CheckpointSealRefused(reason) =>
      Json::object({
        "decision": Json::string("refused"),
        "reason": Json::string(worker_checkpoint_seal_refusal_code(reason)),
      }).stringify()
  }
}

///|
fn worker_peer_route_json(route : @audit_runtime.PeerRouteState) -> Json {
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
fn worker_peer_route(
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
      worker_peer_route(
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
      worker_peer_route(
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
        "route": worker_peer_route_json(route),
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
      worker_peer_route(
        peer_id, available, quarantined, failures, next_retry_at_ms, last_attempt_order,
      ),
      attempt_order~,
    ) {
    @audit_runtime.PeerRouteUpdateResult::PeerRouteUpdated(route) =>
      Json::object({
        "decision": Json::string("updated"),
        "route": worker_peer_route_json(route),
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
fn worker_checkpoint_ack_decision(
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
fn worker_checkpoint_ack_open_refusal_code(
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
fn worker_outbox_ack_refusal_code(
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
/// Stable primitive-only bridge used by the Worker transaction adapter. The
/// adapter authenticates its internal ACK channel, while this function enforces
/// exact authority/boundary/epoch/digest binding and the success-decision set.
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
  let boundary = @audit_runtime.AuditBoundary::{
    protocol_version,
    purpose,
    manifest_digest: @commitment.AuditDigest(manifest_digest),
    scope_id,
    unit_id,
  }
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
  let decision = match worker_checkpoint_ack_decision(ack_decision) {
    Some(value) => value
    None => return "refused_invalid_ack_decision"
  }
  let ack_boundary = @audit_runtime.AuditBoundary::{
    protocol_version: ack_protocol_version,
    purpose: ack_purpose,
    manifest_digest: @commitment.AuditDigest(ack_manifest_digest),
    scope_id: ack_scope_id,
    unit_id: ack_unit_id,
  }
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
      return "refused_" + worker_checkpoint_ack_open_refusal_code(reason)
  }
  match @audit_runtime.acknowledge_checkpoint_outbox(entry, ack) {
    @audit_runtime.CheckpointOutboxAckResult::OutboxAcknowledged(_) =>
      "acknowledged"
    @audit_runtime.CheckpointOutboxAckResult::OutboxAlreadyAcknowledged =>
      "already_acknowledged"
    @audit_runtime.CheckpointOutboxAckResult::OutboxAckRefused(reason) =>
      "refused_" + worker_outbox_ack_refusal_code(reason)
  }
}

///|
/// Stable string bridge to the proved central replay artifact classifier.
pub fn audit_classify_central_replay(
  anchor_matches_job : Bool,
  transcript_present : Bool,
  checkpoint_link_valid : Bool,
  kernel_replay_complete : Bool,
  kernel_replay_matches : Bool,
) -> String {
  match
    @audit.classify_central_replay_artifacts(
      anchor_matches_job~,
      transcript_present~,
      checkpoint_link_valid~,
      kernel_replay_complete~,
      kernel_replay_matches~,
    ) {
    RejectReplayBoundary => "boundary_rejected"
    AwaitReplayTranscript => "awaiting_transcript"
    RejectReplayCheckpointLink => "checkpoint_link_rejected"
    RejectReplayIncomplete => "replay_incomplete"
    RejectReplayMismatch => "replay_mismatch"
    VerifyCentralReplay => "verified"
  }
}

///|
/// Stable bridge to the proved Worker marketplace persistence gate.
pub fn audit_marketplace_creation_persist_allowed(
  open_world_boundary : Bool,
  central_replay_verified : Bool,
  summary_normalized : Bool,
  checkpoint_bound : Bool,
  conflict_free : Bool,
) -> Bool {
  @audit.marketplace_creation_persist_allowed(
    open_world_boundary~,
    central_replay_verified~,
    summary_normalized~,
    checkpoint_bound~,
    conflict_free~,
  )
}

///|
pub fn audit_inventory_head_advance_allowed(
  creation_eligible : Bool,
  proof_verified : Bool,
  manifest_matches : Bool,
  parent_matches : Bool,
  epoch_advances : Bool,
  owner_version_consistent : Bool,
) -> Bool {
  @audit.inventory_head_advance_allowed(
    creation_eligible~,
    proof_verified~,
    manifest_matches~,
    parent_matches~,
    epoch_advances~,
    owner_version_consistent~,
  )
}

///|
fn worker_accept_pve_event(
  adapter : @bft.BFTAdapter,
  signed : @bft.SignedEvent,
) -> @bft.AuthenticatedEvent? {
  match adapter.deliver(signed) {
    Accepted(source) => Some(source)
    _ => None
  }
}

///|
/// Generate one small, valid, real-crypto PvE replay bundle for integration
/// tests and infrastructure benchmarks. Private seeds supplied here are test
/// inputs and this helper must not be exposed by production routing.
pub fn audit_benchmark_make_pve_replay_bundle(
  authority_seed_hex : String,
  player_seed_hex : String,
  session_id : String,
) -> String {
  let authority_seed = match worker_bytes_from_hex(authority_seed_hex) {
    Some(seed) => seed
    None => return worker_error("invalid_authority_seed_hex")
  }
  let player_seed = match worker_bytes_from_hex(player_seed_hex) {
    Some(seed) => seed
    None => return worker_error("invalid_player_seed_hex")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  let authority = @crypto.ExperimentalEd25519Signer::new(authority_seed) catch {
    _ => return worker_error("invalid_authority_seed")
  }
  let player = @crypto.ExperimentalEd25519Signer::new(player_seed) catch {
    _ => return worker_error("invalid_player_seed")
  }
  let authority_peer_id = "authority"
  let player_id = "alice"
  let adapter = @bft.BFTAdapter::new(hasher, verifier, session_id~)
  if !adapter.register_peer(
      @types.PeerId(authority_peer_id),
      authority.public_key(),
    ) ||
    !adapter.register_peer(@types.PeerId(player_id), player.public_key()) {
    return worker_error("fixture_roster_refused")
  }
  let config = @replay.DungeonEncounterConfig::{
    encounter_id: "benchmark-boss",
    player_max_hp: 10,
    attack_rules: {
      min_reaction_ticks: 2,
      max_backdate_ticks: 2,
      max_dodge_distance: 5,
      arena_min_x: -10,
      arena_max_x: 10,
      loot_item_type: "benchmark-boss-token",
    },
  }
  let players = [
    @replay.DungeonPlayer::{
      player_id,
      public_key: player.public_key(),
      initial_x: 0,
    },
  ]
  let attack = @replay.DungeonEncounterAttack::{
    attack: {
      attack_id: "benchmark-cleave",
      visible_tick: 10,
      resolve_tick: 16,
      center_x: 0,
      radius: 2,
    },
    damage: 6,
  }
  let telegraph_event = @replay.make_dungeon_telegraph_event(
    peer=@types.PeerId(authority_peer_id),
    counter=0,
    lamport=1,
    deps=[],
    attack=attack.attack,
  )
  let signed_telegraph = adapter.sign(authority, telegraph_event, [])
  let telegraph = match worker_accept_pve_event(adapter, signed_telegraph) {
    Some(source) => source
    None => return worker_error("fixture_telegraph_refused")
  }
  let intent = @replay.DodgeIntent::{
    attack_id: attack.attack.attack_id,
    player_id,
    telegraph_digest: telegraph.digest(),
    client_tick: 13,
    to_x: 5,
  }
  let input_event = @replay.make_dungeon_dodge_event(
    peer=@types.PeerId(player_id),
    counter=0,
    lamport=2,
    deps=[telegraph_event.id],
    intent~,
  )
  let signed_input = adapter.sign(player, input_event, [telegraph.digest()])
  let input = match worker_accept_pve_event(adapter, signed_input) {
    Some(source) => source
    None => return worker_error("fixture_input_refused")
  }
  let observed = @replay.DodgeReceipt::{
    input_digest: input.digest(),
    received_tick: 14,
  }
  let receipt_event = @replay.make_dungeon_receipt_event(
    peer=@types.PeerId(authority_peer_id),
    counter=1,
    lamport=3,
    deps=[input_event.id],
    receipt=observed,
  )
  let signed_receipt = adapter.sign(authority, receipt_event, [input.digest()])
  let receipt = match worker_accept_pve_event(adapter, signed_receipt) {
    Some(source) => source
    None => return worker_error("fixture_receipt_refused")
  }
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
    _ => return worker_error("fixture_replay_refused")
  }
  let loot_effect = @replay.AssetEffect::Create(
    asset_id=@replay.dungeon_encounter_loot_asset_id(
      session_id,
      config.encounter_id,
      player_id,
    ),
    recipient_id=player_id,
    item_type=config.attack_rules.loot_item_type,
    quantity=1,
    output_index=0,
  )
  let loot_event = @replay.make_asset_effect_event(
    peer=@types.PeerId(authority_peer_id),
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
          player_id,
        ),
        recipient_id: player_id,
        item_type: config.attack_rules.loot_item_type,
        quantity: 1,
        source_event: signed_loot.digest,
        output_index: 0,
      },
    ]) {
    Built(value) => value
    _ => return worker_error("fixture_asset_batch_refused")
  }
  let signed_checkpoint = @checkpoint.sign_checkpoint(hasher, authority, {
    session_id,
    epoch: 1,
    previous_checkpoint: hasher.hash_string("benchmark-game-genesis"),
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: candidate.public_state_root(),
    asset_delta_root: loot_batch.root(),
    hidden_state_commitment: None,
  })
  let encoded = @wire.encode_pve_replay_bundle({
    authority_peer_id,
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
  })
  Json::object({
    "ok": Json::boolean(true),
    "bundle_hex": Json::string(worker_bytes_to_hex(encoded)),
    "bundle_bytes": Json::number(encoded.length().to_double()),
    "session_id": Json::string(session_id),
    "authority_key": Json::string(authority.public_key().0),
    "checkpoint_digest": Json::string(signed_checkpoint.digest.0),
  }).stringify()
}

///|
fn worker_pve_refusal_code(
  reason : @central_replay.PveCentralReplayRefusal,
) -> String {
  match reason {
    WireReplayRefused(_) => "wire_refused"
    ExpectedSessionMismatch => "expected_session_mismatch"
    ExpectedAuthorityMismatch => "expected_authority_mismatch"
    ExpectedCheckpointMismatch => "expected_checkpoint_mismatch"
    InvalidAuthorityPeer => "invalid_authority_peer"
    InvalidRosterBoundary => "invalid_roster_boundary"
    DuplicateEventDigest(_) => "duplicate_event_digest"
    EventAuthenticationRefused(_) => "event_authentication_refused"
    IncompleteEventGraph => "incomplete_event_graph"
    CheckpointAuthenticationRefused(_) => "checkpoint_authentication_refused"
    EncounterReplayRefused(MissingAttackTranscript(_)) =>
      "missing_attack_transcript"
    EncounterReplayRefused(_) => "encounter_replay_refused"
    AssetEffectReplayRefused(_, _) => "asset_effect_replay_refused"
    AssetReceiptBatchRefused(_) => "asset_receipt_batch_refused"
    AssetDeltaRootMismatch => "asset_delta_root_mismatch"
  }
}

///|
fn worker_pve_refusal_complete(
  reason : @central_replay.PveCentralReplayRefusal,
) -> Bool {
  match reason {
    WireReplayRefused(_)
    | IncompleteEventGraph
    | EncounterReplayRefused(MissingAttackTranscript(_)) => false
    _ => true
  }
}

///|
/// Production bridge: strict Ed25519/SHA-256 verification followed by the
/// deterministic PvE kernel and checkpoint-root comparison.
pub fn audit_verify_pve_replay_bundle(
  bundle_hex : String,
  expected_session_id : String,
  expected_authority_key : String,
  expected_checkpoint_digest : String,
) -> String {
  let input = match worker_bytes_from_hex(bundle_hex) {
    Some(input) => input
    None => return worker_error("invalid_bundle_hex")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  match
    @central_replay.verify_pve_replay_bundle(
      hasher,
      verifier,
      input,
      expected_session_id~,
      expected_authority_key=@bft.PublicKey(expected_authority_key),
      expected_checkpoint_digest=@bft.Digest(expected_checkpoint_digest),
      limits=@wire.PveReplayWireLimits::default(),
    ) {
    ReplayVerified(verified) => {
      let survivors = Json::array(
        verified.survivor_ids().map(fn(id) { Json::string(id) }),
      )
      let defeated = Json::array(
        verified.defeated_ids().map(fn(id) { Json::string(id) }),
      )
      Json::object({
        "ok": Json::boolean(true),
        "complete": Json::boolean(true),
        "session_id": Json::string(verified.session_id()),
        "authority_key": Json::string(verified.authority_key().0),
        "checkpoint_digest": Json::string(verified.checkpoint_digest().0),
        "epoch": Json::number(verified.epoch().to_double()),
        "cleared": Json::boolean(verified.cleared()),
        "accepted_dodges": Json::number(
          verified.accepted_dodge_count().to_double(),
        ),
        "survivors": survivors,
        "defeated": defeated,
        "replayed_assets": Json::number(
          verified.replayed_asset_count().to_double(),
        ),
        "bundle_bytes": Json::number(input.length().to_double()),
      }).stringify()
    }
    ReplayRefused(reason) =>
      Json::object({
        "ok": Json::boolean(false),
        "complete": Json::boolean(worker_pve_refusal_complete(reason)),
        "error": Json::string(worker_pve_refusal_code(reason)),
      }).stringify()
  }
}

///|
fn worker_derived_ed25519_signer(
  hasher : &@bft.Hasher,
  master_seed_hex : String,
  label : String,
) -> @crypto.ExperimentalEd25519Signer? {
  let digest = hasher.hash_string(
    "converge-pvp-fixture-seed-v1:" + master_seed_hex + ":" + label,
  )
  let seed = match worker_bytes_from_hex(digest.0) {
    Some(value) => value
    None => return None
  }
  Some(@crypto.ExperimentalEd25519Signer::new(seed)) catch {
    _ => None
  }
}

///|
/// Generate a small real-crypto PvP bundle containing one player command, one
/// referee receipt/checkpoint, and three approvals from a four-witness roster.
/// This benchmark helper embeds test seed material and must not be routed in
/// production.
pub fn audit_benchmark_make_pvp_replay_bundle(
  referee_seed_hex : String,
  participant_seed_hex : String,
  session_id : String,
) -> String {
  let referee_seed = match worker_bytes_from_hex(referee_seed_hex) {
    Some(value) => value
    None => return worker_error("invalid_referee_seed_hex")
  }
  let participant_seed = match worker_bytes_from_hex(participant_seed_hex) {
    Some(value) => value
    None => return worker_error("invalid_participant_seed_hex")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  let referee = @crypto.ExperimentalEd25519Signer::new(referee_seed) catch {
    _ => return worker_error("invalid_referee_seed")
  }
  let alice = @crypto.ExperimentalEd25519Signer::new(participant_seed) catch {
    _ => return worker_error("invalid_participant_seed")
  }
  let bob = match
    worker_derived_ed25519_signer(hasher, participant_seed_hex, "bob") {
    Some(value) => value
    None => return worker_error("fixture_bob_key_failed")
  }
  let referee_peer_id = "referee"
  let adapter = @bft.BFTAdapter::new(hasher, verifier, session_id~)
  if !adapter.register_peer(
      @types.PeerId(referee_peer_id),
      referee.public_key(),
    ) ||
    !adapter.register_peer(@types.PeerId("alice"), alice.public_key()) ||
    !adapter.register_peer(@types.PeerId("bob"), bob.public_key()) {
    return worker_error("fixture_pvp_roster_refused")
  }
  let config = @replay.PvpEpochConfig::{
    match_id: "benchmark-pvp-match",
    epoch: 1,
    previous_checkpoint: hasher.hash_string("benchmark-pvp-genesis"),
    player_max_hp: 10,
    ticks_per_epoch: 4,
    max_late_ticks: 2,
    max_move_distance: 3,
    arena_min_x: -10,
    arena_max_x: 10,
    attack_range: 3,
    attack_damage: 10,
    score_per_elimination: 1,
  }
  let teams : Array[@replay.PvpTeam] = [
    { team_id: "blue", initial_score: 0 },
    { team_id: "orange", initial_score: 0 },
  ]
  let players : Array[@replay.PvpPlayer] = [
    {
      player_id: "alice",
      public_key: alice.public_key(),
      team_id: "blue",
      initial_x: 0,
      initial_hp: 10,
    },
    {
      player_id: "bob",
      public_key: bob.public_key(),
      team_id: "orange",
      initial_x: 2,
      initial_hp: 10,
    },
  ]
  let intent = @replay.PvpCommandIntent::{
    match_id: config.match_id,
    epoch: config.epoch,
    base_checkpoint_digest: config.previous_checkpoint,
    tick: 0,
    player_id: "alice",
    move_to_x: 0,
    attack_target_id: Some("bob"),
  }
  let input_event = @replay.make_pvp_command_event(
    peer=@types.PeerId("alice"),
    counter=0,
    lamport=0,
    deps=[],
    intent~,
  )
  let signed_input = adapter.sign(alice, input_event, [])
  let input = match worker_accept_pve_event(adapter, signed_input) {
    Some(value) => value
    None => return worker_error("fixture_pvp_input_refused")
  }
  let observed = @replay.PvpCommandReceipt::{
    command_digest: input.digest(),
    received_tick: 1,
  }
  let receipt_event = @replay.make_pvp_command_receipt_event(
    peer=@types.PeerId(referee_peer_id),
    counter=0,
    lamport=1,
    deps=[input_event.id],
    receipt=observed,
  )
  let signed_receipt = adapter.sign(referee, receipt_event, [input.digest()])
  let receipt = match worker_accept_pve_event(adapter, signed_receipt) {
    Some(value) => value
    None => return worker_error("fixture_pvp_receipt_refused")
  }
  let witness_signers : Array[@crypto.ExperimentalEd25519Signer] = []
  let witnesses : Array[@witness_manifest.ReplayWitnessIdentity] = []
  for index in 0..<4 {
    let id = "witness-" + index.to_string()
    let signer = match
      worker_derived_ed25519_signer(hasher, participant_seed_hex, id) {
      Some(value) => value
      None => return worker_error("fixture_witness_key_failed")
    }
    witness_signers.push(signer)
    witnesses.push({ id, key: signer.public_key() })
  }
  let command = @replay.PvpCommandEvidence::{ input, receipt, intent, observed }
  let candidate = match
    @replay.prepare_pvp_epoch(
      hasher,
      session_id~,
      referee_key=referee.public_key(),
      config~,
      teams~,
      players~,
      transcript=[command],
      witnesses~,
      max_faults=1,
    ) {
    PvpCandidateReady(value) => value
    PvpCandidateRefused(_) => return worker_error("fixture_pvp_replay_refused")
  }
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id,
    epoch: config.epoch,
    previous_checkpoint: config.previous_checkpoint,
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: candidate.public_state_root(),
    asset_delta_root: candidate.asset_delta_root(),
    hidden_state_commitment: None,
  })
  let signed_checkpoint = @checkpoint.sign_prepared_checkpoint(
    referee, prepared,
  )
  let checkpoint = match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      referee.public_key(),
      signed_checkpoint,
    ) {
    Opened(value) => value
    Refused(_) => return worker_error("fixture_pvp_checkpoint_refused")
  }
  let resolution = match @replay.finalize_pvp_epoch(candidate, checkpoint) {
    PvpEpochFinalized(value) => value
    PvpFinalizeRefused(_) =>
      return worker_error("fixture_pvp_checkpoint_mismatch")
  }
  let attestations : Array[@attestation.SignedAttestation] = []
  for index in 0..<3 {
    match
      @pvp_session.sign_pvp_replay_witness(
        hasher,
        witness_signers[index],
        prepared,
        resolution,
        referee_key=referee.public_key(),
        witness_id=witnesses[index].id,
        choice=@attestation.AttestationChoice::Approve,
      ) {
      PvpReplayWitnessSigned(value) => attestations.push(value)
      _ => return worker_error("fixture_pvp_witness_signing_refused")
    }
  }
  let encoded = @wire.encode_pvp_replay_bundle({
    referee_peer_id,
    signed_checkpoint,
    config,
    teams,
    players,
    witnesses,
    max_faults: 1,
    commands: [
      { input: signed_input, receipt: signed_receipt, intent, observed },
    ],
    attestations,
  })
  Json::object({
    "ok": Json::boolean(true),
    "bundle_hex": Json::string(worker_bytes_to_hex(encoded)),
    "bundle_bytes": Json::number(encoded.length().to_double()),
    "session_id": Json::string(session_id),
    "referee_key": Json::string(referee.public_key().0),
    "checkpoint_digest": Json::string(signed_checkpoint.digest.0),
    "approval_count": Json::number(attestations.length().to_double()),
  }).stringify()
}

///|
fn worker_pvp_refusal_code(
  reason : @central_replay.PvpCentralReplayRefusal,
) -> String {
  match reason {
    PvpWireReplayRefused(_) => "wire_refused"
    PvpExpectedSessionMismatch => "expected_session_mismatch"
    PvpExpectedRefereeMismatch => "expected_referee_mismatch"
    PvpExpectedCheckpointMismatch => "expected_checkpoint_mismatch"
    PvpInvalidRefereePeer => "invalid_referee_peer"
    PvpInvalidRosterBoundary => "invalid_roster_boundary"
    PvpDuplicateEventDigest(_) => "duplicate_event_digest"
    PvpEventAuthenticationRefused(_) => "event_authentication_refused"
    PvpIncompleteEventGraph => "incomplete_event_graph"
    PvpCheckpointAuthenticationRefused(_) => "checkpoint_authentication_refused"
    PvpEpochReplayRefused(_) => "pvp_epoch_replay_refused"
    PvpWitnessSessionRefused(_) => "witness_session_refused"
    PvpWitnessEvidenceRefused(_) => "witness_evidence_refused"
    PvpWitnessCheckpointMismatch => "witness_checkpoint_mismatch"
    PvpWitnessRefereeMismatch => "witness_referee_mismatch"
    PvpWitnessQuorumPending(_, _) => "witness_quorum_pending"
  }
}

///|
fn worker_pvp_refusal_complete(
  reason : @central_replay.PvpCentralReplayRefusal,
) -> Bool {
  match reason {
    PvpWireReplayRefused(_)
    | PvpIncompleteEventGraph
    | PvpEpochReplayRefused(CheckpointEventRootMismatch)
    | PvpWitnessQuorumPending(_, _) => false
    _ => true
  }
}

///|
/// Production bridge: strict Ed25519/SHA-256 verification, deterministic PvP
/// replay, exact checkpoint matching, and replay-witness certification.
pub fn audit_verify_pvp_replay_bundle(
  bundle_hex : String,
  expected_session_id : String,
  expected_referee_key : String,
  expected_checkpoint_digest : String,
) -> String {
  let input = match worker_bytes_from_hex(bundle_hex) {
    Some(value) => value
    None => return worker_error("invalid_bundle_hex")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  match
    @central_replay.verify_pvp_replay_bundle(
      hasher,
      verifier,
      input,
      expected_session_id~,
      expected_referee_key=@bft.PublicKey(expected_referee_key),
      expected_checkpoint_digest=@bft.Digest(expected_checkpoint_digest),
      limits=@wire.PvpReplayWireLimits::default(),
    ) {
    PvpReplayVerified(verified) => {
      let equivocators = Json::array(
        verified.equivocator_ids().map(fn(id) { Json::string(id) }),
      )
      Json::object({
        "ok": Json::boolean(true),
        "complete": Json::boolean(true),
        "session_id": Json::string(verified.session_id()),
        "referee_key": Json::string(verified.referee_key().0),
        "checkpoint_digest": Json::string(verified.checkpoint_digest().0),
        "epoch": Json::number(verified.epoch().to_double()),
        "accepted_commands": Json::number(
          verified.accepted_command_count().to_double(),
        ),
        "approval_count": Json::number(verified.approval_count().to_double()),
        "required_approvals": Json::number(
          verified.required_approvals().to_double(),
        ),
        "equivocators": equivocators,
        "bundle_bytes": Json::number(input.length().to_double()),
      }).stringify()
    }
    PvpReplayRefused(reason) =>
      Json::object({
        "ok": Json::boolean(false),
        "complete": Json::boolean(worker_pvp_refusal_complete(reason)),
        "error": Json::string(worker_pvp_refusal_code(reason)),
      }).stringify()
  }
}

///|
/// Generate a real-crypto open-world sample with a delayed audit seed, a
/// closed one-leaf eligible set, three observations from a four-observer
/// roster, and a complete deterministic PvE encounter replay.
pub fn audit_benchmark_make_open_world_pve_replay_bundle(
  authority_seed_hex : String,
  participant_seed_hex : String,
  world_id : String,
  encounter_session_id : String,
) -> String {
  let authority_seed = match worker_bytes_from_hex(authority_seed_hex) {
    Some(value) => value
    None => return worker_error("invalid_authority_seed_hex")
  }
  let participant_seed = match worker_bytes_from_hex(participant_seed_hex) {
    Some(value) => value
    None => return worker_error("invalid_participant_seed_hex")
  }
  if world_id == "" || encounter_session_id == "" {
    return worker_error("invalid_open_world_session")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  let authority = @crypto.ExperimentalEd25519Signer::new(authority_seed) catch {
    _ => return worker_error("invalid_authority_seed")
  }
  let player = @crypto.ExperimentalEd25519Signer::new(participant_seed) catch {
    _ => return worker_error("invalid_participant_seed")
  }
  let transparency_publisher = match
    worker_derived_ed25519_signer(
      hasher, participant_seed_hex, "open-world-transparency-publisher",
    ) {
    Some(value) => value
    None => return worker_error("fixture_transparency_key_failed")
  }
  let transparency_log_session_id = world_id + ":audit-transparency"
  let observers : Array[@attestation.Participant] = []
  let observer_signers : Array[@crypto.ExperimentalEd25519Signer] = []
  for index in 0..<4 {
    let id = "open-world-observer-" + index.to_string()
    let signer = match
      worker_derived_ed25519_signer(hasher, participant_seed_hex, id) {
      Some(value) => value
      None => return worker_error("fixture_observer_key_failed")
    }
    observer_signers.push(signer)
    observers.push({ id, key: signer.public_key() })
  }
  let game_manifest_digest = hasher.hash_string("open-world-pve-game-v1")
  let observer_manifest_digest = @open_world.open_world_observer_manifest(
    hasher,
    observers~,
    max_faults=1,
  )
  let seed = "benchmark-delayed-open-world-seed"
  let signed_audit_checkpoint = @checkpoint.sign_checkpoint(hasher, authority, {
    session_id: world_id,
    epoch: 10,
    previous_checkpoint: hasher.hash_string("benchmark-world-epoch-9"),
    manifest_digest: @open_world.open_world_audit_manifest(
      hasher,
      game_manifest_digest~,
      observer_manifest_digest~,
      sample_numerator=1,
      sample_denominator=1,
    ),
    event_root: hasher.hash_string("benchmark-audit-start-events"),
    public_state_root: hasher.hash_string("benchmark-audit-start-state"),
    asset_delta_root: hasher.hash_string("benchmark-audit-start-assets"),
    hidden_state_commitment: Some(
      @open_world.open_world_audit_seed_commitment(
        hasher,
        world_id~,
        epoch=10,
        seed~,
      ),
    ),
  })
  let authority_peer_id = "authority"
  let player_id = "alice"
  let adapter = @bft.BFTAdapter::new(
    hasher,
    verifier,
    session_id=encounter_session_id,
  )
  if !adapter.register_peer(
      @types.PeerId(authority_peer_id),
      authority.public_key(),
    ) ||
    !adapter.register_peer(@types.PeerId(player_id), player.public_key()) {
    return worker_error("fixture_open_world_roster_refused")
  }
  let config = @replay.DungeonEncounterConfig::{
    encounter_id: "benchmark-open-world-encounter",
    player_max_hp: 2,
    attack_rules: {
      min_reaction_ticks: 2,
      max_backdate_ticks: 2,
      max_dodge_distance: 4,
      arena_min_x: -10,
      arena_max_x: 10,
      loot_item_type: "benchmark-open-world-token",
    },
  }
  let players = [
    @replay.DungeonPlayer::{
      player_id,
      public_key: player.public_key(),
      initial_x: 0,
    },
  ]
  let attack = @replay.DungeonEncounterAttack::{
    attack: {
      attack_id: "benchmark-open-world-cleave",
      visible_tick: 10,
      resolve_tick: 14,
      center_x: 0,
      radius: 1,
    },
    damage: 1,
  }
  let telegraph_event = @replay.make_dungeon_telegraph_event(
    peer=@types.PeerId(authority_peer_id),
    counter=0,
    lamport=1,
    deps=[],
    attack=attack.attack,
  )
  let signed_telegraph = adapter.sign(authority, telegraph_event, [])
  let telegraph = match worker_accept_pve_event(adapter, signed_telegraph) {
    Some(value) => value
    None => return worker_error("fixture_open_world_telegraph_refused")
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
    _ => return worker_error("fixture_open_world_replay_refused")
  }
  let loot_effect = @replay.AssetEffect::Create(
    asset_id=@replay.dungeon_encounter_loot_asset_id(
      encounter_session_id,
      config.encounter_id,
      player_id,
    ),
    recipient_id=player_id,
    item_type=config.attack_rules.loot_item_type,
    quantity=1,
    output_index=0,
  )
  let loot_event = @replay.make_asset_effect_event(
    peer=@types.PeerId(authority_peer_id),
    counter=1,
    lamport=2,
    deps=[telegraph_event.id],
    effect=loot_effect,
  )
  let signed_loot = adapter.sign(authority, loot_event, [telegraph.digest()])
  let loot_batch = match
    @market.build_receipt_batch(hasher, [
      {
        asset_id: @replay.dungeon_encounter_loot_asset_id(
          encounter_session_id,
          config.encounter_id,
          player_id,
        ),
        recipient_id: player_id,
        item_type: config.attack_rules.loot_item_type,
        quantity: 1,
        source_event: signed_loot.digest,
        output_index: 0,
      },
    ]) {
    Built(value) => value
    _ => return worker_error("fixture_open_world_asset_batch_refused")
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
    None => return worker_error("fixture_open_world_proof_missing")
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
      public_state_root: hasher.hash_string("benchmark-open-world-registry"),
      asset_delta_root: hasher.hash_string("benchmark-open-world-seal-assets"),
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
      previous_checkpoint: hasher.hash_string("benchmark-transparency-3"),
      manifest_digest: @open_world.open_world_audit_transparency_log_manifest(
        hasher,
        log_session_id=transparency_log_session_id,
      ),
      event_root: hasher.hash_string("benchmark-transparency-events"),
      public_state_root: transparency_map.root(),
      asset_delta_root: hasher.hash_string("benchmark-transparency-assets"),
      hidden_state_commitment: None,
    },
  )
  let audit_publication_proof = match
    transparency_map.proof(audit_publication_key) {
    Some(value) => value
    None => return worker_error("fixture_audit_publication_proof_missing")
  }
  let seal_publication_proof = match
    transparency_map.proof(seal_publication_key) {
    Some(value) => value
    None => return worker_error("fixture_seal_publication_proof_missing")
  }
  let observations : Array[@open_world.SignedOpenWorldRegistrationObservation] = []
  for index in 0..<3 {
    let ledger = match
      @open_world.OpenWorldObserverSigningLedger::new(
        hasher,
        observer_signers[index],
        observer_id=observers[index].id,
      ) {
      ObserverSigningLedgerReady(value) => value
      _ => return worker_error("fixture_observer_ledger_refused")
    }
    match
      ledger.sign_registration(
        audit_checkpoint_digest=signed_audit_checkpoint.digest,
        registration_index=0,
        encounter_digest=signed_encounter_checkpoint.digest,
      ) {
      ObserverObservationSigned(value) => observations.push(value)
      _ => return worker_error("fixture_observer_signing_refused")
    }
  }
  let encoded = @wire.encode_open_world_pve_replay_bundle({
    signed_audit_checkpoint,
    signed_anchor_seal_checkpoint,
    audit_transparency: {
      signed_checkpoint: signed_transparency_checkpoint,
      audit_membership_proof: audit_publication_proof,
      seal_membership_proof: seal_publication_proof,
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
      authority_peer_id,
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
  })
  Json::object({
    "ok": Json::boolean(true),
    "bundle_hex": Json::string(worker_bytes_to_hex(encoded)),
    "bundle_bytes": Json::number(encoded.length().to_double()),
    "world_id": Json::string(world_id),
    "encounter_session_id": Json::string(encounter_session_id),
    "authority_key": Json::string(authority.public_key().0),
    "transparency_log_session_id": Json::string(transparency_log_session_id),
    "transparency_publisher_key": Json::string(
      transparency_publisher.public_key().0,
    ),
    "transparency_checkpoint_digest": Json::string(
      signed_transparency_checkpoint.digest.0,
    ),
    "audit_checkpoint_digest": Json::string(signed_audit_checkpoint.digest.0),
    "seal_checkpoint_digest": Json::string(
      signed_anchor_seal_checkpoint.digest.0,
    ),
    "checkpoint_digest": Json::string(signed_encounter_checkpoint.digest.0),
    "asset_id": Json::string(
      @replay.dungeon_encounter_loot_asset_id(
        encounter_session_id,
        config.encounter_id,
        player_id,
      ),
    ),
    "item_type": Json::string(config.attack_rules.loot_item_type),
    "quantity": Json::number(1.0),
    "output_index": Json::number(0.0),
    "source_event": Json::string(signed_loot.digest.0),
    "observer_approvals": Json::number(observations.length().to_double()),
  }).stringify()
}

///|
fn worker_open_world_refusal_code(
  reason : @central_replay.OpenWorldPveCentralReplayRefusal,
) -> String {
  match reason {
    OpenWorldWireReplayRefused(_) => "wire_refused"
    OpenWorldExpectedWorldMismatch => "expected_world_mismatch"
    OpenWorldExpectedAuthorityMismatch => "expected_authority_mismatch"
    OpenWorldExpectedAuditCheckpointMismatch =>
      "expected_audit_checkpoint_mismatch"
    OpenWorldExpectedSealCheckpointMismatch =>
      "expected_seal_checkpoint_mismatch"
    OpenWorldExpectedEncounterCheckpointMismatch =>
      "expected_checkpoint_mismatch"
    OpenWorldAuditCheckpointAuthenticationRefused(_) =>
      "audit_checkpoint_authentication_refused"
    OpenWorldSealCheckpointAuthenticationRefused(_) =>
      "seal_checkpoint_authentication_refused"
    OpenWorldAuditTransparencyRefused(_) => "audit_transparency_refused"
    OpenWorldAuditEpochRefused(_) => "audit_epoch_refused"
    OpenWorldEncounterReplayRefused(_) => "encounter_replay_refused"
    OpenWorldObserverPolicyRefused => "observer_policy_refused"
    OpenWorldObserverEvidenceRefused(_) => "observer_evidence_refused"
    OpenWorldObserverQuorumPending(_, _) => "observer_quorum_pending"
    OpenWorldEncounterGateRefused(_) => "encounter_gate_refused"
    OpenWorldAssetListingGateRefused(_) => "asset_listing_gate_refused"
  }
}

///|
fn worker_open_world_refusal_complete(
  reason : @central_replay.OpenWorldPveCentralReplayRefusal,
) -> Bool {
  match reason {
    OpenWorldWireReplayRefused(_)
    | OpenWorldObserverQuorumPending(_, _)
    | OpenWorldEncounterReplayRefused(IncompleteEventGraph)
    | OpenWorldEncounterReplayRefused(
      EncounterReplayRefused(MissingAttackTranscript(_))
    ) => false
    _ => true
  }
}

///|
/// Production bridge for the complete open-world selective replay boundary.
pub fn audit_verify_open_world_pve_replay_bundle(
  bundle_hex : String,
  expected_world_id : String,
  expected_encounter_session_id : String,
  expected_authority_key : String,
  expected_transparency_log_session_id : String,
  expected_transparency_publisher_key : String,
  expected_transparency_checkpoint_digest : String,
  expected_audit_checkpoint_digest : String,
  expected_seal_checkpoint_digest : String,
  expected_encounter_checkpoint_digest : String,
) -> String {
  let input = match worker_bytes_from_hex(bundle_hex) {
    Some(value) => value
    None => return worker_error("invalid_bundle_hex")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  match
    @central_replay.verify_open_world_pve_replay_bundle(
      hasher,
      verifier,
      input,
      expected_world_id~,
      expected_encounter_session_id~,
      expected_authority_key=@bft.PublicKey(expected_authority_key),
      expected_transparency_log_session_id~,
      expected_transparency_publisher_key=@bft.PublicKey(
        expected_transparency_publisher_key,
      ),
      expected_transparency_checkpoint_digest=@bft.Digest(
        expected_transparency_checkpoint_digest,
      ),
      expected_audit_checkpoint_digest=@bft.Digest(
        expected_audit_checkpoint_digest,
      ),
      expected_seal_checkpoint_digest=@bft.Digest(
        expected_seal_checkpoint_digest,
      ),
      expected_encounter_checkpoint_digest=@bft.Digest(
        expected_encounter_checkpoint_digest,
      ),
      limits=@wire.OpenWorldPveReplayWireLimits::default(),
    ) {
    OpenWorldPveReplayVerified(verified) => {
      let item_creations = Json::array(
        verified
        .verified_item_creations()
        .map(fn(item) {
          Json::object({
            "asset_id": Json::string(item.asset_id),
            "initial_owner_id": Json::string(item.initial_owner_id),
            "item_type": Json::string(item.item_type),
            "quantity": Json::number(item.quantity.to_double()),
            "output_index": Json::number(item.output_index.to_double()),
            "source_event": Json::string(item.source_event.0),
            "checkpoint_digest": Json::string(item.checkpoint_digest.0),
            "inventory_session_id": Json::string(item.inventory_session_id),
            "checkpoint_epoch": Json::number(item.checkpoint_epoch.to_double()),
          })
        }),
      )
      Json::object({
        "ok": Json::boolean(true),
        "complete": Json::boolean(true),
        "world_id": Json::string(verified.world_id()),
        "encounter_session_id": Json::string(verified.encounter_session_id()),
        "authority_key": Json::string(verified.authority_key().0),
        "transparency_checkpoint_digest": Json::string(
          verified.transparency_checkpoint_digest().0,
        ),
        "audit_checkpoint_digest": Json::string(
          verified.audit_checkpoint_digest().0,
        ),
        "seal_checkpoint_digest": Json::string(
          verified.seal_checkpoint_digest().0,
        ),
        "checkpoint_digest": Json::string(
          verified.encounter_checkpoint_digest().0,
        ),
        "observer_approvals": Json::number(
          verified.observer_approval_count().to_double(),
        ),
        "required_observer_approvals": Json::number(
          verified.required_observer_approvals().to_double(),
        ),
        "cleared": Json::boolean(verified.cleared()),
        "accepted_dodges": Json::number(
          verified.accepted_dodge_count().to_double(),
        ),
        "survivors": Json::array(
          verified.survivor_ids().map(fn(id) { Json::string(id) }),
        ),
        "defeated": Json::array(
          verified.defeated_ids().map(fn(id) { Json::string(id) }),
        ),
        "verified_item_creations": item_creations,
        "bundle_bytes": Json::number(input.length().to_double()),
      }).stringify()
    }
    OpenWorldPveReplayRefused(reason) =>
      Json::object({
        "ok": Json::boolean(false),
        "complete": Json::boolean(worker_open_world_refusal_complete(reason)),
        "error": Json::string(worker_open_world_refusal_code(reason)),
      }).stringify()
  }
}

///|
/// Generate a compact real-crypto current-owner fixture. Production clients
/// construct the same bundle after locally replaying inventory transitions;
/// this deterministic helper exists for Worker integration benchmarks.
pub fn audit_benchmark_make_inventory_listing_proof_bundle(
  authority_seed_hex : String,
  participant_seed_hex : String,
  session_id : String,
  previous_checkpoint_digest : String,
  epoch : Int,
  asset_id : String,
  initial_owner_id : String,
  current_owner_id : String,
  item_type : String,
  quantity : Int,
  source_event_digest : String,
  output_index : Int,
  version : Int,
) -> String {
  let authority_seed = match worker_bytes_from_hex(authority_seed_hex) {
    Some(value) => value
    None => return worker_error("invalid_authority_seed_hex")
  }
  match worker_bytes_from_hex(participant_seed_hex) {
    Some(_) => ()
    None => return worker_error("invalid_participant_seed_hex")
  }
  if session_id == "" ||
    previous_checkpoint_digest == "" ||
    epoch < 0 ||
    asset_id == "" ||
    initial_owner_id == "" ||
    current_owner_id == "" ||
    item_type == "" ||
    quantity <= 0 ||
    source_event_digest == "" ||
    output_index < 0 ||
    version < 0 {
    return worker_error("invalid_inventory_fixture")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let authority = @crypto.ExperimentalEd25519Signer::new(authority_seed) catch {
    _ => return worker_error("invalid_authority_seed")
  }
  let origin = @market.ItemReceipt::{
    asset_id,
    recipient_id: initial_owner_id,
    item_type,
    quantity,
    source_event: @bft.Digest(source_event_digest),
    output_index,
  }
  let last_event = if version == 0 {
    origin.source_event
  } else {
    hasher.hash_string(
      "inventory-transfer-fixture-v1:" +
      asset_id +
      ":" +
      current_owner_id +
      ":" +
      version.to_string(),
    )
  }
  let record = @inventory.AssetRecord::{
    asset_id,
    owner_id: current_owner_id,
    item_type,
    quantity,
    origin_source_event: origin.source_event,
    origin_output_index: output_index,
    origin_receipt_digest: @inventory.inventory_origin_receipt_digest(
      hasher, origin,
    ),
    version,
    last_event,
  }
  let state = @authmap.AuthenticatedMap::new(hasher)
  ignore(state.put(asset_id, @inventory.serialize_asset_record(record)))
  let map_proof = match state.proof(asset_id) {
    Some(value) => value
    None => return worker_error("fixture_inventory_proof_missing")
  }
  let witnesses : Array[@witness_manifest.ReplayWitnessIdentity] = []
  let participants : Array[@attestation.Participant] = []
  let witness_signers : Array[@crypto.ExperimentalEd25519Signer] = []
  for index in 0..<4 {
    let id = "inventory-witness-" + index.to_string()
    let signer = match
      worker_derived_ed25519_signer(hasher, participant_seed_hex, id) {
      Some(value) => value
      None => return worker_error("fixture_inventory_witness_key_failed")
    }
    witness_signers.push(signer)
    witnesses.push({ id, key: signer.public_key() })
    participants.push({ id, key: signer.public_key() })
  }
  let game_manifest_digest = @replay.CanonicalAssetKernel::new(
    hasher,
    effect_author=authority.public_key(),
  ).manifest_digest()
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id,
    epoch,
    previous_checkpoint: @bft.Digest(previous_checkpoint_digest),
    manifest_digest: @attestation.replay_witness_session_manifest(
      hasher,
      game_manifest_digest~,
      referee_key=authority.public_key(),
      witnesses=participants,
      max_faults=1,
    ),
    event_root: hasher.hash_string(
      "inventory-events-v1:" + asset_id + ":" + version.to_string(),
    ),
    public_state_root: state.root(),
    asset_delta_root: hasher.hash_string("inventory-no-new-assets-v1"),
    hidden_state_commitment: None,
  })
  let signed_checkpoint = @checkpoint.sign_prepared_checkpoint(
    authority, prepared,
  )
  let attestations : Array[@attestation.SignedAttestation] = []
  for index in 0..<3 {
    attestations.push(
      @attestation.sign_replay_witness_attestation(
        hasher,
        witness_signers[index],
        prepared,
        witnesses[index].id,
        @attestation.AttestationChoice::Approve,
      ),
    )
  }
  let encoded = @wire.encode_inventory_listing_proof_bundle({
    signed_checkpoint,
    game_manifest_digest,
    witnesses,
    max_faults: 1,
    attestations,
    proof: { record, map_proof },
  })
  Json::object({
    "ok": Json::boolean(true),
    "bundle_hex": Json::string(worker_bytes_to_hex(encoded)),
    "bundle_bytes": Json::number(encoded.length().to_double()),
    "session_id": Json::string(session_id),
    "authority_key": Json::string(authority.public_key().0),
    "checkpoint_digest": Json::string(signed_checkpoint.digest.0),
    "previous_checkpoint": Json::string(previous_checkpoint_digest),
    "epoch": Json::number(epoch.to_double()),
    "game_manifest_digest": Json::string(game_manifest_digest.0),
    "asset_id": Json::string(asset_id),
    "initial_owner_id": Json::string(initial_owner_id),
    "current_owner_id": Json::string(current_owner_id),
    "version": Json::number(version.to_double()),
  }).stringify()
}

///|
fn worker_inventory_listing_refusal_code(
  reason : @central_replay.InventoryListingCentralRefusal,
) -> String {
  match reason {
    InventoryListingWireRefused(_) => "wire_refused"
    InventoryExpectedSessionMismatch => "expected_session_mismatch"
    InventoryExpectedAuthorityMismatch => "expected_authority_mismatch"
    InventoryExpectedCheckpointMismatch => "expected_checkpoint_mismatch"
    InventoryExpectedGameManifestMismatch => "expected_game_manifest_mismatch"
    InventoryCheckpointAuthenticationRefused(_) =>
      "checkpoint_authentication_refused"
    InventoryWitnessSessionRefused(_) => "witness_session_refused"
    InventoryWitnessEvidenceRefused(_) => "witness_evidence_refused"
    InventoryWitnessCheckpointMismatch => "witness_checkpoint_mismatch"
    InventoryWitnessAuthorityMismatch => "witness_authority_mismatch"
    InventoryWitnessQuorumPending(_, _) => "witness_quorum_pending"
    InventoryWitnessFinalizationMismatch => "witness_finalization_mismatch"
    InventoryOriginMismatch => "origin_mismatch"
    InventoryCurrentOwnerProofRefused => "current_owner_proof_refused"
  }
}

///|
/// Production bridge for the current-owner marketplace proof boundary.
pub fn audit_verify_inventory_listing_proof_bundle(
  bundle_hex : String,
  expected_session_id : String,
  expected_authority_key : String,
  expected_checkpoint_digest : String,
  expected_game_manifest_digest : String,
  expected_asset_id : String,
  expected_initial_owner_id : String,
  expected_item_type : String,
  expected_quantity : Int,
  expected_source_event : String,
  expected_output_index : Int,
  expected_seller_id : String,
  rejected_ancestor : Bool,
) -> String {
  let input = match worker_bytes_from_hex(bundle_hex) {
    Some(value) => value
    None => return worker_error("invalid_bundle_hex")
  }
  let hasher = @crypto.ExperimentalSha256Hasher::new()
  let verifier = @crypto.ExperimentalEd25519Verifier::new()
  let origin = @market.ItemReceipt::{
    asset_id: expected_asset_id,
    recipient_id: expected_initial_owner_id,
    item_type: expected_item_type,
    quantity: expected_quantity,
    source_event: @bft.Digest(expected_source_event),
    output_index: expected_output_index,
  }
  match
    @central_replay.verify_inventory_listing_proof_bundle(
      hasher,
      verifier,
      input,
      expected_session_id~,
      expected_authority_key=@bft.PublicKey(expected_authority_key),
      expected_checkpoint_digest=@bft.Digest(expected_checkpoint_digest),
      expected_game_manifest_digest=@bft.Digest(expected_game_manifest_digest),
      expected_origin=origin,
      expected_seller_id~,
      rejected_ancestor~,
      limits=@wire.InventoryListingWireLimits::default(),
    ) {
    InventoryListingVerified(verified) =>
      Json::object({
        "ok": Json::boolean(true),
        "complete": Json::boolean(true),
        "session_id": Json::string(verified.session_id()),
        "authority_key": Json::string(verified.authority_key().0),
        "checkpoint_digest": Json::string(verified.checkpoint_digest().0),
        "previous_checkpoint": Json::string(verified.previous_checkpoint().0),
        "epoch": Json::number(verified.epoch().to_double()),
        "public_state_root": Json::string(verified.public_state_root().0),
        "asset_id": Json::string(verified.asset_id()),
        "current_owner_id": Json::string(verified.current_owner_id()),
        "version": Json::number(verified.version().to_double()),
        "last_event": Json::string(verified.last_event().0),
        "approval_count": Json::number(verified.approval_count().to_double()),
        "required_approvals": Json::number(
          verified.required_approvals().to_double(),
        ),
        "bundle_bytes": Json::number(input.length().to_double()),
      }).stringify()
    InventoryListingRefused(reason) =>
      Json::object({
        "ok": Json::boolean(false),
        "complete": Json::boolean(true),
        "error": Json::string(worker_inventory_listing_refusal_code(reason)),
      }).stringify()
  }
}
