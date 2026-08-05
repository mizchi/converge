import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import type {
  AuditBoundary,
  CheckpointAckEvidence,
  CheckpointOutboxState,
  CheckpointSealDraft,
  CheckpointSealHead,
  CheckpointSealStorageSnapshot,
  EpochClosureEvidence,
  PlayerLocalAuditEvent,
  PlayerLocalAuditImage,
  PlayerLocalCheckpointOutboxRecord,
  PlayerLocalEventAdmission,
  PlayerLocalOutboxAckResult,
  PlayerLocalSealCommitResult,
  PlayerLocalSealFaultPoint,
  PlayerLocalSealWriteSet,
  PlayerLocalStoreConfiguration,
} from "./contracts.ts";

export type * from "./contracts.ts";

export class InjectedPlayerLocalSealFault extends Error {
  readonly faultPoint: PlayerLocalSealFaultPoint;

  constructor(faultPoint: PlayerLocalSealFaultPoint) {
    super(`injected player-local seal fault: ${faultPoint}`);
    this.faultPoint = faultPoint;
  }
}

export class PlayerLocalStoreCorruptError extends Error {
  constructor(message = "player-local SQLite image violates its contract") {
    super(message);
  }
}

interface ConfigurationRow {
  protocol_version: number;
  purpose: string;
  manifest_digest: string;
  scope_id: string;
  unit_id: string;
  genesis_digest: string;
  outbox_capacity: number;
  next_created_order: number;
  storage_revision: number;
}

interface EventRow {
  author_id: string;
  counter: number;
  epoch: number;
  event_digest: string;
  canonical_event: string;
}

interface EquivocationRow {
  author_id: string;
  counter: number;
  epoch: number;
  conflicting_digest: string;
  canonical_event: string;
}

interface CheckpointRow {
  epoch: number;
  previous_checkpoint: string;
  checkpoint_digest: string;
  canonical_envelope: string;
}

interface HeadRow {
  epoch: number;
  checkpoint_digest: string;
}

interface ClosureRow {
  epoch: number;
  roster_digest: string;
  frontier_digest: string;
  certificate_digest: string;
}

interface OutboxRow {
  destination_id: string;
  epoch: number;
  checkpoint_digest: string;
  canonical_envelope: string;
  created_order: number;
  state: "pending" | "in_flight" | "acknowledged";
  lease_expires_at_ms: number | null;
}

interface AckRow {
  authority_id: string;
  epoch: number;
  checkpoint_digest: string;
  decision: "accepted" | "duplicate";
}

class PlayerLocalSealCasConflict extends Error {}

function isNonNegativeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function boundaryValid(boundary: AuditBoundary): boolean {
  return (
    Number.isSafeInteger(boundary.protocol_version) &&
    boundary.protocol_version > 0 &&
    boundary.purpose.length > 0 &&
    boundary.manifest_digest.length > 0 &&
    boundary.scope_id.length > 0 &&
    boundary.unit_id.length > 0
  );
}

function sameBoundary(left: AuditBoundary, right: AuditBoundary): boolean {
  return (
    left.protocol_version === right.protocol_version &&
    left.purpose === right.purpose &&
    left.manifest_digest === right.manifest_digest &&
    left.scope_id === right.scope_id &&
    left.unit_id === right.unit_id
  );
}

function sameHead(left: CheckpointSealHead, right: CheckpointSealHead): boolean {
  return (
    sameBoundary(left.boundary, right.boundary) &&
    left.epoch === right.epoch &&
    left.checkpoint_digest === right.checkpoint_digest
  );
}

function sameSnapshot(
  left: CheckpointSealStorageSnapshot,
  right: CheckpointSealStorageSnapshot,
): boolean {
  return (
    sameBoundary(left.boundary, right.boundary) &&
    left.current_epoch === right.current_epoch &&
    left.current_digest === right.current_digest &&
    left.incoming_epoch_known === right.incoming_epoch_known &&
    left.known_digest_matches === right.known_digest_matches &&
    left.known_seal_complete === right.known_seal_complete &&
    left.closure_consumed === right.closure_consumed &&
    left.outbox_entry_count === right.outbox_entry_count &&
    left.outbox_capacity === right.outbox_capacity &&
    left.next_created_order === right.next_created_order
  );
}

function eventValid(
  boundary: AuditBoundary,
  event: PlayerLocalAuditEvent,
): boolean {
  return (
    sameBoundary(boundary, event.boundary) &&
    event.author_id.length > 0 &&
    isNonNegativeInteger(event.counter) &&
    isNonNegativeInteger(event.epoch) &&
    event.event_digest.length > 0 &&
    event.canonical_event.length > 0
  );
}

