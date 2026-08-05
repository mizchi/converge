import type { CheckpointDeliveryJob } from "./checkpoint-runtime";
import {
  classifyAnchorHead,
  sameCheckpointDeliveryAuthenticationPolicy,
  verifyCheckpointDeliveryAuthenticationSync,
  type CheckpointAckDecision,
  type CheckpointDeliveryAuthenticationPolicy,
  type CheckpointDeliveryAuthenticationVerification,
  type CheckpointRuntimeBoundary,
  type LoadedCheckpointRuntime,
} from "./moonbit";

const authenticatedCheckpointDelivery = Symbol("authenticated-checkpoint-delivery");

interface AuthenticatedCheckpointDelivery {
  job: CheckpointDeliveryJob;
  producer_id: string;
  approval_count: number;
  [authenticatedCheckpointDelivery]: true;
}

export type CheckpointReceiverAuthenticationResult =
  | { decision: "not_configured" }
  | {
    decision: "refused";
    verification: Extract<CheckpointDeliveryAuthenticationVerification, { ok: false }>;
  }
  | { decision: "authenticated"; delivery: AuthenticatedCheckpointDelivery };

interface ReceiverConfigRow extends Record<string, SqlStorageValue> {
  protocol_version: number;
  purpose: string;
  manifest_digest: string;
  scope_id: string;
  unit_id: string;
  destination_id: string;
  initial_epoch: number;
  initial_digest: string;
}

interface ReceiverHeadRow extends Record<string, SqlStorageValue> {
  epoch: number;
  digest: string;
}

interface ReceiverHistoryRow extends Record<string, SqlStorageValue> {
  epoch: number;
  digest: string;
  previous_digest: string;
  canonical_envelope: string;
}

export interface CheckpointAuthorityAck {
  decision: CheckpointAckDecision;
  authority_id: string;
  boundary: CheckpointRuntimeBoundary;
  epoch: number;
  checkpoint_digest: string;
}

export interface CheckpointReceiverConfiguration {
  boundary: CheckpointRuntimeBoundary;
  destination_id: string;
  initial_epoch: number;
  initial_digest: string;
  authentication_policy: CheckpointDeliveryAuthenticationPolicy;
}

export type CheckpointReceiverConfigureResult =
  | { decision: "configured" | "duplicate" }
  | { decision: "conflict" };

