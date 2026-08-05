import {
  sameCheckpointDeliveryApproval,
  sameCheckpointDeliveryAuthentication,
  verifyCheckpointDeliveryAuthenticationSync,
  type CheckpointDeliveryApproval,
  type CheckpointDeliveryAuthentication,
  type CheckpointDeliveryAuthenticationPolicy,
  type CheckpointRuntimeBoundary,
  type LoadedCheckpointRuntime,
} from "./moonbit";

export interface CheckpointWitnessStatement {
  boundary: CheckpointRuntimeBoundary;
  destination_id: string;
  epoch: number;
  previous_checkpoint: string;
  checkpoint_digest: string;
  canonical_envelope: string;
}

export interface CheckpointWitnessCollectionStart {
  statement: CheckpointWitnessStatement;
  producer_authentication: CheckpointDeliveryAuthentication;
  deadline_at: number;
}

export interface CheckpointWitnessCollection {
  collection_id: string;
  statement: CheckpointWitnessStatement;
  producer_authentication: CheckpointDeliveryAuthentication;
  status: "collecting" | "ready" | "expired";
  approval_count: number;
  required_approvals: number;
  deadline_at: number;
  created_at: number;
  ready_at: number | null;
}

export type CheckpointWitnessCollectionStartResult =
  | {
    decision: "started" | "duplicate";
    collection: CheckpointWitnessCollection;
  }
  | { decision: "conflict" }
  | { decision: "refused"; reason: string };

export type CheckpointWitnessApprovalResult =
  | {
    decision: "accepted" | "duplicate";
    collection: CheckpointWitnessCollection;
  }
  | {
    decision: "refused" | "conflict";
    reason: string;
    approval_count: number;
  }
  | { decision: "unknown" };

export type ReadyCheckpointWitnessAuthentication =
  | { ok: true; authentication: CheckpointDeliveryAuthentication }
  | { ok: false; reason: string };

export type CheckpointWitnessSubmissionAdmission =
  | { decision: "allowed" }
  | { decision: "limited"; retry_after_ms: number }
  | { decision: "unknown" };

const WITNESS_SUBMISSION_WINDOW_MS = 1_000;
const WITNESS_SUBMISSIONS_PER_WINDOW = 8;

interface CollectionRow extends Record<string, SqlStorageValue> {
  collection_id: string;
  boundary_json: string;
  destination_id: string;
  epoch: number;
  previous_checkpoint: string;
  checkpoint_digest: string;
  canonical_envelope: string;
  producer_authentication_json: string;
  status: "collecting" | "ready" | "expired";
  deadline_at: number;
  created_at: number;
  ready_at: number | null;
}

interface ApprovalRow extends Record<string, SqlStorageValue> {
  witness_id: string;
  approval_json: string;
}

interface SourceWindowRow extends Record<string, SqlStorageValue> {
  window_started_at: number;
  attempts: number;
}

