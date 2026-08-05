///|
fn local_store_boundary() -> AuditBoundary {
  {
    protocol_version: 1,
    purpose: "checkpoint-v1",
    manifest_digest: @commitment.AuditDigest("manifest-local"),
    scope_id: "player-alice",
    unit_id: "match-1",
  }
}

///|
fn ready_local_store() -> PlayerLocalAuditStore {
  match
    open_player_local_audit_store(
      boundary=local_store_boundary(),
      genesis_digest=@commitment.AuditDigest("genesis"),
      outbox_capacity=8,
    ) {
    PlayerLocalAuditStoreReady(store) => store
    PlayerLocalAuditStoreRefused(_) => abort("expected valid local store")
  }
}

///|
fn local_event(counter : Int, digest : String) -> PlayerLocalAuditEvent {
  {
    boundary: local_store_boundary(),
    author_id: "alice",
    counter,
    epoch: 0,
    event_digest: @commitment.AuditDigest(digest),
    canonical_event: "event:" + digest,
  }
}

///|
fn local_closure() -> TrustedEpochClosure {
  match
    open_trusted_epoch_closure(
      {
        boundary: local_store_boundary(),
        epoch: 0,
        roster_digest: @commitment.AuditDigest("roster"),
        frontier_digest: @commitment.AuditDigest("frontier"),
        certificate_digest: @commitment.AuditDigest("certificate"),
      },
      frontier_complete=true,
      conflict_free=true,
      quorum_satisfied=true,
    ) {
    EpochClosureReady(closure) => closure
    _ => abort("expected valid local closure")
  }
}

///|
fn local_draft() -> CheckpointSealDraft {
  {
    boundary: local_store_boundary(),
    epoch: 0,
    previous_checkpoint: @commitment.AuditDigest("genesis"),
    checkpoint_digest: @commitment.AuditDigest("checkpoint-0"),
    canonical_envelope: "checkpoint-envelope-0",
  }
}

///|
test "player-local store preserves events conflicts seal and outbox across restart" {
  let store = ready_local_store()
  debug_inspect(
    store.admit_event(local_event(0, "event-0")),
    content="LocalEventStored",
  )
  debug_inspect(
    store.admit_event(local_event(0, "event-0")),
    content="LocalEventDuplicate",
  )
  debug_inspect(
    store.admit_event(local_event(0, "event-fork")),
    content="LocalEventEquivocation",
  )
  let destinations = ["authority", "peer-bob"]
  match store.prepare_seal(local_draft(), local_closure(), destinations) {
    PlayerLocalSealPrepared(plan) =>
      debug_inspect(store.commit_seal(plan), content="PlayerLocalSealCommitted")
    _ => abort("expected a valid atomic seal plan")
  }
  inspect(store.event_count(), content="1")
  inspect(store.equivocation_count(), content="1")
  inspect(store.checkpoint_count(), content="1")
  inspect(store.head().epoch, content="0")
  inspect(store.outbox_entries().length(), content="2")
  match restore_player_local_audit_store(store.durable_image()) {
    PlayerLocalAuditStoreReady(restored) => {
      inspect(restored.event_count(), content="1")
      inspect(restored.equivocation_count(), content="1")
      inspect(restored.checkpoint_count(), content="1")
      inspect(restored.head().checkpoint_digest.0, content="checkpoint-0")
      inspect(restored.outbox_entries().length(), content="2")
      inspect(restored.closure_consumed(0), content="true")
      let claimed = match
        restored.claim_outbox_at(0, now_ms=100, lease_duration_ms=30) {
        PlayerLocalOutboxUpdated(entry) => entry
        _ => abort("pending outbox was not claimed")
      }
      debug_inspect(claimed.state(), content="OutboxInFlight(130)")
      let ack = match
        open_authenticated_checkpoint_ack(
          {
            boundary: claimed.boundary(),
            authority_id: claimed.destination_id(),
            epoch: claimed.epoch(),
            checkpoint_digest: claimed.checkpoint_digest(),
            decision: CheckpointAccepted,
          },
          authentication_succeeded=true,
        ) {
        CheckpointAckReady(value) => value
        _ => abort("valid local ACK did not authenticate")
      }
      match restored.acknowledge_outbox_at(0, ack) {
        PlayerLocalOutboxUpdated(entry) =>
          debug_inspect(entry.state(), content="OutboxAcknowledgedState")
        _ => abort("authenticated local ACK was not persisted")
      }
      let acknowledged_image = restored.durable_image()
      inspect(acknowledged_image.ack_history.length(), content="1")
      debug_inspect(
        acknowledged_image.outbox[0].state,
        content="OutboxAcknowledgedState",
      )
      match restore_player_local_audit_store(acknowledged_image) {
        PlayerLocalAuditStoreReady(after_ack_restart) =>
          debug_inspect(
            after_ack_restart.outbox_entries()[0].state(),
            content="OutboxAcknowledgedState",
          )
        _ => abort("acknowledged outbox did not survive restart")
      }
      match
        restore_player_local_audit_store({
          ..acknowledged_image,
          ack_history: [],
        }) {
        PlayerLocalAuditStoreRefused(reason) =>
          debug_inspect(reason, content="LocalStoreInvalidImage")
        _ => abort("acknowledged row without ACK history must not restore")
      }
    }
    PlayerLocalAuditStoreRefused(_) => abort("durable image did not restore")
  }
}

