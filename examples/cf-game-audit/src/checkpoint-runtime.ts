import {
  acknowledgeCheckpointOutboxSync,
  prepareCheckpointSealSync,
  sameCheckpointDeliveryAuthentication,
  sameCheckpointDeliveryAuthenticationPolicy,
  type AtomicCheckpointSealPreparation,
  type CheckpointAckDecision,
  type CheckpointDeliveryAuthentication,
  type CheckpointDeliveryAuthenticationPolicy,
  type CheckpointRuntimeBoundary,
  type LoadedCheckpointRuntime,
  type StoredCheckpointClosure,
} from "./moonbit";

const CHECKPOINT_OUTBOX_SELECT = `SELECT idempotency_key, destination_id, epoch,
  previous_checkpoint, checkpoint_digest, canonical_envelope, created_order,
  state, attempts, lease_expires_at, last_attempt_at, acknowledged_at,
  ack_decision, created_at FROM checkpoint_outbox`;

interface CheckpointRuntimeConfigRow extends Record<string, SqlStorageValue> {
  protocol_version: number;
  purpose: string;
  manifest_digest: string;
  scope_id: string;
  unit_id: string;
  initial_epoch: number;
  initial_digest: string;
  destinations_json: string;
  outbox_capacity: number;
  next_created_order: number;
}

interface CheckpointHeadRow extends Record<string, SqlStorageValue> {
  epoch: number;
  digest: string;
  updated_at: number;
}

interface CheckpointHistoryRow extends Record<string, SqlStorageValue> {
  epoch: number;
  digest: string;
  previous_digest: string;
  canonical_envelope: string;
  committed_at: number;
}

interface CheckpointClosureRow extends Record<string, SqlStorageValue> {
  epoch: number;
  roster_digest: string;
  frontier_digest: string;
  certificate_digest: string;
  status: "ready" | "consumed";
  consumed_digest: string | null;
  created_at: number;
  consumed_at: number | null;
}

interface CheckpointOutboxRow extends Record<string, SqlStorageValue> {
  idempotency_key: string;
  destination_id: string;
  epoch: number;
  previous_checkpoint: string;
  checkpoint_digest: string;
  canonical_envelope: string;
  created_order: number;
  state: "pending" | "in_flight" | "acknowledged";
  attempts: number;
  lease_expires_at: number | null;
  last_attempt_at: number | null;
  acknowledged_at: number | null;
  ack_decision: "accepted" | "duplicate" | null;
  created_at: number;
}

interface CheckpointOutboxAuthenticationRow
  extends Record<string, SqlStorageValue> {
  idempotency_key: string;
  authentication_json: string;
}

export interface CheckpointDeliveryJob {
  kind: "checkpoint-delivery-v1";
  version: 1;
  idempotency_key: string;
  mode: "pve" | "pvp" | "open";
  unit: string;
  boundary: CheckpointRuntimeBoundary;
  destination_id: string;
  initial_epoch: number;
  initial_digest: string;
  epoch: number;
  previous_checkpoint: string;
  checkpoint_digest: string;
  canonical_envelope: string;
  authentication: CheckpointDeliveryAuthentication;
  created_order: number;
  created_at: number;
  state: "pending" | "in_flight" | "acknowledged";
}

export interface CheckpointDeliveryClaim {
  job: CheckpointDeliveryJob;
  lease_expires_at: number;
}

export type CheckpointOutboxAckStoreResult =
  | { decision: "acknowledged" | "already_acknowledged" }
  | { decision: "refused"; reason: string };

export interface CheckpointOutboxAckEvidence {
  decision: Extract<CheckpointAckDecision, "accepted" | "duplicate">;
  authority_id: string;
  boundary: CheckpointRuntimeBoundary;
  epoch: number;
  checkpoint_digest: string;
}

export interface CheckpointRuntimeConfiguration extends CheckpointRuntimeBoundary {
  initial_epoch: number;
  initial_digest: string;
  outbox_capacity: number;
  destinations: string[];
  authentication_policy: CheckpointDeliveryAuthenticationPolicy;
}

export interface DestinationCheckpointDeliveryAuthentication {
  destination_id: string;
  authentication: CheckpointDeliveryAuthentication;
}

export interface CheckpointSealInput {
  epoch: number;
  previous_checkpoint: string;
  checkpoint_digest: string;
  canonical_envelope: string;
  destinations: string[];
  authentications: DestinationCheckpointDeliveryAuthentication[];
}

export type CheckpointRuntimeConfigureResult =
  | { decision: "configured" }
  | { decision: "duplicate" }
  | { decision: "conflict" };

export type CheckpointClosureStoreResult =
  | { decision: "stored" }
  | { decision: "duplicate" }
  | { decision: "conflict" };

