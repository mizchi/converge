import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import {
  InjectedPlayerLocalSealFault,
  PlayerLocalSqliteStore,
  PlayerLocalStoreCorruptError,
  type AuditBoundary,
  type PlayerLocalAuditEvent,
  type PlayerLocalSealWriteSet,
  type PlayerLocalStoreConfiguration,
} from "../src/player-local-sqlite.ts";

const boundary: AuditBoundary = {
  protocol_version: 1,
  purpose: "checkpoint-v1",
  manifest_digest: "manifest-local",
  scope_id: "player-alice",
  unit_id: "match-1",
};

const configuration: PlayerLocalStoreConfiguration = {
  boundary,
  genesis_digest: "genesis",
  outbox_capacity: 8,
};

function event(counter: number, digest: string): PlayerLocalAuditEvent {
  return {
    boundary,
    author_id: "alice",
    counter,
    epoch: 0,
    event_digest: digest,
    canonical_event: `event:${digest}`,
  };
}

function sealWriteSet(
  store: PlayerLocalSqliteStore,
  destinations = ["authority", "peer-bob"],
  digest = "checkpoint-0",
): PlayerLocalSealWriteSet {
  const image = store.image();
  const epoch = image.head.epoch + 1;
  const outbox_entries = destinations.map((destination_id, index) => ({
    boundary,
    destination_id,
    epoch,
    checkpoint_digest: digest,
    canonical_envelope: `envelope:${digest}`,
    created_order: image.next_created_order + index,
    state: { kind: "pending" as const },
  }));
  return {
    expected_revision: image.storage_revision,
    expected_snapshot: {
      boundary,
      current_epoch: image.head.epoch,
      current_digest: image.head.checkpoint_digest,
      incoming_epoch_known: false,
      known_digest_matches: false,
      known_seal_complete: false,
      closure_consumed: false,
      outbox_entry_count: image.outbox.length,
      outbox_capacity: image.outbox_capacity,
      next_created_order: image.next_created_order,
    },
    checkpoint: {
      boundary,
      epoch,
      previous_checkpoint: image.head.checkpoint_digest,
      checkpoint_digest: digest,
      canonical_envelope: `envelope:${digest}`,
    },
    next_head: { boundary, epoch, checkpoint_digest: digest },
    outbox_entries,
    consumed_closure: {
      boundary,
      epoch,
      roster_digest: "roster",
      frontier_digest: "frontier",
      certificate_digest: "certificate",
    },
    next_outbox_entry_count: image.outbox.length + destinations.length,
    next_created_order: image.next_created_order + destinations.length,
  };
}

async function withDatabase(
  t: test.TestContext,
): Promise<{ path: string; store: PlayerLocalSqliteStore }> {
  const directory = await mkdtemp(join(tmpdir(), "converge-player-local-"));
  t.after(async () => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "audit.sqlite");
  return { path, store: PlayerLocalSqliteStore.open(path, configuration) };
}

test("persists event forks, an atomic seal, leases, and ACK evidence", async (t) => {
  const { path, store } = await withDatabase(t);
  assert.deepEqual(store.admitEvent(event(0, "event-0")), {
    decision: "stored",
  });
  assert.deepEqual(store.admitEvent(event(0, "event-0")), {
    decision: "duplicate",
  });
  assert.deepEqual(store.admitEvent(event(0, "event-fork")), {
    decision: "equivocation",
  });

  const writeSet = sealWriteSet(store);
  assert.deepEqual(store.commitSeal(writeSet), { decision: "committed" });
  store.close();

  const restarted = PlayerLocalSqliteStore.open(path, configuration);
  const restored = restarted.image();
  assert.equal(restored.events.length, 1);
  assert.equal(restored.equivocations.length, 1);
  assert.equal(restored.checkpoints.length, 1);
  assert.deepEqual(restored.head, {
    boundary,
    epoch: 0,
    checkpoint_digest: "checkpoint-0",
  });
  assert.equal(restored.outbox.length, 2);
  assert.equal(restored.consumed_closures.length, 1);

  const claimed = restarted.claimOutbox(0, 100, 30);
  assert.deepEqual(claimed?.state, {
    kind: "in_flight",
    lease_expires_at_ms: 130,
  });
  assert.deepEqual(
    restarted.acknowledgeOutbox({
      boundary,
      authority_id: "authority",
      epoch: 0,
      checkpoint_digest: "checkpoint-0",
      decision: "accepted",
    }),
    { decision: "updated" },
  );
  restarted.close();

  const afterAckRestart = PlayerLocalSqliteStore.open(path, configuration);
  const acknowledged = afterAckRestart.image();
  assert.equal(acknowledged.ack_history.length, 1);
  assert.deepEqual(acknowledged.outbox[0]?.state, { kind: "acknowledged" });
  afterAckRestart.close();
});

