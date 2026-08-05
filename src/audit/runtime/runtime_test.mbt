///|
fn test_digest(value : String) -> @commitment.AuditDigest {
  @commitment.AuditDigest(value)
}

///|
fn test_boundary(scope_id : String) -> AuditBoundary {
  {
    protocol_version: 1,
    purpose: "checkpoint-v1",
    manifest_digest: test_digest("manifest"),
    scope_id,
    unit_id: "match-1",
  }
}

///|
fn test_closure_evidence() -> EpochClosureEvidence {
  {
    boundary: test_boundary("scope-1"),
    epoch: 7,
    roster_digest: test_digest("roster"),
    frontier_digest: test_digest("frontier"),
    certificate_digest: test_digest("certificate"),
  }
}

///|
fn ready_outbox(
  scope_id : String,
  destination_id : String,
  epoch : Int,
  digest : String,
  created_order : Int,
) -> CheckpointOutboxEntry {
  match
    open_checkpoint_outbox_entry(
      boundary=test_boundary(scope_id),
      destination_id~,
      epoch~,
      checkpoint_digest=test_digest(digest),
      canonical_envelope="checkpoint:" + digest,
      created_order~,
    ) {
    OutboxEntryReady(entry) => entry
    OutboxEntryRefused(_) => abort("expected valid outbox entry")
  }
}

///|
fn claim_outbox(
  entry : CheckpointOutboxEntry,
  now_ms~ : Int,
  lease_duration_ms~ : Int,
) -> CheckpointOutboxEntry {
  match claim_checkpoint_outbox(entry, now_ms~, lease_duration_ms~) {
    OutboxClaimed(claimed) => claimed
    OutboxNotRetryable => abort("expected retryable outbox entry")
    OutboxClaimRefused(_) => abort("expected valid claim")
  }
}

///|
fn raw_accepted_ack(entry : CheckpointOutboxEntry) -> CheckpointAckEvidence {
  {
    boundary: entry.boundary(),
    authority_id: entry.destination_id(),
    epoch: entry.epoch(),
    checkpoint_digest: entry.checkpoint_digest(),
    decision: CheckpointAccepted,
  }
}

///|
fn authenticate_ack_for_test(
  evidence : CheckpointAckEvidence,
) -> AuthenticatedCheckpointAck {
  match
    open_authenticated_checkpoint_ack(evidence, authentication_succeeded=true) {
    CheckpointAckReady(ack) => ack
    CheckpointAckRefused(_) => abort("expected authenticated checkpoint ACK")
  }
}

///|
fn accepted_ack(entry : CheckpointOutboxEntry) -> AuthenticatedCheckpointAck {
  authenticate_ack_for_test(raw_accepted_ack(entry))
}

///|
fn acknowledge_outbox_for_test(
  entry : CheckpointOutboxEntry,
) -> CheckpointOutboxEntry {
  match acknowledge_checkpoint_outbox(entry, accepted_ack(entry)) {
    OutboxAcknowledged(acknowledged) => acknowledged
    OutboxAlreadyAcknowledged => abort("entry was not acknowledged yet")
    OutboxAckRefused(_) => abort("expected valid acknowledgment")
  }
}

///|
test "trusted epoch closure is minted only from complete conflict-free quorum evidence" {
  let evidence = test_closure_evidence()
  let ready = open_trusted_epoch_closure(
    evidence,
    frontier_complete=true,
    conflict_free=true,
    quorum_satisfied=true,
  )
  match ready {
    EpochClosureReady(closure) => {
      debug_inspect(closure.epoch(), content="7")
      debug_inspect(
        closure.evidence(),
        content=(
          #|{
          #|  boundary: {
          #|    protocol_version: 1,
          #|    purpose: "checkpoint-v1",
          #|    manifest_digest: AuditDigest("manifest"),
          #|    scope_id: "scope-1",
          #|    unit_id: "match-1",
          #|  },
          #|  epoch: 7,
          #|  roster_digest: AuditDigest("roster"),
          #|  frontier_digest: AuditDigest("frontier"),
          #|  certificate_digest: AuditDigest("certificate"),
          #|}
        ),
      )
    }
    _ => abort("complete closure evidence must open")
  }
  debug_inspect(
    open_trusted_epoch_closure(
      evidence,
      frontier_complete=false,
      conflict_free=true,
      quorum_satisfied=true,
    ),
    content="EpochClosurePending(MissingFrontierEvents)",
  )
  debug_inspect(
    open_trusted_epoch_closure(
      evidence,
      frontier_complete=true,
      conflict_free=true,
      quorum_satisfied=false,
    ),
    content="EpochClosurePending(UnderQuorum)",
  )
  debug_inspect(
    open_trusted_epoch_closure(
      evidence,
      frontier_complete=false,
      conflict_free=false,
      quorum_satisfied=false,
    ),
    content="EpochClosureConflict(EquivocationDetected)",
  )
}

///|
test "trusted epoch closure rejects malformed boundaries before evidence claims" {
  let evidence = test_closure_evidence()
  debug_inspect(
    open_trusted_epoch_closure(
      { ..evidence, boundary: { ..evidence.boundary, scope_id: "" } },
      frontier_complete=true,
      conflict_free=true,
      quorum_satisfied=true,
    ),
    content="EpochClosureRefused(EmptyScopeId)",
  )
  debug_inspect(
    open_trusted_epoch_closure(
      { ..evidence, epoch: -1 },
      frontier_complete=true,
      conflict_free=true,
      quorum_satisfied=true,
    ),
    content="EpochClosureRefused(NegativeClosureEpoch)",
  )
  debug_inspect(
    open_trusted_epoch_closure(
      { ..evidence, certificate_digest: test_digest("") },
      frontier_complete=true,
      conflict_free=true,
      quorum_satisfied=true,
    ),
    content="EpochClosureRefused(EmptyCertificateDigest)",
  )
}