function checkpointValid(
  boundary: AuditBoundary,
  checkpoint: CheckpointSealDraft,
): boolean {
  return (
    sameBoundary(boundary, checkpoint.boundary) &&
    isNonNegativeInteger(checkpoint.epoch) &&
    checkpoint.previous_checkpoint.length > 0 &&
    checkpoint.checkpoint_digest.length > 0 &&
    checkpoint.canonical_envelope.length > 0
  );
}

function closureValid(
  boundary: AuditBoundary,
  closure: EpochClosureEvidence,
): boolean {
  return (
    sameBoundary(boundary, closure.boundary) &&
    isNonNegativeInteger(closure.epoch) &&
    closure.roster_digest.length > 0 &&
    closure.frontier_digest.length > 0 &&
    closure.certificate_digest.length > 0
  );
}

export class PlayerLocalSqliteStore {
  private readonly database: DatabaseSync;

  static open(
    path: string,
    configuration: PlayerLocalStoreConfiguration,
  ): PlayerLocalSqliteStore {
    if (
      !boundaryValid(configuration.boundary) ||
      configuration.genesis_digest.length === 0 ||
      !isNonNegativeInteger(configuration.outbox_capacity)
    ) {
      throw new TypeError("invalid player-local store configuration");
    }
    const database = new DatabaseSync(path);
    try {
      const store = new PlayerLocalSqliteStore(database);
      store.createSchema();
      store.configure(configuration);
      store.assertValidImage();
      return store;
    } catch (error) {
      database.close();
      throw error;
    }
  }

  private constructor(database: DatabaseSync) {
    this.database = database;
  }

  close(): void {
    this.database.close();
  }

  admitEvent(event: PlayerLocalAuditEvent): PlayerLocalEventAdmission {
    const boundary = this.boundary();
    if (!eventValid(boundary, event)) {
      return { decision: "refused", reason: "invalid_event" };
    }
    return this.transaction(() => {
      const accepted = this.get<EventRow>(
        `SELECT author_id, counter, epoch, event_digest, canonical_event
         FROM player_local_events WHERE author_id = ? AND counter = ?`,
        event.author_id,
        event.counter,
      );
      if (!accepted) {
        this.run(
          `INSERT INTO player_local_events
           (author_id, counter, epoch, event_digest, canonical_event)
           VALUES (?, ?, ?, ?, ?)`,
          event.author_id,
          event.counter,
          event.epoch,
          event.event_digest,
          event.canonical_event,
        );
        this.incrementRevision();
        return { decision: "stored" };
      }
      if (accepted.event_digest === event.event_digest) {
        return accepted.epoch === event.epoch &&
            accepted.canonical_event === event.canonical_event
          ? { decision: "duplicate" }
          : { decision: "refused", reason: "digest_collision" };
      }
      const knownConflict = this.get<{ epoch: number; canonical_event: string }>(
        `SELECT epoch, canonical_event FROM player_local_equivocations
         WHERE author_id = ? AND counter = ? AND conflicting_digest = ?`,
        event.author_id,
        event.counter,
        event.event_digest,
      );
      if (knownConflict) {
        return knownConflict.epoch === event.epoch &&
            knownConflict.canonical_event === event.canonical_event
          ? { decision: "equivocation" }
          : { decision: "refused", reason: "digest_collision" };
      } else {
        this.run(
          `INSERT INTO player_local_equivocations
           (author_id, counter, epoch, conflicting_digest, canonical_event)
           VALUES (?, ?, ?, ?, ?)`,
          event.author_id,
          event.counter,
          event.epoch,
          event.event_digest,
          event.canonical_event,
        );
        this.incrementRevision();
      }
      return { decision: "equivocation" };
    });
  }