export class CheckpointWitnessCollectionStore {
  constructor(private readonly storage: DurableObjectStorage) {
    this.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS checkpoint_witness_collections (
        collection_id TEXT PRIMARY KEY CHECK (length(collection_id) > 0),
        boundary_json TEXT NOT NULL CHECK (length(boundary_json) > 0),
        destination_id TEXT NOT NULL CHECK (length(destination_id) > 0),
        epoch INTEGER NOT NULL CHECK (epoch >= 0),
        previous_checkpoint TEXT NOT NULL CHECK (length(previous_checkpoint) > 0),
        checkpoint_digest TEXT NOT NULL CHECK (length(checkpoint_digest) > 0),
        canonical_envelope TEXT NOT NULL CHECK (length(canonical_envelope) > 0),
        producer_authentication_json TEXT NOT NULL
          CHECK (length(producer_authentication_json) > 0),
        status TEXT NOT NULL CHECK (status IN ('collecting', 'ready', 'expired')),
        deadline_at INTEGER NOT NULL CHECK (deadline_at >= 0),
        created_at INTEGER NOT NULL CHECK (created_at >= 0),
        ready_at INTEGER,
        CHECK (
          (status = 'ready' AND ready_at IS NOT NULL)
          OR
          (status != 'ready' AND ready_at IS NULL)
        )
      );
      CREATE TABLE IF NOT EXISTS checkpoint_witness_approvals (
        collection_id TEXT NOT NULL,
        witness_id TEXT NOT NULL CHECK (length(witness_id) > 0),
        approval_json TEXT NOT NULL CHECK (length(approval_json) > 0),
        accepted_at INTEGER NOT NULL CHECK (accepted_at >= 0),
        PRIMARY KEY (collection_id, witness_id)
      );
      CREATE TABLE IF NOT EXISTS checkpoint_witness_conflicts (
        collection_id TEXT NOT NULL,
        witness_id TEXT NOT NULL CHECK (length(witness_id) > 0),
        first_approval_json TEXT NOT NULL,
        conflicting_approval_json TEXT NOT NULL,
        observed_at INTEGER NOT NULL CHECK (observed_at >= 0),
        PRIMARY KEY (collection_id, witness_id, conflicting_approval_json)
      );
      CREATE TABLE IF NOT EXISTS checkpoint_witness_source_windows (
        collection_id TEXT NOT NULL,
        source_bucket TEXT NOT NULL CHECK (length(source_bucket) = 64),
        window_started_at INTEGER NOT NULL CHECK (window_started_at >= 0),
        attempts INTEGER NOT NULL CHECK (attempts > 0),
        PRIMARY KEY (collection_id, source_bucket)
      );
    `);
  }

  reserveSubmission(
    collectionId: string,
    sourceBucket: string,
    now: number,
  ): CheckpointWitnessSubmissionAdmission {
    return this.storage.transactionSync(() => {
      if (!this.row(collectionId)) return { decision: "unknown" };
      const current = this.storage.sql.exec<SourceWindowRow>(
        `SELECT window_started_at, attempts
         FROM checkpoint_witness_source_windows
         WHERE collection_id = ? AND source_bucket = ?`,
        collectionId,
        sourceBucket,
      ).toArray()[0];
      if (
        !current ||
        now < current.window_started_at ||
        now - current.window_started_at >= WITNESS_SUBMISSION_WINDOW_MS
      ) {
        this.storage.sql.exec(
          `INSERT INTO checkpoint_witness_source_windows
           (collection_id, source_bucket, window_started_at, attempts)
           VALUES (?, ?, ?, 1)
           ON CONFLICT(collection_id, source_bucket) DO UPDATE SET
             window_started_at = excluded.window_started_at,
             attempts = 1`,
          collectionId,
          sourceBucket,
          now,
        );
        return { decision: "allowed" };
      }
      if (current.attempts >= WITNESS_SUBMISSIONS_PER_WINDOW) {
        return {
          decision: "limited",
          retry_after_ms: Math.max(
            1,
            current.window_started_at + WITNESS_SUBMISSION_WINDOW_MS - now,
          ),
        };
      }
      this.storage.sql.exec(
        `UPDATE checkpoint_witness_source_windows
         SET attempts = attempts + 1
         WHERE collection_id = ? AND source_bucket = ?
           AND window_started_at = ? AND attempts = ?`,
        collectionId,
        sourceBucket,
        current.window_started_at,
        current.attempts,
      );
      return { decision: "allowed" };
    });
  }

  start(
    runtime: LoadedCheckpointRuntime,
    input: CheckpointWitnessCollectionStart,
    policy: CheckpointDeliveryAuthenticationPolicy,
    now: number,
  ): CheckpointWitnessCollectionStartResult {
    if (
      input.producer_authentication.approvals.length !== 0 ||
      input.deadline_at <= now ||
      !Number.isSafeInteger(input.deadline_at)
    ) return { decision: "refused", reason: "invalid_collection_start" };
    const verification = verifyDelivery(
      runtime,
      input.statement,
      policy,
      input.producer_authentication,
    );
    if (verification.ok || verification.error !== "under_quorum") {
      return {
        decision: "refused",
        reason: verification.ok
          ? "producer_authentication_must_not_include_approvals"
          : verification.error,
      };
    }
    const collectionId = checkpointWitnessCollectionId(input.statement);
    return this.storage.transactionSync(() => {
      const existing = this.row(collectionId);
      if (existing) {
        return collectionStartMatches(existing, input)
          ? {
            decision: "duplicate",
            collection: this.collection(existing, policy),
          }
          : { decision: "conflict" };
      }
      this.storage.sql.exec(
        `INSERT INTO checkpoint_witness_collections
         (collection_id, boundary_json, destination_id, epoch,
          previous_checkpoint, checkpoint_digest, canonical_envelope,
          producer_authentication_json, status, deadline_at, created_at, ready_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'collecting', ?, ?, NULL)`,
        collectionId,
        JSON.stringify(input.statement.boundary),
        input.statement.destination_id,
        input.statement.epoch,
        input.statement.previous_checkpoint,
        input.statement.checkpoint_digest,
        input.statement.canonical_envelope,
        JSON.stringify(input.producer_authentication),
        input.deadline_at,
        now,
      );
      return {
        decision: "started",
        collection: this.collection(this.row(collectionId)!, policy),
      };
    });
  }

  submit(
    runtime: LoadedCheckpointRuntime,
    collectionId: string,
    approval: CheckpointDeliveryApproval,
    policy: CheckpointDeliveryAuthenticationPolicy,
    now: number,
  ): CheckpointWitnessApprovalResult {
    return this.storage.transactionSync(() => {
      const row = this.row(collectionId);
      if (!row) return { decision: "unknown" };
      const approvalCount = this.approvalRows(collectionId).length;
      if (row.status === "expired" ||
        (row.status === "collecting" && now >= row.deadline_at)) {
        if (row.status === "collecting") {
          this.storage.sql.exec(
            `UPDATE checkpoint_witness_collections
             SET status = 'expired' WHERE collection_id = ? AND status = 'collecting'`,
            collectionId,
          );
        }
        return {
          decision: "refused",
          reason: "collection_expired",
          approval_count: approvalCount,
        };
      }
      if (row.status === "ready") {
        return {
          decision: "duplicate",
          collection: this.collection(row, policy),
        };
      }
      const existing = this.approvalRow(collectionId, approval.witness_id);
      if (existing) {
        const first = JSON.parse(existing.approval_json) as CheckpointDeliveryApproval;
        if (sameCheckpointDeliveryApproval(first, approval)) {
          return {
            decision: "duplicate",
            collection: this.collection(row, policy),
          };
        }
        const conflictingAuthentication: CheckpointDeliveryAuthentication = {
          ...producerAuthenticationFromRow(row),
          approvals: [approval],
        };
        const conflictingVerification = verifyDelivery(
          runtime,
          statementFromRow(row),
          policy,
          conflictingAuthentication,
        );
        if (
          !conflictingVerification.ok &&
          conflictingVerification.error !== "under_quorum"
        ) {
          return {
            decision: "refused",
            reason: conflictingVerification.error,
            approval_count: approvalCount,
          };
        }
        this.storage.sql.exec(
          `INSERT OR IGNORE INTO checkpoint_witness_conflicts
           (collection_id, witness_id, first_approval_json,
            conflicting_approval_json, observed_at)
           VALUES (?, ?, ?, ?, ?)`,
          collectionId,
          approval.witness_id,
          existing.approval_json,
          JSON.stringify(approval),
          now,
        );
        return {
          decision: "conflict",
          reason: "witness_equivocation",
          approval_count: approvalCount,
        };
      }
      const statement = statementFromRow(row);
      const producerAuthentication = producerAuthenticationFromRow(row);
      const candidate: CheckpointDeliveryAuthentication = {
        ...producerAuthentication,
        approvals: [
          ...this.approvals(collectionId),
          approval,
        ],
      };
      const verification = verifyDelivery(runtime, statement, policy, candidate);
      if (!verification.ok && verification.error !== "under_quorum") {
        return {
          decision: "refused",
          reason: verification.error,
          approval_count: approvalCount,
        };
      }
      this.storage.sql.exec(
        `INSERT INTO checkpoint_witness_approvals
         (collection_id, witness_id, approval_json, accepted_at)
         VALUES (?, ?, ?, ?)`,
        collectionId,
        approval.witness_id,
        JSON.stringify(approval),
        now,
      );
      if (verification.ok) {
        this.storage.sql.exec(
          `UPDATE checkpoint_witness_collections
           SET status = 'ready', ready_at = ?
           WHERE collection_id = ? AND status = 'collecting'`,
          now,
          collectionId,
        );
      }
      return {
        decision: "accepted",
        collection: this.collection(this.row(collectionId)!, policy),
      };
    });
  }

  get(
    collectionId: string,
    policy: CheckpointDeliveryAuthenticationPolicy,
    now: number,
  ): CheckpointWitnessCollection | undefined {
    return this.storage.transactionSync(() => {
      const row = this.row(collectionId);
      if (!row) return undefined;
      const effective = this.expireIfNeeded(row, now);
      return this.collection(effective, policy);
    });
  }

  readyAuthentication(
    runtime: LoadedCheckpointRuntime,
    collectionId: string,
    expected: CheckpointWitnessStatement,
    policy: CheckpointDeliveryAuthenticationPolicy,
    now: number,
  ): ReadyCheckpointWitnessAuthentication {
    return this.storage.transactionSync(() => {
      const row = this.row(collectionId);
      if (!row) return { ok: false, reason: "witness_collection_unknown" };
      const effective = this.expireIfNeeded(row, now);
      if (!sameStatement(statementFromRow(effective), expected)) {
        return { ok: false, reason: "witness_collection_statement_mismatch" };
      }
      if (effective.status !== "ready") {
        return {
          ok: false,
          reason: effective.status === "expired"
            ? "witness_collection_expired"
            : "witness_collection_not_ready",
        };
      }
      const authentication: CheckpointDeliveryAuthentication = {
        ...producerAuthenticationFromRow(effective),
        approvals: this.approvals(collectionId),
      };
      const verification = verifyDelivery(
        runtime,
        expected,
        policy,
        authentication,
      );
      return verification.ok
        ? { ok: true, authentication }
        : { ok: false, reason: verification.error };
    });
  }

  private expireIfNeeded(row: CollectionRow, now: number): CollectionRow {
    if (row.status !== "collecting" || now < row.deadline_at) return row;
    this.storage.sql.exec(
      `UPDATE checkpoint_witness_collections
       SET status = 'expired' WHERE collection_id = ? AND status = 'collecting'`,
      row.collection_id,
    );
    return { ...row, status: "expired" };
  }

  private collection(
    row: CollectionRow,
    policy: CheckpointDeliveryAuthenticationPolicy,
  ): CheckpointWitnessCollection {
    return {
      collection_id: row.collection_id,
      statement: statementFromRow(row),
      producer_authentication: producerAuthenticationFromRow(row),
      status: row.status,
      approval_count: this.approvalRows(row.collection_id).length,
      required_approvals: policy.required_approvals,
      deadline_at: row.deadline_at,
      created_at: row.created_at,
      ready_at: row.ready_at,
    };
  }

  private row(collectionId: string): CollectionRow | undefined {
    return this.storage.sql.exec<CollectionRow>(
      `SELECT collection_id, boundary_json, destination_id, epoch,
              previous_checkpoint, checkpoint_digest, canonical_envelope,
              producer_authentication_json, status, deadline_at, created_at,
              ready_at
       FROM checkpoint_witness_collections WHERE collection_id = ?`,
      collectionId,
    ).toArray()[0];
  }

  private approvalRows(collectionId: string): ApprovalRow[] {
    return this.storage.sql.exec<ApprovalRow>(
      `SELECT witness_id, approval_json FROM checkpoint_witness_approvals
       WHERE collection_id = ? ORDER BY witness_id ASC`,
      collectionId,
    ).toArray();
  }

  private approvalRow(
    collectionId: string,
    witnessId: string,
  ): ApprovalRow | undefined {
    return this.storage.sql.exec<ApprovalRow>(
      `SELECT witness_id, approval_json FROM checkpoint_witness_approvals
       WHERE collection_id = ? AND witness_id = ?`,
      collectionId,
      witnessId,
    ).toArray()[0];
  }

  private approvals(collectionId: string): CheckpointDeliveryApproval[] {
    return this.approvalRows(collectionId).map((row) =>
      JSON.parse(row.approval_json) as CheckpointDeliveryApproval
    );
  }
}

export function checkpointWitnessCollectionId(
  statement: CheckpointWitnessStatement,
): string {
  const boundary = statement.boundary;
  return JSON.stringify([
    "checkpoint-witness-collection-v1",
    boundary.protocol_version,
    boundary.purpose,
    boundary.manifest_digest,
    boundary.scope_id,
    boundary.unit_id,
    statement.destination_id,
    statement.epoch,
    statement.checkpoint_digest,
  ]);
}

function statementFromRow(row: CollectionRow): CheckpointWitnessStatement {
  return {
    boundary: JSON.parse(row.boundary_json) as CheckpointRuntimeBoundary,
    destination_id: row.destination_id,
    epoch: row.epoch,
    previous_checkpoint: row.previous_checkpoint,
    checkpoint_digest: row.checkpoint_digest,
    canonical_envelope: row.canonical_envelope,
  };
}

function producerAuthenticationFromRow(
  row: CollectionRow,
): CheckpointDeliveryAuthentication {
  return JSON.parse(
    row.producer_authentication_json,
  ) as CheckpointDeliveryAuthentication;
}

function collectionStartMatches(
  row: CollectionRow,
  input: CheckpointWitnessCollectionStart,
): boolean {
  return sameStatement(statementFromRow(row), input.statement) &&
    sameCheckpointDeliveryAuthentication(
      producerAuthenticationFromRow(row),
      input.producer_authentication,
    ) &&
    row.deadline_at === input.deadline_at;
}

function sameStatement(
  left: CheckpointWitnessStatement,
  right: CheckpointWitnessStatement,
): boolean {
  return left.boundary.protocol_version === right.boundary.protocol_version &&
    left.boundary.purpose === right.boundary.purpose &&
    left.boundary.manifest_digest === right.boundary.manifest_digest &&
    left.boundary.scope_id === right.boundary.scope_id &&
    left.boundary.unit_id === right.boundary.unit_id &&
    left.destination_id === right.destination_id &&
    left.epoch === right.epoch &&
    left.previous_checkpoint === right.previous_checkpoint &&
    left.checkpoint_digest === right.checkpoint_digest &&
    left.canonical_envelope === right.canonical_envelope;
}

function verifyDelivery(
  runtime: LoadedCheckpointRuntime,
  statement: CheckpointWitnessStatement,
  policy: CheckpointDeliveryAuthenticationPolicy,
  authentication: CheckpointDeliveryAuthentication,
) {
  return verifyCheckpointDeliveryAuthenticationSync(runtime, {
    boundary: statement.boundary,
    destinationId: statement.destination_id,
    epoch: statement.epoch,
    previousCheckpoint: statement.previous_checkpoint,
    checkpointDigest: statement.checkpoint_digest,
    canonicalEnvelope: statement.canonical_envelope,
    policy,
    authentication,
  });
}