export class CheckpointReceiverStore {
  constructor(private readonly storage: DurableObjectStorage) {
    this.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS checkpoint_receiver_config (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        protocol_version INTEGER NOT NULL CHECK (protocol_version > 0),
        purpose TEXT NOT NULL CHECK (length(purpose) > 0),
        manifest_digest TEXT NOT NULL CHECK (length(manifest_digest) > 0),
        scope_id TEXT NOT NULL CHECK (length(scope_id) > 0),
        unit_id TEXT NOT NULL CHECK (length(unit_id) > 0),
        destination_id TEXT NOT NULL CHECK (length(destination_id) > 0),
        initial_epoch INTEGER NOT NULL CHECK (initial_epoch >= -1),
        initial_digest TEXT NOT NULL CHECK (length(initial_digest) > 0)
      );
      CREATE TABLE IF NOT EXISTS checkpoint_receiver_head (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        epoch INTEGER NOT NULL CHECK (epoch >= -1),
        digest TEXT NOT NULL CHECK (length(digest) > 0),
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS checkpoint_receiver_history (
        epoch INTEGER PRIMARY KEY CHECK (epoch >= 0),
        digest TEXT NOT NULL CHECK (length(digest) > 0),
        previous_digest TEXT NOT NULL CHECK (length(previous_digest) > 0),
        canonical_envelope TEXT NOT NULL CHECK (length(canonical_envelope) > 0),
        committed_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS checkpoint_receiver_forks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL CHECK (kind IN ('same_epoch_fork', 'parent_fork')),
        observed_epoch INTEGER NOT NULL,
        observed_digest TEXT NOT NULL,
        observed_previous_digest TEXT NOT NULL,
        canonical_envelope TEXT NOT NULL,
        observed_at INTEGER NOT NULL,
        UNIQUE(kind, observed_epoch, observed_digest)
      );
      CREATE TABLE IF NOT EXISTS checkpoint_receiver_auth_policy (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        policy_json TEXT NOT NULL CHECK (length(policy_json) > 0)
      );
    `);
  }

  configure(
    value: CheckpointReceiverConfiguration,
  ): CheckpointReceiverConfigureResult {
    return this.storage.transactionSync(() => {
      const existing = this.config();
      const head = this.head();
      const existingPolicy = this.authenticationPolicy();
      if (existing || head) {
        return existing &&
            head &&
            receiverConfigEquals(existing, value) &&
            sameCheckpointDeliveryAuthenticationPolicy(
              existingPolicy,
              value.authentication_policy,
            ) &&
            head.epoch >= value.initial_epoch
          ? { decision: "duplicate" }
          : { decision: "conflict" };
      }
      this.storage.sql.exec(
        `INSERT INTO checkpoint_receiver_auth_policy (singleton, policy_json)
         VALUES (1, ?)`,
        JSON.stringify(value.authentication_policy),
      );
      this.storage.sql.exec(
        `INSERT INTO checkpoint_receiver_config
         (singleton, protocol_version, purpose, manifest_digest, scope_id,
          unit_id, destination_id, initial_epoch, initial_digest)
         VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)`,
        value.boundary.protocol_version,
        value.boundary.purpose,
        value.boundary.manifest_digest,
        value.boundary.scope_id,
        value.boundary.unit_id,
        value.destination_id,
        value.initial_epoch,
        value.initial_digest,
      );
      this.storage.sql.exec(
        `INSERT INTO checkpoint_receiver_head
         (singleton, epoch, digest, updated_at) VALUES (1, ?, ?, ?)`,
        value.initial_epoch,
        value.initial_digest,
        Date.now(),
      );
      return { decision: "configured" };
    });
  }

  authenticate(
    runtime: LoadedCheckpointRuntime,
    job: CheckpointDeliveryJob,
  ): CheckpointReceiverAuthenticationResult {
    const policy = this.authenticationPolicy();
    if (!this.config() || !policy) return { decision: "not_configured" };
    const verification = verifyCheckpointDeliveryAuthenticationSync(runtime, {
      boundary: job.boundary,
      destinationId: job.destination_id,
      epoch: job.epoch,
      previousCheckpoint: job.previous_checkpoint,
      checkpointDigest: job.checkpoint_digest,
      canonicalEnvelope: job.canonical_envelope,
      policy,
      authentication: job.authentication,
    });
    if (!verification.ok) return { decision: "refused", verification };
    return {
      decision: "authenticated",
      delivery: {
        job,
        producer_id: verification.producer_id,
        approval_count: verification.approval_count,
        [authenticatedCheckpointDelivery]: true,
      },
    };
  }

  receive(
    delivery: AuthenticatedCheckpointDelivery,
  ): CheckpointAuthorityAck | undefined {
    const job = delivery.job;
    return this.storage.transactionSync(() => {
      const config = this.config();
      if (!config) return undefined;
      const boundaryMatches = receiverConfigMatches(config, job);
      const known = this.historyAt(job.epoch);
      const exactKnown = known !== undefined &&
        known.digest === job.checkpoint_digest &&
        known.previous_digest === job.previous_checkpoint &&
        known.canonical_envelope === job.canonical_envelope;
      const head = this.head();
      if (!head) throw new Error("checkpoint receiver head is missing");
      const classified = classifyAnchorHead({
        boundaryMatches,
        epochKnown: known !== undefined,
        knownDigestMatches: exactKnown,
        currentEpoch: head.epoch,
        incomingEpoch: job.epoch,
        parentMatches: job.previous_checkpoint === head.digest,
      });
      const decision = receiverDecision(classified);
      if (decision === "accepted") {
        const now = Date.now();
        this.storage.sql.exec(
          `INSERT INTO checkpoint_receiver_history
           (epoch, digest, previous_digest, canonical_envelope, committed_at)
           VALUES (?, ?, ?, ?, ?)`,
          job.epoch,
          job.checkpoint_digest,
          job.previous_checkpoint,
          job.canonical_envelope,
          now,
        );
        const write = this.storage.sql.exec(
          `UPDATE checkpoint_receiver_head SET epoch = ?, digest = ?, updated_at = ?
           WHERE singleton = 1 AND epoch = ? AND digest = ?`,
          job.epoch,
          job.checkpoint_digest,
          now,
          head.epoch,
          head.digest,
        );
        if (write.rowsWritten !== 1) {
          throw new Error("checkpoint receiver head CAS failed");
        }
      } else if (decision === "same_epoch_fork" || decision === "parent_fork") {
        this.storage.sql.exec(
          `INSERT OR IGNORE INTO checkpoint_receiver_forks
           (kind, observed_epoch, observed_digest, observed_previous_digest,
            canonical_envelope, observed_at)
           VALUES (?, ?, ?, ?, ?, ?)`,
          decision,
          job.epoch,
          job.checkpoint_digest,
          job.previous_checkpoint,
          job.canonical_envelope,
          Date.now(),
        );
      }
      return {
        decision,
        authority_id: config.destination_id,
        boundary: receiverBoundary(config),
        epoch: job.epoch,
        checkpoint_digest: job.checkpoint_digest,
      };
    });
  }

  private config(): ReceiverConfigRow | undefined {
    return this.storage.sql.exec<ReceiverConfigRow>(
      `SELECT protocol_version, purpose, manifest_digest, scope_id, unit_id,
              destination_id, initial_epoch, initial_digest
       FROM checkpoint_receiver_config WHERE singleton = 1`,
    ).toArray()[0];
  }

  private authenticationPolicy():
    | CheckpointDeliveryAuthenticationPolicy
    | undefined {
    const row = this.storage.sql.exec<{ policy_json: string }>(
      `SELECT policy_json FROM checkpoint_receiver_auth_policy WHERE singleton = 1`,
    ).toArray()[0];
    return row
      ? JSON.parse(row.policy_json) as CheckpointDeliveryAuthenticationPolicy
      : undefined;
  }

  private head(): ReceiverHeadRow | undefined {
    return this.storage.sql.exec<ReceiverHeadRow>(
      "SELECT epoch, digest FROM checkpoint_receiver_head WHERE singleton = 1",
    ).toArray()[0];
  }

  private historyAt(epoch: number): ReceiverHistoryRow | undefined {
    return this.storage.sql.exec<ReceiverHistoryRow>(
      `SELECT epoch, digest, previous_digest, canonical_envelope
       FROM checkpoint_receiver_history WHERE epoch = ?`,
      epoch,
    ).toArray()[0];
  }
}

function receiverConfigEquals(
  config: ReceiverConfigRow,
  value: CheckpointReceiverConfiguration,
): boolean {
  const boundary = receiverBoundary(config);
  return boundary.protocol_version === value.boundary.protocol_version &&
    boundary.purpose === value.boundary.purpose &&
    boundary.manifest_digest === value.boundary.manifest_digest &&
    boundary.scope_id === value.boundary.scope_id &&
    boundary.unit_id === value.boundary.unit_id &&
    config.destination_id === value.destination_id &&
    config.initial_epoch === value.initial_epoch &&
    config.initial_digest === value.initial_digest;
}

function receiverBoundary(config: ReceiverConfigRow): CheckpointRuntimeBoundary {
  return {
    protocol_version: config.protocol_version,
    purpose: config.purpose,
    manifest_digest: config.manifest_digest,
    scope_id: config.scope_id,
    unit_id: config.unit_id,
  };
}

function receiverConfigMatches(
  config: ReceiverConfigRow,
  job: CheckpointDeliveryJob,
): boolean {
  const boundary = receiverBoundary(config);
  return boundary.protocol_version === job.boundary.protocol_version &&
    boundary.purpose === job.boundary.purpose &&
    boundary.manifest_digest === job.boundary.manifest_digest &&
    boundary.scope_id === job.boundary.scope_id &&
    boundary.unit_id === job.boundary.unit_id &&
    config.destination_id === job.destination_id &&
    config.initial_epoch === job.initial_epoch &&
    config.initial_digest === job.initial_digest;
}

function receiverDecision(
  decision:
    | "advance"
    | "duplicate"
    | "same_epoch_fork"
    | "wrong_parent_fork"
    | "gap"
    | "stale"
    | "boundary_rejected",
): CheckpointAckDecision {
  switch (decision) {
    case "advance":
      return "accepted";
    case "duplicate":
      return "duplicate";
    case "wrong_parent_fork":
      return "parent_fork";
    case "stale":
      return "stale_unknown";
    case "boundary_rejected":
      return "boundary_mismatch";
    default:
      return decision;
  }
}