  commitSeal(
    writeSet: PlayerLocalSealWriteSet,
    faultPoint?: PlayerLocalSealFaultPoint,
  ): PlayerLocalSealCommitResult {
    try {
      return this.transaction(() => {
        const config = this.configuration();
        if (config.storage_revision !== writeSet.expected_revision) {
          return { decision: "concurrent_write" };
        }
        const actualSnapshot = this.sealSnapshot(
          writeSet.checkpoint,
          writeSet.outbox_entries.map((entry) => entry.destination_id),
        );
      if (!sameSnapshot(actualSnapshot, writeSet.expected_snapshot)) {
          return { decision: "concurrent_write" };
        }
        if (!this.writeSetValid(writeSet, config)) {
          return { decision: "refused", reason: "invalid_write_set" };
        }

        const checkpoint = writeSet.checkpoint;
        this.run(
          `INSERT INTO player_local_checkpoints
           (epoch, previous_checkpoint, checkpoint_digest, canonical_envelope)
           VALUES (?, ?, ?, ?)`,
          checkpoint.epoch,
          checkpoint.previous_checkpoint,
          checkpoint.checkpoint_digest,
          checkpoint.canonical_envelope,
        );
        this.inject(faultPoint, "after_history");

        const headWrite = this.run(
          `UPDATE player_local_head SET epoch = ?, checkpoint_digest = ?
           WHERE singleton = 1 AND epoch = ? AND checkpoint_digest = ?`,
          writeSet.next_head.epoch,
          writeSet.next_head.checkpoint_digest,
          writeSet.expected_snapshot.current_epoch,
          writeSet.expected_snapshot.current_digest,
        );
        if (headWrite !== 1) throw new PlayerLocalSealCasConflict();
        this.inject(faultPoint, "after_head");

        for (const entry of writeSet.outbox_entries) {
          this.run(
            `INSERT INTO player_local_outbox
             (destination_id, epoch, checkpoint_digest, canonical_envelope,
              created_order, state, lease_expires_at_ms)
             VALUES (?, ?, ?, ?, ?, 'pending', NULL)`,
            entry.destination_id,
            entry.epoch,
            entry.checkpoint_digest,
            entry.canonical_envelope,
            entry.created_order,
          );
        }
        this.inject(faultPoint, "after_outbox");

        const closure = writeSet.consumed_closure;
        this.run(
          `INSERT INTO player_local_consumed_closures
           (epoch, roster_digest, frontier_digest, certificate_digest)
           VALUES (?, ?, ?, ?)`,
          closure.epoch,
          closure.roster_digest,
          closure.frontier_digest,
          closure.certificate_digest,
        );
        this.inject(faultPoint, "after_closure");

        const configWrite = this.run(
          `UPDATE player_local_config
           SET next_created_order = ?, storage_revision = storage_revision + 1
           WHERE singleton = 1 AND storage_revision = ?
             AND next_created_order = ?`,
          writeSet.next_created_order,
          writeSet.expected_revision,
          writeSet.expected_snapshot.next_created_order,
        );
        if (configWrite !== 1) throw new PlayerLocalSealCasConflict();
        return { decision: "committed" };
      });
    } catch (error) {
      if (error instanceof InjectedPlayerLocalSealFault) throw error;
      if (error instanceof PlayerLocalSealCasConflict) {
        return { decision: "concurrent_write" };
      }
      throw error;
    }
  }

  claimOutbox(
    createdOrder: number,
    nowMs: number,
    leaseDurationMs: number,
  ): PlayerLocalCheckpointOutboxRecord | undefined {
    if (
      !isNonNegativeInteger(createdOrder) ||
      !isNonNegativeInteger(nowMs) ||
      !Number.isSafeInteger(leaseDurationMs) ||
      leaseDurationMs <= 0
    ) {
      return undefined;
    }
    const leaseExpiresAt = nowMs + leaseDurationMs;
    if (!Number.isSafeInteger(leaseExpiresAt) || leaseExpiresAt < nowMs) {
      return undefined;
    }
    return this.transaction(() => {
      const row = this.outboxAt(createdOrder);
      if (
        !row ||
        row.state === "acknowledged" ||
        (row.state === "in_flight" &&
          row.lease_expires_at_ms !== null &&
          row.lease_expires_at_ms > nowMs)
      ) {
        return undefined;
      }
      const changed = this.run(
        `UPDATE player_local_outbox
         SET state = 'in_flight', lease_expires_at_ms = ?
         WHERE created_order = ? AND (
           state = 'pending' OR
           (state = 'in_flight' AND lease_expires_at_ms <= ?)
         )`,
        leaseExpiresAt,
        createdOrder,
        nowMs,
      );
      if (changed !== 1) return undefined;
      this.incrementRevision();
      return this.outboxRecord(
        {
          ...row,
          state: "in_flight",
          lease_expires_at_ms: leaseExpiresAt,
        },
        this.boundary(),
      );
    });
  }

  releaseOutbox(createdOrder: number): boolean {
    if (!isNonNegativeInteger(createdOrder)) return false;
    return this.transaction(() => {
      const changed = this.run(
        `UPDATE player_local_outbox
         SET state = 'pending', lease_expires_at_ms = NULL
         WHERE created_order = ? AND state = 'in_flight'`,
        createdOrder,
      );
      if (changed !== 1) return false;
      this.incrementRevision();
      return true;
    });
  }