export type CheckpointSealStoreResult =
  | {
    decision: "committed";
    epoch: number;
    digest: string;
    outbox_entries: number;
  }
  | { decision: "duplicate"; epoch: number; digest: string }
  | { decision: "conflict" | "refused"; reason: string };

export type CheckpointSealFaultPoint =
  | "after_history"
  | "after_head"
  | "after_outbox"
  | "after_closure";

export class InjectedCheckpointSealFault extends Error {
  constructor(readonly faultPoint: CheckpointSealFaultPoint) {
    super(`injected checkpoint seal fault: ${faultPoint}`);
  }
}

class CheckpointSealCasConflict extends Error {}

export class CheckpointRuntimeStore {
  constructor(private readonly storage: DurableObjectStorage) {
    this.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS checkpoint_runtime_config (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        protocol_version INTEGER NOT NULL CHECK (protocol_version > 0),
        purpose TEXT NOT NULL CHECK (length(purpose) > 0),
        manifest_digest TEXT NOT NULL CHECK (length(manifest_digest) > 0),
        scope_id TEXT NOT NULL CHECK (length(scope_id) > 0),
        unit_id TEXT NOT NULL CHECK (length(unit_id) > 0),
        initial_epoch INTEGER NOT NULL CHECK (initial_epoch >= -1),
        initial_digest TEXT NOT NULL CHECK (length(initial_digest) > 0),
        destinations_json TEXT NOT NULL CHECK (length(destinations_json) > 0),
        outbox_capacity INTEGER NOT NULL CHECK (outbox_capacity >= 0),
        next_created_order INTEGER NOT NULL CHECK (next_created_order >= 0)
      );
      CREATE TABLE IF NOT EXISTS checkpoint_local_head (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        epoch INTEGER NOT NULL CHECK (epoch >= -1),
        digest TEXT NOT NULL CHECK (length(digest) > 0),
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS checkpoint_history (
        epoch INTEGER PRIMARY KEY CHECK (epoch >= 0),
        digest TEXT NOT NULL CHECK (length(digest) > 0),
        previous_digest TEXT NOT NULL CHECK (length(previous_digest) > 0),
        canonical_envelope TEXT NOT NULL CHECK (length(canonical_envelope) > 0),
        committed_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS checkpoint_closures (
        epoch INTEGER PRIMARY KEY CHECK (epoch >= 0),
        roster_digest TEXT NOT NULL CHECK (length(roster_digest) > 0),
        frontier_digest TEXT NOT NULL CHECK (length(frontier_digest) > 0),
        certificate_digest TEXT NOT NULL CHECK (length(certificate_digest) > 0),
        status TEXT NOT NULL CHECK (status IN ('ready', 'consumed')),
        consumed_digest TEXT,
        created_at INTEGER NOT NULL,
        consumed_at INTEGER,
        CHECK (
          (status = 'ready' AND consumed_digest IS NULL AND consumed_at IS NULL)
          OR
          (status = 'consumed' AND consumed_digest IS NOT NULL AND consumed_at IS NOT NULL)
        )
      );
      CREATE TABLE IF NOT EXISTS checkpoint_outbox (
        idempotency_key TEXT NOT NULL PRIMARY KEY CHECK (length(idempotency_key) > 0),
        destination_id TEXT NOT NULL CHECK (length(destination_id) > 0),
        epoch INTEGER NOT NULL CHECK (epoch >= 0),
        previous_checkpoint TEXT NOT NULL CHECK (length(previous_checkpoint) > 0),
        checkpoint_digest TEXT NOT NULL CHECK (length(checkpoint_digest) > 0),
        canonical_envelope TEXT NOT NULL CHECK (length(canonical_envelope) > 0),
        created_order INTEGER NOT NULL CHECK (created_order >= 0),
        state TEXT NOT NULL CHECK (state IN ('pending', 'in_flight', 'acknowledged')),
        attempts INTEGER NOT NULL CHECK (attempts >= 0),
        lease_expires_at INTEGER,
        last_attempt_at INTEGER,
        acknowledged_at INTEGER,
        ack_decision TEXT CHECK (ack_decision IN ('accepted', 'duplicate')),
        created_at INTEGER NOT NULL,
        UNIQUE (destination_id, epoch, checkpoint_digest),
        UNIQUE (created_order)
      );
      CREATE INDEX IF NOT EXISTS checkpoint_outbox_retry_order
      ON checkpoint_outbox(destination_id, state, attempts, epoch, created_order);
      CREATE TABLE IF NOT EXISTS checkpoint_destination_provisioning (
        destination_id TEXT PRIMARY KEY CHECK (length(destination_id) > 0),
        state TEXT NOT NULL CHECK (state IN ('pending', 'provisioned')),
        provisioned_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS checkpoint_delivery_auth_policy (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        policy_json TEXT NOT NULL CHECK (length(policy_json) > 0)
      );
      CREATE TABLE IF NOT EXISTS checkpoint_outbox_authentication (
        idempotency_key TEXT PRIMARY KEY CHECK (length(idempotency_key) > 0),
        authentication_json TEXT NOT NULL CHECK (length(authentication_json) > 0)
      );
    `);
    this.ensureDestinationProvisioningRows();
  }

  configure(
    value: CheckpointRuntimeConfiguration,
  ): CheckpointRuntimeConfigureResult {
    return this.storage.transactionSync(() => {
      const existing = this.config();
      const head = this.head();
      const existingPolicy = this.authenticationPolicy();
      if (existing || head) {
        if (
          existing &&
          head &&
          existing.protocol_version === value.protocol_version &&
          existing.purpose === value.purpose &&
          existing.manifest_digest === value.manifest_digest &&
          existing.scope_id === value.scope_id &&
          existing.unit_id === value.unit_id &&
          existing.initial_epoch === value.initial_epoch &&
          existing.initial_digest === value.initial_digest &&
          existing.destinations_json === JSON.stringify(value.destinations) &&
          existing.outbox_capacity === value.outbox_capacity &&
          sameCheckpointDeliveryAuthenticationPolicy(
            existingPolicy,
            value.authentication_policy,
          ) &&
          head !== undefined
        ) {
          return { decision: "duplicate" };
        }
        return { decision: "conflict" };
      }
      this.storage.sql.exec(
        `INSERT INTO checkpoint_delivery_auth_policy (singleton, policy_json)
         VALUES (1, ?)`,
        JSON.stringify(value.authentication_policy),
      );
      this.storage.sql.exec(
        `INSERT INTO checkpoint_runtime_config
         (singleton, protocol_version, purpose, manifest_digest, scope_id,
          unit_id, initial_epoch, initial_digest, outbox_capacity,
          destinations_json, next_created_order)
         VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)`,
        value.protocol_version,
        value.purpose,
        value.manifest_digest,
        value.scope_id,
        value.unit_id,
        value.initial_epoch,
        value.initial_digest,
        value.outbox_capacity,
        JSON.stringify(value.destinations),
      );
      for (const destination of value.destinations) {
        this.storage.sql.exec(
          `INSERT INTO checkpoint_destination_provisioning
           (destination_id, state, provisioned_at)
           VALUES (?, 'pending', NULL)`,
          destination,
        );
      }
      this.storage.sql.exec(
        `INSERT INTO checkpoint_local_head
         (singleton, epoch, digest, updated_at) VALUES (1, ?, ?, ?)`,
        value.initial_epoch,
        value.initial_digest,
        Date.now(),
      );
      return { decision: "configured" };
    });
  }

  storeClosure(
    closure: StoredCheckpointClosure,
  ): CheckpointClosureStoreResult {
    return this.storage.transactionSync(() => {
      const existing = this.closureAt(closure.epoch);
      if (existing) {
        return existing.roster_digest === closure.roster_digest &&
            existing.frontier_digest === closure.frontier_digest &&
            existing.certificate_digest === closure.certificate_digest
          ? { decision: "duplicate" }
          : { decision: "conflict" };
      }
      this.storage.sql.exec(
        `INSERT INTO checkpoint_closures
         (epoch, roster_digest, frontier_digest, certificate_digest, status,
          consumed_digest, created_at, consumed_at)
         VALUES (?, ?, ?, ?, 'ready', NULL, ?, NULL)`,
        closure.epoch,
        closure.roster_digest,
        closure.frontier_digest,
        closure.certificate_digest,
        Date.now(),
      );
      return { decision: "stored" };
    });
  }

  seal(
    runtime: LoadedCheckpointRuntime,
    input: CheckpointSealInput,
    faultPoint?: CheckpointSealFaultPoint,
  ): CheckpointSealStoreResult {
    try {
      return this.storage.transactionSync(() => {
        const config = this.config();
        const head = this.head();
        const closure = this.closureAt(input.epoch);
        const known = this.historyAt(input.epoch);
        if (!config || !head) {
          return { decision: "refused", reason: "runtime_not_configured" };
        }
        const configuredDestinations = this.configuredDestinations(config);
        if (!sameDestinationSet(input.destinations, configuredDestinations)) {
          return { decision: "refused", reason: "destination_policy_mismatch" };
        }
        if (!this.allDestinationsProvisioned(configuredDestinations)) {
          return { decision: "refused", reason: "destination_not_provisioned" };
        }
        if (!sameAuthenticationSet(input.authentications, configuredDestinations)) {
          return { decision: "refused", reason: "authentication_policy_mismatch" };
        }
        const effectiveInput = {
          ...input,
          destinations: configuredDestinations,
        };
        if (!closure) {
          return known
            ? { decision: "conflict", reason: "incomplete_known_commit" }
            : { decision: "refused", reason: "closure_not_ready" };
        }
        const knownDigestMatches = known?.digest === input.checkpoint_digest;
        const knownSealComplete = Boolean(
          knownDigestMatches &&
            known?.previous_digest === input.previous_checkpoint &&
            known?.canonical_envelope === input.canonical_envelope &&
            head.epoch >= input.epoch &&
            closure.status === "consumed" &&
            closure.consumed_digest === input.checkpoint_digest &&
            this.requiredOutboxComplete(effectiveInput),
        );
        const preparation = prepareCheckpointSealSync(runtime, {
          boundary: this.boundary(config),
          closure,
          currentEpoch: head.epoch,
          currentDigest: head.digest,
          incomingEpochKnown: known !== undefined,
          knownDigestMatches,
          knownSealComplete,
          closureConsumed: closure.status === "consumed",
          outboxEntryCount: this.outboxCount(),
          outboxCapacity: config.outbox_capacity,
          nextCreatedOrder: config.next_created_order,
          checkpointEpoch: input.epoch,
          previousCheckpoint: input.previous_checkpoint,
          checkpointDigest: input.checkpoint_digest,
          canonicalEnvelope: input.canonical_envelope,
          destinations: effectiveInput.destinations,
        });
        if (preparation.decision === "duplicate") {
          return {
            decision: "duplicate",
            epoch: input.epoch,
            digest: input.checkpoint_digest,
          };
        }
        if (preparation.decision !== "prepared") return preparation;
        this.applyPreparedSeal(
          config,
          head,
          closure,
          effectiveInput,
          preparation,
          faultPoint,
        );
        return {
          decision: "committed",
          epoch: preparation.epoch,
          digest: preparation.digest,
          outbox_entries: preparation.outbox.length,
        };
      });
    } catch (error) {
      if (error instanceof InjectedCheckpointSealFault) throw error;
      if (error instanceof CheckpointSealCasConflict) {
        return { decision: "refused", reason: "storage_snapshot_changed" };
      }
      throw error;
    }
  }

  state(mode: CheckpointDeliveryJob["mode"]): Record<string, unknown> | undefined {
    const config = this.config();
    const head = this.head();
    if (!config || !head) return undefined;
    const entries = this.outboxRows().map((row) => ({
      ...this.deliveryJob(mode, config, row),
      attempts: row.attempts,
      lease_expires_at: row.lease_expires_at,
      last_attempt_at: row.last_attempt_at,
      acknowledged_at: row.acknowledged_at,
      ack_decision: row.ack_decision,
    }));
    return {
      boundary: this.boundary(config),
      head: { epoch: head.epoch, digest: head.digest },
      history: this.historyCount(),
      closures: {
        ready: this.closureCount("ready"),
        consumed: this.closureCount("consumed"),
      },
      outbox: {
        pending: this.outboxStateCount("pending"),
        in_flight: this.outboxStateCount("in_flight"),
        acknowledged: this.outboxStateCount("acknowledged"),
        ack_decisions: {
          accepted: this.outboxAckDecisionCount("accepted"),
          duplicate: this.outboxAckDecisionCount("duplicate"),
        },
        capacity: config.outbox_capacity,
        entries,
      },
      destinations: {
        pending: this.destinationProvisioningCount("pending"),
        provisioned: this.destinationProvisioningCount("provisioned"),
      },
      next_created_order: config.next_created_order,
    };
  }

  markDestinationProvisioned(destinationId: string): boolean {
    return this.storage.transactionSync(() => {
      const config = this.config();
      if (
        !config ||
        !this.configuredDestinations(config).includes(destinationId)
      ) return false;
      const write = this.storage.sql.exec(
        `UPDATE checkpoint_destination_provisioning
         SET state = 'provisioned', provisioned_at = COALESCE(provisioned_at, ?)
         WHERE destination_id = ?`,
        Date.now(),
        destinationId,
      );
      return write.rowsWritten === 1;
    });
  }

  authenticateDelivery(
    mode: CheckpointDeliveryJob["mode"],
    job: CheckpointDeliveryJob,
  ): boolean {
    const config = this.config();
    const row = this.outboxAt(job.idempotency_key);
    return config !== undefined &&
      row !== undefined &&
      job.mode === mode &&
      this.deliveryMatches(row, config, job);
  }

  claimDeliveries(
    mode: CheckpointDeliveryJob["mode"],
    unit: string,
    now: number,
    leaseDurationMs: number,
    limit = 32,
  ): CheckpointDeliveryClaim[] {
    if (now < 0 || leaseDurationMs <= 0 || limit <= 0) return [];
    return this.storage.transactionSync(() => {
      const config = this.config();
      if (!config || config.unit_id !== unit) return [];
      const selected = new Map<string, CheckpointOutboxRow>();
      for (const row of this.storage.sql.exec<CheckpointOutboxRow>(
        `${CHECKPOINT_OUTBOX_SELECT}
         WHERE state = 'pending' AND attempts = 0
         ORDER BY created_order ASC LIMIT ?`,
        limit,
      ).toArray()) {
        selected.set(row.idempotency_key, row);
      }
      if (selected.size < limit) {
        for (const destination of this.configuredDestinations(config)) {
          const row = this.storage.sql.exec<CheckpointOutboxRow>(
            `${CHECKPOINT_OUTBOX_SELECT}
             WHERE destination_id = ? AND attempts > 0 AND (
               state = 'pending' OR
               (state = 'in_flight' AND lease_expires_at <= ?)
             )
             ORDER BY epoch ASC, created_order ASC, checkpoint_digest ASC
             LIMIT 1`,
            destination,
            now,
          ).toArray()[0];
          if (row) selected.set(row.idempotency_key, row);
          if (selected.size >= limit) break;
        }
      }
      const leaseExpiresAt = now + leaseDurationMs;
      if (!Number.isSafeInteger(leaseExpiresAt) || leaseExpiresAt < now) return [];
      const claims: CheckpointDeliveryClaim[] = [];
      for (const row of selected.values()) {
        const claimedJob = this.deliveryJob(mode, config, {
          ...row,
          state: "in_flight",
          attempts: row.attempts + 1,
          lease_expires_at: leaseExpiresAt,
          last_attempt_at: now,
        });
        this.storage.sql.exec(
          `UPDATE checkpoint_outbox
           SET state = 'in_flight', attempts = attempts + 1,
               lease_expires_at = ?, last_attempt_at = ?
           WHERE idempotency_key = ? AND (
             state = 'pending' OR
             (state = 'in_flight' AND lease_expires_at <= ?)
           )`,
          leaseExpiresAt,
          now,
          row.idempotency_key,
          now,
        );
        claims.push({
          job: claimedJob,
          lease_expires_at: leaseExpiresAt,
        });
      }
      return claims;
    });
  }

  releaseDelivery(idempotencyKey: string, leaseExpiresAt: number): boolean {
    return this.storage.transactionSync(() => {
      const write = this.storage.sql.exec(
        `UPDATE checkpoint_outbox
         SET state = 'pending', lease_expires_at = NULL
         WHERE idempotency_key = ? AND state = 'in_flight'
           AND lease_expires_at = ?`,
        idempotencyKey,
        leaseExpiresAt,
      );
      return write.rowsWritten === 1;
    });
  }

  acknowledgeDelivery(
    runtime: LoadedCheckpointRuntime,
    job: CheckpointDeliveryJob,
    ack: CheckpointOutboxAckEvidence,
    authenticationSucceeded: boolean,
  ): CheckpointOutboxAckStoreResult {
    return this.storage.transactionSync(() => {
      const config = this.config();
      const row = this.outboxAt(job.idempotency_key);
      if (!config || !row || !this.deliveryMatches(row, config, job)) {
        return { decision: "refused", reason: "unknown_or_mismatched_delivery" };
      }
      if (row.state === "acknowledged") {
        return { decision: "already_acknowledged" };
      }
      const boundary = this.boundary(config);
      const result = acknowledgeCheckpointOutboxSync(runtime, {
        boundary,
        destinationId: row.destination_id,
        epoch: row.epoch,
        checkpointDigest: row.checkpoint_digest,
        canonicalEnvelope: row.canonical_envelope,
        createdOrder: row.created_order,
        ackBoundary: ack.boundary,
        ackAuthorityId: ack.authority_id,
        ackEpoch: ack.epoch,
        ackCheckpointDigest: ack.checkpoint_digest,
        ackDecision: ack.decision,
        authenticationSucceeded,
      });
      if (result !== "acknowledged") {
        return { decision: "refused", reason: result };
      }
      const write = this.storage.sql.exec(
        `UPDATE checkpoint_outbox
         SET state = 'acknowledged', lease_expires_at = NULL,
             acknowledged_at = ?, ack_decision = ?
         WHERE idempotency_key = ? AND state != 'acknowledged'`,
        Date.now(),
        ack.decision,
        job.idempotency_key,
      );
      return write.rowsWritten === 1
        ? { decision: "acknowledged" }
        : { decision: "already_acknowledged" };
    });
  }

  nextDeliveryRetryAt(): number | undefined {
    const pending = this.storage.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM checkpoint_outbox WHERE state = 'pending'",
    ).toArray()[0]?.count ?? 0;
    if (pending > 0) return Date.now();
    return this.storage.sql.exec<{ retry_at: number | null }>(
      `SELECT MIN(lease_expires_at) AS retry_at FROM checkpoint_outbox
       WHERE state = 'in_flight'`,
    ).toArray()[0]?.retry_at ?? undefined;
  }

  config(): CheckpointRuntimeConfigRow | undefined {
    return this.storage.sql.exec<CheckpointRuntimeConfigRow>(
      `SELECT protocol_version, purpose, manifest_digest, scope_id, unit_id,
              initial_epoch, initial_digest, destinations_json, outbox_capacity,
              next_created_order
       FROM checkpoint_runtime_config WHERE singleton = 1`,
    ).toArray()[0];
  }

  authenticationPolicy(): CheckpointDeliveryAuthenticationPolicy | undefined {
    const row = this.storage.sql.exec<{ policy_json: string }>(
      `SELECT policy_json FROM checkpoint_delivery_auth_policy WHERE singleton = 1`,
    ).toArray()[0];
    return row
      ? JSON.parse(row.policy_json) as CheckpointDeliveryAuthenticationPolicy
      : undefined;
  }

  private applyPreparedSeal(
    config: CheckpointRuntimeConfigRow,
    head: CheckpointHeadRow,
    closure: CheckpointClosureRow,
    input: CheckpointSealInput,
    preparation: Extract<AtomicCheckpointSealPreparation, { decision: "prepared" }>,
    faultPoint?: CheckpointSealFaultPoint,
  ): void {
    const now = Date.now();
    this.storage.sql.exec(
      `INSERT INTO checkpoint_history
       (epoch, digest, previous_digest, canonical_envelope, committed_at)
       VALUES (?, ?, ?, ?, ?)`,
      input.epoch,
      input.checkpoint_digest,
      input.previous_checkpoint,
      input.canonical_envelope,
      now,
    );
    this.inject(faultPoint, "after_history");
    const headWrite = this.storage.sql.exec(
      `UPDATE checkpoint_local_head
       SET epoch = ?, digest = ?, updated_at = ?
       WHERE singleton = 1 AND epoch = ? AND digest = ?`,
      preparation.epoch,
      preparation.digest,
      now,
      head.epoch,
      head.digest,
    );
    if (headWrite.rowsWritten !== 1) throw new CheckpointSealCasConflict();
    this.inject(faultPoint, "after_head");
    for (const entry of preparation.outbox) {
      const idempotencyKey = checkpointDeliveryIdempotencyKey(
        this.boundary(config),
        entry.destination_id,
        entry.epoch,
        entry.checkpoint_digest,
      );
      this.storage.sql.exec(
        `INSERT INTO checkpoint_outbox
         (idempotency_key, destination_id, epoch, previous_checkpoint,
          checkpoint_digest, canonical_envelope, created_order, state, attempts,
          lease_expires_at, last_attempt_at, acknowledged_at, ack_decision,
          created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, NULL, NULL, NULL, NULL, ?)`,
        idempotencyKey,
        entry.destination_id,
        entry.epoch,
        input.previous_checkpoint,
        entry.checkpoint_digest,
        entry.canonical_envelope,
        entry.created_order,
        now,
      );
      const authentication = input.authentications.find(
        (value) => value.destination_id === entry.destination_id,
      );
      if (!authentication) throw new CheckpointSealCasConflict();
      this.storage.sql.exec(
        `INSERT INTO checkpoint_outbox_authentication
         (idempotency_key, authentication_json) VALUES (?, ?)`,
        idempotencyKey,
        JSON.stringify(authentication.authentication),
      );
    }
    this.inject(faultPoint, "after_outbox");
    const closureWrite = this.storage.sql.exec(
      `UPDATE checkpoint_closures
       SET status = 'consumed', consumed_digest = ?, consumed_at = ?
       WHERE epoch = ? AND status = 'ready' AND roster_digest = ?
         AND frontier_digest = ? AND certificate_digest = ?`,
      preparation.digest,
      now,
      closure.epoch,
      closure.roster_digest,
      closure.frontier_digest,
      closure.certificate_digest,
    );
    if (closureWrite.rowsWritten !== 1) throw new CheckpointSealCasConflict();
    this.inject(faultPoint, "after_closure");
    const configWrite = this.storage.sql.exec(
      `UPDATE checkpoint_runtime_config SET next_created_order = ?
       WHERE singleton = 1 AND next_created_order = ?`,
      preparation.next_created_order,
      config.next_created_order,
    );
    if (configWrite.rowsWritten !== 1) throw new CheckpointSealCasConflict();
  }

  private inject(
    requested: CheckpointSealFaultPoint | undefined,
    current: CheckpointSealFaultPoint,
  ): void {
    if (requested === current) throw new InjectedCheckpointSealFault(current);
  }

  private boundary(config: CheckpointRuntimeConfigRow): CheckpointRuntimeBoundary {
    return {
      protocol_version: config.protocol_version,
      purpose: config.purpose,
      manifest_digest: config.manifest_digest,
      scope_id: config.scope_id,
      unit_id: config.unit_id,
    };
  }

  private head(): CheckpointHeadRow | undefined {
    return this.storage.sql.exec<CheckpointHeadRow>(
      `SELECT epoch, digest, updated_at
       FROM checkpoint_local_head WHERE singleton = 1`,
    ).toArray()[0];
  }

  private historyAt(epoch: number): CheckpointHistoryRow | undefined {
    return this.storage.sql.exec<CheckpointHistoryRow>(
      `SELECT epoch, digest, previous_digest, canonical_envelope, committed_at
       FROM checkpoint_history WHERE epoch = ?`,
      epoch,
    ).toArray()[0];
  }

  private outboxAt(idempotencyKey: string): CheckpointOutboxRow | undefined {
    return this.storage.sql.exec<CheckpointOutboxRow>(
      `${CHECKPOINT_OUTBOX_SELECT} WHERE idempotency_key = ?`,
      idempotencyKey,
    ).toArray()[0];
  }

  private outboxRows(): CheckpointOutboxRow[] {
    return this.storage.sql.exec<CheckpointOutboxRow>(
      `${CHECKPOINT_OUTBOX_SELECT} ORDER BY created_order ASC`,
    ).toArray();
  }

  private deliveryJob(
    mode: CheckpointDeliveryJob["mode"],
    config: CheckpointRuntimeConfigRow,
    row: CheckpointOutboxRow,
  ): CheckpointDeliveryJob {
    const authentication = this.outboxAuthentication(row.idempotency_key);
    if (!authentication) throw new CheckpointSealCasConflict();
    return {
      kind: "checkpoint-delivery-v1",
      version: 1,
      idempotency_key: row.idempotency_key,
      mode,
      unit: config.unit_id,
      boundary: this.boundary(config),
      destination_id: row.destination_id,
      initial_epoch: config.initial_epoch,
      initial_digest: config.initial_digest,
      epoch: row.epoch,
      previous_checkpoint: row.previous_checkpoint,
      checkpoint_digest: row.checkpoint_digest,
      canonical_envelope: row.canonical_envelope,
      authentication,
      created_order: row.created_order,
      created_at: row.created_at,
      state: row.state,
    };
  }

  private deliveryMatches(
    row: CheckpointOutboxRow,
    config: CheckpointRuntimeConfigRow,
    job: CheckpointDeliveryJob,
  ): boolean {
    const boundary = this.boundary(config);
    return job.kind === "checkpoint-delivery-v1" &&
      job.version === 1 &&
      job.idempotency_key === row.idempotency_key &&
      job.idempotency_key === checkpointDeliveryIdempotencyKey(
        boundary,
        row.destination_id,
        row.epoch,
        row.checkpoint_digest,
      ) &&
      job.unit === config.unit_id &&
      sameBoundary(job.boundary, boundary) &&
      job.destination_id === row.destination_id &&
      job.initial_epoch === config.initial_epoch &&
      job.initial_digest === config.initial_digest &&
      job.epoch === row.epoch &&
      job.previous_checkpoint === row.previous_checkpoint &&
      job.checkpoint_digest === row.checkpoint_digest &&
      job.canonical_envelope === row.canonical_envelope &&
      sameCheckpointDeliveryAuthentication(
        job.authentication,
        this.outboxAuthentication(row.idempotency_key),
      ) &&
      job.created_order === row.created_order &&
      job.created_at === row.created_at;
  }

  private closureAt(epoch: number): CheckpointClosureRow | undefined {
    return this.storage.sql.exec<CheckpointClosureRow>(
      `SELECT epoch, roster_digest, frontier_digest, certificate_digest,
              status, consumed_digest, created_at, consumed_at
       FROM checkpoint_closures WHERE epoch = ?`,
      epoch,
    ).toArray()[0];
  }

  private requiredOutboxComplete(input: CheckpointSealInput): boolean {
    if (new Set(input.destinations).size !== input.destinations.length) return false;
    return input.destinations.every((destination) => {
      const row = this.storage.sql.exec<CheckpointOutboxRow>(
        `${CHECKPOINT_OUTBOX_SELECT}
         WHERE destination_id = ? AND epoch = ? AND checkpoint_digest = ?`,
        destination,
        input.epoch,
        input.checkpoint_digest,
      ).toArray()[0];
      const expected = input.authentications.find(
        (value) => value.destination_id === destination,
      )?.authentication;
      return row?.canonical_envelope === input.canonical_envelope &&
        expected !== undefined &&
        sameCheckpointDeliveryAuthentication(
          this.outboxAuthentication(row.idempotency_key),
          expected,
        );
    });
  }

  private outboxAuthentication(
    idempotencyKey: string,
  ): CheckpointDeliveryAuthentication | undefined {
    const row = this.storage.sql.exec<CheckpointOutboxAuthenticationRow>(
      `SELECT idempotency_key, authentication_json
       FROM checkpoint_outbox_authentication WHERE idempotency_key = ?`,
      idempotencyKey,
    ).toArray()[0];
    return row
      ? JSON.parse(row.authentication_json) as CheckpointDeliveryAuthentication
      : undefined;
  }

  private configuredDestinations(
    config: CheckpointRuntimeConfigRow,
  ): string[] {
    const value: unknown = JSON.parse(config.destinations_json);
    if (
      !Array.isArray(value) ||
      value.length === 0 ||
      !value.every((item) => typeof item === "string")
    ) {
      throw new CheckpointSealCasConflict("invalid configured destinations");
    }
    return value;
  }

  private historyCount(): number {
    return this.count("checkpoint_history");
  }

  private outboxCount(): number {
    return this.count("checkpoint_outbox");
  }

  private count(
    table: "checkpoint_history" | "checkpoint_outbox",
  ): number {
    return this.storage.sql.exec<{ count: number }>(
      `SELECT COUNT(*) AS count FROM ${table}`,
    ).toArray()[0]?.count ?? 0;
  }

  private closureCount(status: CheckpointClosureRow["status"]): number {
    return this.storage.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM checkpoint_closures WHERE status = ?",
      status,
    ).toArray()[0]?.count ?? 0;
  }

  private ensureDestinationProvisioningRows(): void {
    const config = this.config();
    if (!config) return;
    for (const destination of this.configuredDestinations(config)) {
      this.storage.sql.exec(
        `INSERT OR IGNORE INTO checkpoint_destination_provisioning
         (destination_id, state, provisioned_at)
         VALUES (?, 'pending', NULL)`,
        destination,
      );
    }
  }

  private allDestinationsProvisioned(destinations: string[]): boolean {
    return destinations.every((destination) =>
      this.storage.sql.exec<{ state: string }>(
        `SELECT state FROM checkpoint_destination_provisioning
         WHERE destination_id = ?`,
        destination,
      ).toArray()[0]?.state === "provisioned"
    );
  }

  private destinationProvisioningCount(
    state: "pending" | "provisioned",
  ): number {
    return this.storage.sql.exec<{ count: number }>(
      `SELECT COUNT(*) AS count FROM checkpoint_destination_provisioning
       WHERE state = ?`,
      state,
    ).toArray()[0]?.count ?? 0;
  }

  private outboxStateCount(state: CheckpointOutboxRow["state"]): number {
    return this.storage.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM checkpoint_outbox WHERE state = ?",
      state,
    ).toArray()[0]?.count ?? 0;
  }

  private outboxAckDecisionCount(
    decision: Exclude<CheckpointOutboxRow["ack_decision"], null>,
  ): number {
    return this.storage.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM checkpoint_outbox WHERE ack_decision = ?",
      decision,
    ).toArray()[0]?.count ?? 0;
  }
}

function sameDestinationSet(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false;
  const normalized = [...left].sort();
  return normalized.every((value, index) => value === right[index]);
}

function sameAuthenticationSet(
  values: DestinationCheckpointDeliveryAuthentication[],
  destinations: string[],
): boolean {
  if (values.length !== destinations.length) return false;
  const normalized = values.map((value) => value.destination_id).sort();
  return new Set(normalized).size === normalized.length &&
    normalized.every((value, index) => value === destinations[index]);
}

export function checkpointDeliveryIdempotencyKey(
  boundary: CheckpointRuntimeBoundary,
  destinationId: string,
  epoch: number,
  checkpointDigest: string,
): string {
  return JSON.stringify([
    "checkpoint-delivery-v1",
    boundary.protocol_version,
    boundary.purpose,
    boundary.manifest_digest,
    boundary.scope_id,
    boundary.unit_id,
    destinationId,
    epoch,
    checkpointDigest,
  ]);
}

function sameBoundary(
  left: CheckpointRuntimeBoundary,
  right: CheckpointRuntimeBoundary,
): boolean {
  return left.protocol_version === right.protocol_version &&
    left.purpose === right.purpose &&
    left.manifest_digest === right.manifest_digest &&
    left.scope_id === right.scope_id &&
    left.unit_id === right.unit_id;
}