///|
test "retry selection prioritizes the oldest retryable epoch within one route" {
  let active_oldest = claim_outbox(
    ready_outbox("scope-1", "authority-1", 0, "active", 0),
    now_ms=10,
    lease_duration_ms=100,
  )
  let acknowledged_oldest = acknowledge_outbox_for_test(
    ready_outbox("scope-1", "authority-1", 0, "acked", 1),
  )
  let entries = [
    ready_outbox("scope-1", "authority-1", 2, "epoch-2", 0),
    ready_outbox("scope-1", "authority-1", 1, "later", 20),
    ready_outbox("scope-1", "authority-1", 1, "earlier", 10),
    active_oldest,
    acknowledged_oldest,
    ready_outbox("scope-2", "authority-1", 0, "foreign-scope", 0),
    ready_outbox("scope-1", "authority-2", 0, "foreign-route", 0),
  ]
  debug_inspect(
    select_oldest_retryable_checkpoint(
      entries,
      boundary=test_boundary("scope-1"),
      destination_id="authority-1",
      now_ms=20,
    ),
    content="RetrySelected(2)",
  )
  let expired = claim_outbox(
    ready_outbox("scope-1", "authority-1", 0, "expired", 0),
    now_ms=0,
    lease_duration_ms=5,
  )
  debug_inspect(
    select_oldest_retryable_checkpoint(
      [entries[0], expired],
      boundary=test_boundary("scope-1"),
      destination_id="authority-1",
      now_ms=5,
    ),
    content="RetrySelected(1)",
  )
}

///|
test "retry selection and outbox opening fail closed on invalid input" {
  debug_inspect(
    open_checkpoint_outbox_entry(
      boundary=test_boundary("scope-1"),
      destination_id="",
      epoch=1,
      checkpoint_digest=test_digest("checkpoint"),
      canonical_envelope="bytes",
      created_order=0,
    ),
    content="OutboxEntryRefused(EmptyDestinationId)",
  )
  debug_inspect(
    select_oldest_retryable_checkpoint(
      [],
      boundary=test_boundary("scope-1"),
      destination_id="authority-1",
      now_ms=-1,
    ),
    content="RetrySelectionRefused(NegativeSelectionTime)",
  )
  debug_inspect(
    select_oldest_retryable_checkpoint(
      [],
      boundary=test_boundary("scope-1"),
      destination_id="authority-1",
      now_ms=0,
    ),
    content="NoRetryableCheckpoint",
  )
}

///|
test "transport failure releases an in-flight lease without reopening acknowledged work" {
  let entry = ready_outbox("scope-1", "authority-1", 1, "checkpoint", 0)
  let claimed = claim_outbox(entry, now_ms=10, lease_duration_ms=20)
  match release_checkpoint_outbox(claimed) {
    OutboxReleased(released) =>
      debug_inspect(released.state(), content="OutboxPending")
    OutboxReleaseNoop => abort("in-flight entry must return to pending")
  }
  let acknowledged = acknowledge_outbox_for_test(entry)
  debug_inspect(
    release_checkpoint_outbox(acknowledged),
    content="OutboxReleaseNoop",
  )
}

///|
test "raw checkpoint acknowledgment cannot cross the authentication boundary" {
  let entry = ready_outbox("scope-1", "authority-1", 1, "checkpoint", 0)
  debug_inspect(
    open_authenticated_checkpoint_ack(
      raw_accepted_ack(entry),
      authentication_succeeded=false,
    ),
    content="CheckpointAckRefused(AckAuthenticationFailed)",
  )
}

///|
test "only an exact authenticated success acknowledgment completes an outbox entry" {
  let entry = ready_outbox("scope-1", "authority-1", 1, "checkpoint", 0)
  match acknowledge_checkpoint_outbox(entry, accepted_ack(entry)) {
    OutboxAcknowledged(acknowledged) => {
      debug_inspect(acknowledged.state(), content="OutboxAcknowledgedState")
      debug_inspect(
        acknowledge_checkpoint_outbox(
          acknowledged,
          { ..raw_accepted_ack(entry), decision: CheckpointDuplicate }
          |> authenticate_ack_for_test,
        ),
        content="OutboxAlreadyAcknowledged",
      )
    }
    _ => abort("exact accepted ACK must complete the entry")
  }
  match
    acknowledge_checkpoint_outbox(
      entry,
      { ..raw_accepted_ack(entry), decision: CheckpointDuplicate }
      |> authenticate_ack_for_test,
    ) {
    OutboxAcknowledged(acknowledged) =>
      debug_inspect(acknowledged.state(), content="OutboxAcknowledgedState")
    _ => abort("exact duplicate ACK must complete the entry")
  }
  debug_inspect(
    acknowledge_checkpoint_outbox(
      entry,
      { ..raw_accepted_ack(entry), authority_id: "attacker" }
      |> authenticate_ack_for_test,
    ),
    content="OutboxAckRefused(AckAuthorityMismatch)",
  )
  debug_inspect(
    acknowledge_checkpoint_outbox(
      entry,
      { ..raw_accepted_ack(entry), checkpoint_digest: test_digest("other") }
      |> authenticate_ack_for_test,
    ),
    content="OutboxAckRefused(AckDigestMismatch)",
  )
  debug_inspect(
    acknowledge_checkpoint_outbox(
      entry,
      { ..raw_accepted_ack(entry), decision: CheckpointGap }
      |> authenticate_ack_for_test,
    ),
    content="OutboxAckRefused(AckDecisionNotSuccessful)",
  )
}