  acknowledgeOutbox(
    evidence: CheckpointAckEvidence,
  ): PlayerLocalOutboxAckResult {
    const boundary = this.boundary();
    if (
      !sameBoundary(boundary, evidence.boundary) ||
      evidence.authority_id.length === 0 ||
      !isNonNegativeInteger(evidence.epoch) ||
      evidence.checkpoint_digest.length === 0 ||
      (evidence.decision !== "accepted" && evidence.decision !== "duplicate")
    ) {
      return { decision: "refused", reason: "invalid_ack" };
    }
    return this.transaction(() => {
      const row = this.get<OutboxRow>(
        `SELECT destination_id, epoch, checkpoint_digest, canonical_envelope,
                created_order, state, lease_expires_at_ms
         FROM player_local_outbox
         WHERE destination_id = ? AND epoch = ? AND checkpoint_digest = ?`,
        evidence.authority_id,
        evidence.epoch,
        evidence.checkpoint_digest,
      );
      if (!row) return { decision: "refused", reason: "ack_mismatch" };
      if (row.state === "acknowledged") return { decision: "no_change" };
      this.run(
        `INSERT INTO player_local_ack_history
         (authority_id, epoch, checkpoint_digest, decision)
         VALUES (?, ?, ?, ?)`,
        evidence.authority_id,
        evidence.epoch,
        evidence.checkpoint_digest,
        evidence.decision,
      );
      const changed = this.run(
        `UPDATE player_local_outbox
         SET state = 'acknowledged', lease_expires_at_ms = NULL
         WHERE created_order = ? AND state != 'acknowledged'`,
        row.created_order,
      );
      if (changed !== 1) throw new PlayerLocalSealCasConflict();
      this.incrementRevision();
      return { decision: "updated" };
    });
  }

  image(): PlayerLocalAuditImage {
    const config = this.configuration();
    const boundary = this.boundaryFromRow(config);
    const eventRows = this.all<EventRow>(
      `SELECT author_id, counter, epoch, event_digest, canonical_event
       FROM player_local_events ORDER BY author_id, counter`,
    );
    const events = eventRows.map((row) => this.eventFromRow(boundary, row));
    const accepted = new Map(
      events.map((event) => [`${event.author_id}\u0000${event.counter}`, event]),
    );
    const equivocations = this.all<EquivocationRow>(
      `SELECT author_id, counter, epoch, conflicting_digest, canonical_event
       FROM player_local_equivocations
       ORDER BY author_id, counter, conflicting_digest`,
    ).map((row) => {
      const acceptedEvent = accepted.get(`${row.author_id}\u0000${row.counter}`);
      if (!acceptedEvent) {
        throw new PlayerLocalStoreCorruptError("orphan equivocation row");
      }
      return {
        accepted: acceptedEvent,
        conflicting: this.eventFromRow(boundary, {
          author_id: row.author_id,
          counter: row.counter,
          epoch: row.epoch,
          event_digest: row.conflicting_digest,
          canonical_event: row.canonical_event,
        }),
      };
    });
    const checkpoints = this.all<CheckpointRow>(
      `SELECT epoch, previous_checkpoint, checkpoint_digest, canonical_envelope
       FROM player_local_checkpoints ORDER BY epoch`,
    ).map((row) => ({ boundary, ...row }));
    const headRow = this.get<HeadRow>(
      `SELECT epoch, checkpoint_digest FROM player_local_head
       WHERE singleton = 1`,
    );
    if (!headRow) throw new PlayerLocalStoreCorruptError("missing local head");
    const consumed_closures = this.all<ClosureRow>(
      `SELECT epoch, roster_digest, frontier_digest, certificate_digest
       FROM player_local_consumed_closures ORDER BY epoch`,
    ).map((row) => ({ boundary, ...row }));
    const outbox = this.all<OutboxRow>(
      `SELECT destination_id, epoch, checkpoint_digest, canonical_envelope,
              created_order, state, lease_expires_at_ms
       FROM player_local_outbox ORDER BY created_order`,
    ).map((row) => this.outboxRecord(row, boundary));
    const ack_history = this.all<AckRow>(
      `SELECT authority_id, epoch, checkpoint_digest, decision
       FROM player_local_ack_history
       ORDER BY authority_id, epoch, checkpoint_digest`,
    ).map((row) => ({ boundary, ...row }));
    return {
      boundary,
      genesis_digest: config.genesis_digest,
      outbox_capacity: config.outbox_capacity,
      events,
      equivocations,
      checkpoints,
      head: { boundary, ...headRow },
      consumed_closures,
      outbox,
      ack_history,
      next_created_order: config.next_created_order,
      storage_revision: config.storage_revision,
    };
  }

