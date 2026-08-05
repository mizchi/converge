///|
fn trusted_closure_for_epoch(epoch : Int) -> TrustedEpochClosure {
  let evidence = { ..test_closure_evidence(), epoch, }
  match
    open_trusted_epoch_closure(
      evidence,
      frontier_complete=true,
      conflict_free=true,
      quorum_satisfied=true,
    ) {
    EpochClosureReady(closure) => closure
    _ => abort("expected trusted epoch closure")
  }
}

///|
fn seal_snapshot() -> CheckpointSealStorageSnapshot {
  {
    boundary: test_boundary("scope-1"),
    current_epoch: 6,
    current_digest: test_digest("checkpoint-6"),
    incoming_epoch_known: false,
    known_digest_matches: false,
    known_seal_complete: false,
    closure_consumed: false,
    outbox_entry_count: 2,
    outbox_capacity: 8,
    next_created_order: 100,
  }
}

///|
fn seal_draft() -> CheckpointSealDraft {
  {
    boundary: test_boundary("scope-1"),
    epoch: 7,
    previous_checkpoint: test_digest("checkpoint-6"),
    checkpoint_digest: test_digest("checkpoint-7"),
    canonical_envelope: "canonical-checkpoint-7",
  }
}

///|
test "atomic seal prepares history head outbox and closure consumption together" {
  match
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1", "peer-2"],
    ) {
    AtomicCheckpointSealPrepared(plan) => {
      debug_inspect(
        plan.checkpoint(),
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
          #|  previous_checkpoint: AuditDigest("checkpoint-6"),
          #|  checkpoint_digest: AuditDigest("checkpoint-7"),
          #|  canonical_envelope: "canonical-checkpoint-7",
          #|}
        ),
      )
      debug_inspect(
        plan.next_head(),
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
          #|  checkpoint_digest: AuditDigest("checkpoint-7"),
          #|}
        ),
      )
      debug_inspect(plan.consumed_closure_epoch(), content="7")
      debug_inspect(plan.next_outbox_entry_count(), content="4")
      debug_inspect(plan.next_created_order(), content="102")
      let entries = plan.outbox_entries()
      debug_inspect(entries.length(), content="2")
      debug_inspect(entries[0].destination_id(), content="\"authority-1\"")
      debug_inspect(entries[0].created_order(), content="100")
      debug_inspect(entries[0].state(), content="OutboxPending")
      debug_inspect(entries[1].destination_id(), content="\"peer-2\"")
      debug_inspect(entries[1].created_order(), content="101")
    }
    _ => abort("valid exact-next seal must prepare one atomic plan")
  }
}

///|
test "atomic seal retry is idempotent but a known different digest is a fork" {
  let committed = {
    ..seal_snapshot(),
    current_epoch: 8,
    current_digest: test_digest("checkpoint-8"),
    incoming_epoch_known: true,
    known_digest_matches: true,
    known_seal_complete: true,
    closure_consumed: true,
  }
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      committed,
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealAlreadyCommitted",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      { ..committed, known_digest_matches: false, known_seal_complete: false },
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealConflict(SealSameEpochFork)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      { ..committed, known_seal_complete: false },
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealConflict(SealIncompleteKnownCommit)",
  )
}

///|
test "atomic seal refuses parent forks gaps stale epochs and consumed closures" {
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      { ..seal_draft(), previous_checkpoint: test_digest("other-parent") },
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealConflict(SealParentFork)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      { ..seal_draft(), epoch: 8 },
      trusted_closure_for_epoch(8),
      ["authority-1"],
    ),
    content="CheckpointSealRefused(SealEpochGap)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      { ..seal_draft(), epoch: 5 },
      trusted_closure_for_epoch(5),
      ["authority-1"],
    ),
    content="CheckpointSealRefused(SealStaleEpoch)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      { ..seal_snapshot(), closure_consumed: true },
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealRefused(SealClosureAlreadyConsumed)",
  )
}

///|
test "atomic seal binds closure and checkpoint to the same boundary and epoch" {
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      { ..seal_draft(), boundary: test_boundary("foreign-scope") },
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealRefused(SealBoundaryMismatch)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      seal_draft(),
      trusted_closure_for_epoch(6),
      ["authority-1"],
    ),
    content="CheckpointSealRefused(SealClosureEpochMismatch)",
  )
}

///|
test "atomic seal validates every destination and reserves capacity before planning" {
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      seal_draft(),
      trusted_closure_for_epoch(7),
      [],
    ),
    content="CheckpointSealRefused(SealDestinationsEmpty)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1", "authority-1"],
    ),
    content="CheckpointSealRefused(SealDestinationDuplicate)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      { ..seal_snapshot(), outbox_entry_count: 7 },
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1", "peer-2"],
    ),
    content="CheckpointSealRefused(SealOutboxCapacityExceeded)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      seal_snapshot(),
      seal_draft(),
      trusted_closure_for_epoch(7),
      [""],
    ),
    content="CheckpointSealRefused(SealDestinationEmpty)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      { ..seal_snapshot(), next_created_order: 2147483647 },
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealRefused(SealCreatedOrderOverflow)",
  )
}

///|
test "atomic seal rejects internally inconsistent storage facts" {
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      { ..seal_snapshot(), known_digest_matches: true },
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealRefused(SealInvalidStorageSnapshot)",
  )
  debug_inspect(
    prepare_atomic_checkpoint_seal(
      {
        ..seal_snapshot(),
        incoming_epoch_known: true,
        known_digest_matches: true,
        known_seal_complete: true,
      },
      seal_draft(),
      trusted_closure_for_epoch(7),
      ["authority-1"],
    ),
    content="CheckpointSealRefused(SealInvalidStorageSnapshot)",
  )
}