for (
  const faultPoint of [
    "after_history",
    "after_head",
    "after_outbox",
    "after_closure",
  ] as const
) {
  test(`rolls back ${faultPoint} without a partial seal`, async (t) => {
    const { store } = await withDatabase(t);
    const before = store.image();
    assert.throws(
      () => store.commitSeal(sealWriteSet(store), faultPoint),
      (error) =>
        error instanceof InjectedPlayerLocalSealFault &&
        error.faultPoint === faultPoint,
    );
    assert.deepEqual(store.image(), before);
    assert.deepEqual(store.commitSeal(sealWriteSet(store)), {
      decision: "committed",
    });
    store.close();
  });
}

test("rejects a stale revision without changing any seal relation", async (t) => {
  const { store } = await withDatabase(t);
  const stale = sealWriteSet(store);
  assert.deepEqual(store.admitEvent(event(0, "late-event")), {
    decision: "stored",
  });
  const before = store.image();
  assert.deepEqual(store.commitSeal(stale), { decision: "concurrent_write" });
  assert.deepEqual(store.image(), before);
  store.close();
});

test("refuses different canonical bytes for a known fork digest", async (t) => {
  const { store } = await withDatabase(t);
  assert.deepEqual(store.admitEvent(event(0, "event-0")), {
    decision: "stored",
  });
  assert.deepEqual(store.admitEvent(event(0, "event-fork")), {
    decision: "equivocation",
  });
  assert.deepEqual(
    store.admitEvent({
      ...event(0, "event-fork"),
      canonical_event: "different-bytes-with-the-same-digest",
    }),
    { decision: "refused", reason: "digest_collision" },
  );
  assert.equal(store.image().equivocations.length, 1);
  store.close();
});

test("refuses an over-capacity write set atomically", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "converge-player-local-"));
  t.after(async () => rm(directory, { recursive: true, force: true }));
  const store = PlayerLocalSqliteStore.open(join(directory, "audit.sqlite"), {
    ...configuration,
    outbox_capacity: 1,
  });
  const before = store.image();
  const result = store.commitSeal(
    sealWriteSet(store, ["authority", "peer-bob"]),
  );
  assert.deepEqual(result, {
    decision: "refused",
    reason: "invalid_write_set",
  });
  assert.deepEqual(store.image(), before);
  store.close();
});

test("detects an acknowledged outbox row whose ACK footprint was lost", async (t) => {
  const { path, store } = await withDatabase(t);
  assert.deepEqual(store.commitSeal(sealWriteSet(store, ["authority"])), {
    decision: "committed",
  });
  store.claimOutbox(0, 100, 30);
  assert.deepEqual(
    store.acknowledgeOutbox({
      boundary,
      authority_id: "authority",
      epoch: 0,
      checkpoint_digest: "checkpoint-0",
      decision: "duplicate",
    }),
    { decision: "updated" },
  );
  store.close();

  const corrupt = new DatabaseSync(path);
  corrupt.exec("DELETE FROM player_local_ack_history");
  corrupt.close();
  assert.throws(
    () => PlayerLocalSqliteStore.open(path, configuration),
    PlayerLocalStoreCorruptError,
  );
});