  private createSchema(): void {
    this.database.exec(`
      PRAGMA foreign_keys = ON;
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS player_local_config (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        protocol_version INTEGER NOT NULL CHECK (protocol_version > 0),
        purpose TEXT NOT NULL CHECK (length(purpose) > 0),
        manifest_digest TEXT NOT NULL CHECK (length(manifest_digest) > 0),
        scope_id TEXT NOT NULL CHECK (length(scope_id) > 0),
        unit_id TEXT NOT NULL CHECK (length(unit_id) > 0),
        genesis_digest TEXT NOT NULL CHECK (length(genesis_digest) > 0),
        outbox_capacity INTEGER NOT NULL CHECK (outbox_capacity >= 0),
        next_created_order INTEGER NOT NULL CHECK (next_created_order >= 0),
        storage_revision INTEGER NOT NULL CHECK (storage_revision >= 0)
      );
      CREATE TABLE IF NOT EXISTS player_local_events (
        author_id TEXT NOT NULL CHECK (length(author_id) > 0),
        counter INTEGER NOT NULL CHECK (counter >= 0),
        epoch INTEGER NOT NULL CHECK (epoch >= 0),
        event_digest TEXT NOT NULL CHECK (length(event_digest) > 0),
        canonical_event TEXT NOT NULL CHECK (length(canonical_event) > 0),
        PRIMARY KEY (author_id, counter)
      );
      CREATE TABLE IF NOT EXISTS player_local_equivocations (
        author_id TEXT NOT NULL,
        counter INTEGER NOT NULL,
        epoch INTEGER NOT NULL CHECK (epoch >= 0),
        conflicting_digest TEXT NOT NULL CHECK (length(conflicting_digest) > 0),
        canonical_event TEXT NOT NULL CHECK (length(canonical_event) > 0),
        PRIMARY KEY (author_id, counter, conflicting_digest),
        FOREIGN KEY (author_id, counter)
          REFERENCES player_local_events(author_id, counter)
      );
      CREATE TABLE IF NOT EXISTS player_local_checkpoints (
        epoch INTEGER PRIMARY KEY CHECK (epoch >= 0),
        previous_checkpoint TEXT NOT NULL CHECK (length(previous_checkpoint) > 0),
        checkpoint_digest TEXT NOT NULL CHECK (length(checkpoint_digest) > 0),
        canonical_envelope TEXT NOT NULL CHECK (length(canonical_envelope) > 0)
      );
      CREATE TABLE IF NOT EXISTS player_local_head (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        epoch INTEGER NOT NULL CHECK (epoch >= -1),
        checkpoint_digest TEXT NOT NULL CHECK (length(checkpoint_digest) > 0)
      );
      CREATE TABLE IF NOT EXISTS player_local_consumed_closures (
        epoch INTEGER PRIMARY KEY CHECK (epoch >= 0),
        roster_digest TEXT NOT NULL CHECK (length(roster_digest) > 0),
        frontier_digest TEXT NOT NULL CHECK (length(frontier_digest) > 0),
        certificate_digest TEXT NOT NULL CHECK (length(certificate_digest) > 0),
        FOREIGN KEY (epoch) REFERENCES player_local_checkpoints(epoch)
      );
      CREATE TABLE IF NOT EXISTS player_local_outbox (
        destination_id TEXT NOT NULL CHECK (length(destination_id) > 0),
        epoch INTEGER NOT NULL CHECK (epoch >= 0),
        checkpoint_digest TEXT NOT NULL CHECK (length(checkpoint_digest) > 0),
        canonical_envelope TEXT NOT NULL CHECK (length(canonical_envelope) > 0),
        created_order INTEGER NOT NULL UNIQUE CHECK (created_order >= 0),
        state TEXT NOT NULL CHECK (state IN ('pending', 'in_flight', 'acknowledged')),
        lease_expires_at_ms INTEGER,
        PRIMARY KEY (destination_id, epoch, checkpoint_digest),
        FOREIGN KEY (epoch) REFERENCES player_local_checkpoints(epoch),
        CHECK (
          (state = 'in_flight' AND lease_expires_at_ms IS NOT NULL AND lease_expires_at_ms >= 0)
          OR (state != 'in_flight' AND lease_expires_at_ms IS NULL)
        )
      );
      CREATE INDEX IF NOT EXISTS player_local_outbox_retry_order
      ON player_local_outbox(state, created_order);
      CREATE TABLE IF NOT EXISTS player_local_ack_history (
        authority_id TEXT NOT NULL CHECK (length(authority_id) > 0),
        epoch INTEGER NOT NULL CHECK (epoch >= 0),
        checkpoint_digest TEXT NOT NULL CHECK (length(checkpoint_digest) > 0),
        decision TEXT NOT NULL CHECK (decision IN ('accepted', 'duplicate')),
        PRIMARY KEY (authority_id, epoch, checkpoint_digest)
      );
    `);
  }