///|
test "player-local seal CAS failure leaves every relation unchanged" {
  let store = ready_local_store()
  let destinations = ["authority"]
  let plan = match
    store.prepare_seal(local_draft(), local_closure(), destinations) {
    PlayerLocalSealPrepared(plan) => plan
    _ => abort("expected a valid atomic seal plan")
  }
  debug_inspect(
    store.admit_event(local_event(0, "late-event")),
    content="LocalEventStored",
  )
  debug_inspect(
    store.commit_seal(plan),
    content="PlayerLocalSealConcurrentWrite",
  )
  inspect(store.checkpoint_count(), content="0")
  inspect(store.head().epoch, content="-1")
  inspect(store.outbox_entries().length(), content="0")
  inspect(store.closure_consumed(0), content="false")
}

///|
test "player-local seal exposes one storage-neutral atomic write set" {
  let store = ready_local_store()
  let plan = match
    store.prepare_seal(local_draft(), local_closure(), ["authority", "peer-bob"]) {
    PlayerLocalSealPrepared(plan) => plan
    _ => abort("expected a valid atomic seal plan")
  }
  let write_set = plan.write_set()
  inspect(write_set.expected_revision, content="0")
  inspect(write_set.expected_snapshot.current_epoch, content="-1")
  inspect(write_set.checkpoint.checkpoint_digest.0, content="checkpoint-0")
  inspect(write_set.next_head.epoch, content="0")
  inspect(write_set.outbox_entries.length(), content="2")
  inspect(write_set.outbox_entries[0].destination_id, content="authority")
  inspect(write_set.consumed_closure.epoch, content="0")
  inspect(
    write_set.consumed_closure.certificate_digest.0,
    content="certificate",
  )
  inspect(write_set.next_outbox_entry_count, content="2")
  inspect(write_set.next_created_order, content="2")
}

///|
test "player-local store refuses a canonical collision on a known fork digest" {
  let store = ready_local_store()
  debug_inspect(
    store.admit_event(local_event(0, "event-0")),
    content="LocalEventStored",
  )
  debug_inspect(
    store.admit_event(local_event(0, "event-fork")),
    content="LocalEventEquivocation",
  )
  debug_inspect(
    store.admit_event({
      ..local_event(0, "event-fork"),
      canonical_event: "different-bytes-with-the-same-digest",
    }),
    content="LocalEventRefused(LocalEventDigestCollision)",
  )
  inspect(store.equivocation_count(), content="1")
  match restore_player_local_audit_store(store.durable_image()) {
    PlayerLocalAuditStoreReady(_) => ()
    _ => abort("a refused digest collision must leave a restorable image")
  }
}

///|
test "player-local restore rejects a head without its atomic seal footprint" {
  let store = ready_local_store()
  let image = store.durable_image()
  let broken = {
    ..image,
    head: {
      boundary: local_store_boundary(),
      epoch: 0,
      checkpoint_digest: @commitment.AuditDigest("orphan"),
    },
  }
  match restore_player_local_audit_store(broken) {
    PlayerLocalAuditStoreRefused(reason) =>
      debug_inspect(reason, content="LocalStoreInvalidImage")
    PlayerLocalAuditStoreReady(_) => abort("orphan head must be rejected")
  }
}