  private configure(configuration: PlayerLocalStoreConfiguration): void {
    this.transaction(() => {
      const existing = this.get<ConfigurationRow>(
        `SELECT protocol_version, purpose, manifest_digest, scope_id, unit_id,
                genesis_digest, outbox_capacity, next_created_order,
                storage_revision
         FROM player_local_config WHERE singleton = 1`,
      );
      if (existing) {
        if (
          !sameBoundary(
            this.boundaryFromRow(existing),
            configuration.boundary,
          ) ||
          existing.genesis_digest !== configuration.genesis_digest ||
          existing.outbox_capacity !== configuration.outbox_capacity
        ) {
          throw new PlayerLocalStoreCorruptError(
            "player-local database boundary/configuration conflict",
          );
        }
        return;
      }
      const boundary = configuration.boundary;
      this.run(
        `INSERT INTO player_local_config
         (singleton, protocol_version, purpose, manifest_digest, scope_id,
          unit_id, genesis_digest, outbox_capacity, next_created_order,
          storage_revision)
         VALUES (1, ?, ?, ?, ?, ?, ?, ?, 0, 0)`,
        boundary.protocol_version,
        boundary.purpose,
        boundary.manifest_digest,
        boundary.scope_id,
        boundary.unit_id,
        configuration.genesis_digest,
        configuration.outbox_capacity,
      );
      this.run(
        `INSERT INTO player_local_head
         (singleton, epoch, checkpoint_digest) VALUES (1, -1, ?)`,
        configuration.genesis_digest,
      );
    });
  }

  private writeSetValid(
    writeSet: PlayerLocalSealWriteSet,
    config: ConfigurationRow,
  ): boolean {
    const boundary = this.boundaryFromRow(config);
    const checkpoint = writeSet.checkpoint;
    const snapshot = writeSet.expected_snapshot;
    if (
      !isNonNegativeInteger(writeSet.expected_revision) ||
      !checkpointValid(boundary, checkpoint) ||
      !closureValid(boundary, writeSet.consumed_closure) ||
      checkpoint.epoch !== snapshot.current_epoch + 1 ||
      checkpoint.previous_checkpoint !== snapshot.current_digest ||
      writeSet.consumed_closure.epoch !== checkpoint.epoch ||
      !sameHead(writeSet.next_head, {
        boundary,
        epoch: checkpoint.epoch,
        checkpoint_digest: checkpoint.checkpoint_digest,
      }) ||
      writeSet.outbox_entries.length === 0 ||
      writeSet.next_outbox_entry_count !==
        snapshot.outbox_entry_count + writeSet.outbox_entries.length ||
      writeSet.next_outbox_entry_count > config.outbox_capacity ||
      writeSet.next_created_order !==
        snapshot.next_created_order + writeSet.outbox_entries.length ||
      !Number.isSafeInteger(writeSet.next_created_order)
    ) {
      return false;
    }
    const destinations = new Set<string>();
    for (const [index, entry] of writeSet.outbox_entries.entries()) {
      if (
        !sameBoundary(boundary, entry.boundary) ||
        entry.destination_id.length === 0 ||
        destinations.has(entry.destination_id) ||
        entry.epoch !== checkpoint.epoch ||
        entry.checkpoint_digest !== checkpoint.checkpoint_digest ||
        entry.canonical_envelope !== checkpoint.canonical_envelope ||
        entry.created_order !== snapshot.next_created_order + index ||
        entry.state.kind !== "pending"
      ) {
        return false;
      }
      destinations.add(entry.destination_id);
    }
    return true;
  }

  private sealSnapshot(
    checkpoint: CheckpointSealDraft,
    destinations: string[],
  ): CheckpointSealStorageSnapshot {
    const config = this.configuration();
    const boundary = this.boundaryFromRow(config);
    const head = this.get<HeadRow>(
      `SELECT epoch, checkpoint_digest FROM player_local_head
       WHERE singleton = 1`,
    );
    if (!head) throw new PlayerLocalStoreCorruptError("missing local head");
    const known = this.get<CheckpointRow>(
      `SELECT epoch, previous_checkpoint, checkpoint_digest, canonical_envelope
       FROM player_local_checkpoints WHERE epoch = ?`,
      checkpoint.epoch,
    );
    const closureConsumed = this.get<{ present: number }>(
      `SELECT 1 AS present FROM player_local_consumed_closures WHERE epoch = ?`,
      checkpoint.epoch,
    ) !== undefined;
    const allOutboxPresent =
      destinations.length > 0 &&
      destinations.every(
        (destination) =>
          this.get<{ present: number }>(
            `SELECT 1 AS present FROM player_local_outbox
             WHERE destination_id = ? AND epoch = ? AND checkpoint_digest = ?
               AND canonical_envelope = ?`,
            destination,
            checkpoint.epoch,
            checkpoint.checkpoint_digest,
            checkpoint.canonical_envelope,
          ) !== undefined,
      );
    const knownDigestMatches =
      known?.checkpoint_digest === checkpoint.checkpoint_digest;
    return {
      boundary,
      current_epoch: head.epoch,
      current_digest: head.checkpoint_digest,
      incoming_epoch_known: known !== undefined,
      known_digest_matches: knownDigestMatches,
      known_seal_complete:
        knownDigestMatches && closureConsumed && allOutboxPresent,
      closure_consumed: closureConsumed,
      outbox_entry_count: this.count("player_local_outbox"),
      outbox_capacity: config.outbox_capacity,
      next_created_order: config.next_created_order,
    };
  }

  private assertValidImage(): void {
    let image: PlayerLocalAuditImage;
    try {
      image = this.image();
    } catch (error) {
      if (error instanceof PlayerLocalStoreCorruptError) throw error;
      throw new PlayerLocalStoreCorruptError(String(error));
    }
    if (
      !boundaryValid(image.boundary) ||
      image.genesis_digest.length === 0 ||
      !isNonNegativeInteger(image.outbox_capacity) ||
      !isNonNegativeInteger(image.storage_revision) ||
      !isNonNegativeInteger(image.next_created_order) ||
      image.outbox.length > image.outbox_capacity
    ) {
      throw new PlayerLocalStoreCorruptError();
    }
    const eventKeys = new Set<string>();
    for (const event of image.events) {
      const key = `${event.author_id}\u0000${event.counter}`;
      if (!eventValid(image.boundary, event) || eventKeys.has(key)) {
        throw new PlayerLocalStoreCorruptError("invalid event relation");
      }
      eventKeys.add(key);
    }
    const conflictKeys = new Set<string>();
    for (const evidence of image.equivocations) {
      const key = `${evidence.accepted.author_id}\u0000${evidence.accepted.counter}`;
      const conflictKey = `${key}\u0000${evidence.conflicting.event_digest}`;
      if (
        !eventKeys.has(key) ||
        !eventValid(image.boundary, evidence.conflicting) ||
        evidence.accepted.author_id !== evidence.conflicting.author_id ||
        evidence.accepted.counter !== evidence.conflicting.counter ||
        evidence.accepted.event_digest === evidence.conflicting.event_digest ||
        conflictKeys.has(conflictKey)
      ) {
        throw new PlayerLocalStoreCorruptError("invalid equivocation relation");
      }
      conflictKeys.add(conflictKey);
    }

    let expectedParent = image.genesis_digest;
    for (const [epoch, checkpoint] of image.checkpoints.entries()) {
      if (
        !checkpointValid(image.boundary, checkpoint) ||
        checkpoint.epoch !== epoch ||
        checkpoint.previous_checkpoint !== expectedParent ||
        image.consumed_closures[epoch]?.epoch !== epoch
      ) {
        throw new PlayerLocalStoreCorruptError("invalid checkpoint chain");
      }
      expectedParent = checkpoint.checkpoint_digest;
    }
    if (image.consumed_closures.length !== image.checkpoints.length) {
      throw new PlayerLocalStoreCorruptError("orphan closure footprint");
    }
    const expectedHead = image.checkpoints.at(-1)
      ? {
          boundary: image.boundary,
          epoch: image.checkpoints.length - 1,
          checkpoint_digest: expectedParent,
        }
      : {
          boundary: image.boundary,
          epoch: -1,
          checkpoint_digest: image.genesis_digest,
        };
    if (!sameHead(image.head, expectedHead)) {
      throw new PlayerLocalStoreCorruptError("orphan local head");
    }

    const checkpointByEpoch = new Map(
      image.checkpoints.map((checkpoint) => [checkpoint.epoch, checkpoint]),
    );
    const outboxOrders = new Set<number>();
    const epochsWithOutbox = new Set<number>();
    let maxCreatedOrder = -1;
    for (const entry of image.outbox) {
      const checkpoint = checkpointByEpoch.get(entry.epoch);
      if (
        !checkpoint ||
        !sameBoundary(image.boundary, entry.boundary) ||
        entry.destination_id.length === 0 ||
        entry.checkpoint_digest !== checkpoint.checkpoint_digest ||
        entry.canonical_envelope !== checkpoint.canonical_envelope ||
        !isNonNegativeInteger(entry.created_order) ||
        outboxOrders.has(entry.created_order) ||
        (entry.state.kind === "in_flight" &&
          !isNonNegativeInteger(entry.state.lease_expires_at_ms))
      ) {
        throw new PlayerLocalStoreCorruptError("invalid outbox relation");
      }
      epochsWithOutbox.add(entry.epoch);
      outboxOrders.add(entry.created_order);
      maxCreatedOrder = Math.max(maxCreatedOrder, entry.created_order);
    }
    if (
      image.checkpoints.some(
        (checkpoint) => !epochsWithOutbox.has(checkpoint.epoch),
      ) ||
      image.next_created_order <= maxCreatedOrder
    ) {
      throw new PlayerLocalStoreCorruptError("incomplete outbox footprint");
    }

    const acknowledgedOutboxKeys = new Set(
      image.outbox
        .filter((entry) => entry.state.kind === "acknowledged")
        .map((entry) =>
          this.outboxAckKey(
            entry.destination_id,
            entry.epoch,
            entry.checkpoint_digest,
          ),
        ),
    );
    const ackKeys = new Set<string>();
    for (const evidence of image.ack_history) {
      const key = this.ackKey(evidence);
      if (!acknowledgedOutboxKeys.has(key) || ackKeys.has(key)) {
        throw new PlayerLocalStoreCorruptError("invalid ACK history");
      }
      ackKeys.add(key);
    }
    for (const entry of image.outbox) {
      if (
        entry.state.kind === "acknowledged" &&
        !ackKeys.has(
          this.outboxAckKey(
            entry.destination_id,
            entry.epoch,
            entry.checkpoint_digest,
          ),
        )
      ) {
        throw new PlayerLocalStoreCorruptError("ACK footprint missing");
      }
    }
  }

  private eventFromRow(
    boundary: AuditBoundary,
    row: EventRow,
  ): PlayerLocalAuditEvent {
    return { boundary, ...row };
  }

  private outboxRecord(
    row: OutboxRow,
    boundary: AuditBoundary,
  ): PlayerLocalCheckpointOutboxRecord {
    let state: CheckpointOutboxState;
    if (row.state === "pending") {
      state = { kind: "pending" };
    } else if (row.state === "acknowledged") {
      state = { kind: "acknowledged" };
    } else {
      if (row.lease_expires_at_ms === null) {
        throw new PlayerLocalStoreCorruptError("in-flight lease missing");
      }
      state = {
        kind: "in_flight",
        lease_expires_at_ms: row.lease_expires_at_ms,
      };
    }
    return {
      boundary,
      destination_id: row.destination_id,
      epoch: row.epoch,
      checkpoint_digest: row.checkpoint_digest,
      canonical_envelope: row.canonical_envelope,
      created_order: row.created_order,
      state,
    };
  }

  private outboxAt(createdOrder: number): OutboxRow | undefined {
    return this.get<OutboxRow>(
      `SELECT destination_id, epoch, checkpoint_digest, canonical_envelope,
              created_order, state, lease_expires_at_ms
       FROM player_local_outbox WHERE created_order = ?`,
      createdOrder,
    );
  }

  private boundary(): AuditBoundary {
    return this.boundaryFromRow(this.configuration());
  }

  private boundaryFromRow(row: ConfigurationRow): AuditBoundary {
    return {
      protocol_version: row.protocol_version,
      purpose: row.purpose,
      manifest_digest: row.manifest_digest,
      scope_id: row.scope_id,
      unit_id: row.unit_id,
    };
  }

  private configuration(): ConfigurationRow {
    const row = this.get<ConfigurationRow>(
      `SELECT protocol_version, purpose, manifest_digest, scope_id, unit_id,
              genesis_digest, outbox_capacity, next_created_order,
              storage_revision
       FROM player_local_config WHERE singleton = 1`,
    );
    if (!row) throw new PlayerLocalStoreCorruptError("missing configuration");
    return row;
  }

  private incrementRevision(): void {
    const changed = this.run(
      `UPDATE player_local_config
       SET storage_revision = storage_revision + 1 WHERE singleton = 1`,
    );
    if (changed !== 1) throw new PlayerLocalStoreCorruptError();
  }

  private count(table: "player_local_outbox"): number {
    return this.get<{ count: number }>(
      `SELECT COUNT(*) AS count FROM ${table}`,
    )?.count ?? 0;
  }

  private ackKey(evidence: CheckpointAckEvidence): string {
    return this.outboxAckKey(
      evidence.authority_id,
      evidence.epoch,
      evidence.checkpoint_digest,
    );
  }

  private outboxAckKey(
    authorityId: string,
    epoch: number,
    checkpointDigest: string,
  ): string {
    return `${authorityId}\u0000${epoch}\u0000${checkpointDigest}`;
  }

  private inject(
    requested: PlayerLocalSealFaultPoint | undefined,
    current: PlayerLocalSealFaultPoint,
  ): void {
    if (requested === current) throw new InjectedPlayerLocalSealFault(current);
  }

  private transaction<T>(operation: () => T): T {
    this.database.exec("BEGIN IMMEDIATE");
    try {
      const result = operation();
      this.database.exec("COMMIT");
      return result;
    } catch (error) {
      this.database.exec("ROLLBACK");
      throw error;
    }
  }

  private get<Row>(sql: string, ...parameters: SQLInputValue[]): Row | undefined {
    return this.database.prepare(sql).get(...parameters) as Row | undefined;
  }

  private all<Row>(sql: string, ...parameters: SQLInputValue[]): Row[] {
    return this.database.prepare(sql).all(...parameters) as Row[];
  }

  private run(sql: string, ...parameters: SQLInputValue[]): number {
    return Number(this.database.prepare(sql).run(...parameters).changes);
  }
}
