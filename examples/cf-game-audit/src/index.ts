import { DurableObject } from "cloudflare:workers";
import {
  AUDIT_MODE_POLICIES,
  isAuditMode,
  isUnitKey,
  type AuditMode,
} from "./contracts";
import {
  checkpointDeliveryIdempotencyKey,
  CheckpointRuntimeStore,
  InjectedCheckpointSealFault,
  type CheckpointDeliveryJob,
  type CheckpointSealFaultPoint,
} from "./checkpoint-runtime";
import {
  CheckpointReceiverStore,
  type CheckpointAuthorityAck,
  type CheckpointReceiverConfiguration,
} from "./checkpoint-receiver";
import {
  CheckpointWitnessCollectionStore,
  type CheckpointWitnessStatement,
} from "./checkpoint-witness-collection";
import { decodeAuditQueueBody } from "./queue-wire";
import {
  classifyAnchorHead,
  classifyCentralReplayArtifacts,
  inventoryHeadAdvanceAllowed,
  loadCheckpointRuntime,
  marketplaceCreationPersistAllowed,
  openCheckpointClosure,
  verifyAnchorEnvelope,
  verifyInventoryListingProofBundle,
  verifyOpenWorldPveReplayBundle,
  verifyPveReplayBundle,
  verifyPvpReplayBundle,
  verifyCheckpointDeliveryAuthenticationSync,
  type AnchorHeadDecision,
  type CentralReplayArtifactDecision,
  type CheckpointDeliveryAuthentication,
  type CheckpointDeliveryApproval,
  type CheckpointDeliveryAuthenticationPolicy,
  type VerifiedAnchor,
  type VerifiedItemCreation,
} from "./moonbit";

export interface Env {
  AUDIT_SHARD: DurableObjectNamespace<GameAuditShard>;
  REPLAY_QUEUE: Queue<AuditQueueWireBody>;
  ADMIN_TOKEN: string;
  WITNESS_SOURCE_BUCKET_KEY: string;
}

export type { CheckpointDeliveryJob } from "./checkpoint-runtime";

export type ReplayReason =
  | "fork"
  | "sample"
  | "challenge"
  | "high_value"
  | "dispute"
  | "marketplace";

export interface ReplayJob {
  version: 1;
  idempotency_key: string;
  mode: AuditMode;
  unit: string;
  reason: ReplayReason;
  epoch: number;
  digest: string;
  checkpoint_digest?: string;
  created_at: number;
}

type AuditQueueJob = ReplayJob | CheckpointDeliveryJob;
type AuditQueueWireBody = AuditQueueJob | string;
type SuccessfulCheckpointAuthorityAck = CheckpointAuthorityAck & {
  decision: "accepted" | "duplicate";
};

interface AuditConfigRow extends Record<string, SqlStorageValue> {
  mode: AuditMode;
  unit_key: string;
  session_id: string;
  authority_key: string;
  initial_epoch: number;
  initial_previous_digest: string;
  created_at: number;
}

interface HeadRow extends Record<string, SqlStorageValue> {
  epoch: number;
  digest: string;
  previous_digest: string;
  observer_id: string;
  anchor_root: string;
  anchor_size: number;
  updated_at: number;
}

interface HistoryRow extends HeadRow {
  envelope_hex: string;
  envelope_bytes: number;
}

interface ReplayOutboxRow extends Record<string, SqlStorageValue> {
  idempotency_key: string;
  reason: ReplayReason;
  epoch: number;
  digest: string;
  checkpoint_digest: string | null;
  status: "pending" | "queued" | "delivered";
  attempts: number;
  created_at: number;
  queued_at: number | null;
  delivered_at: number | null;
  replay_decision: CentralReplayArtifactDecision | null;
  replay_error: string | null;
  replay_compute_ms: number | null;
  decided_at: number | null;
}

interface ReplayArtifactRow extends Record<string, SqlStorageValue> {
  idempotency_key: string;
  kind: "pve-v1" | "pve-v2" | "pvp-v1" | "open-pve-v1" | "open-pve-v2";
  checkpoint_digest: string;
  target_session_id: string;
  audit_checkpoint_digest: string | null;
  seal_checkpoint_digest: string | null;
  transparency_log_session_id: string | null;
  transparency_publisher_key: string | null;
  transparency_checkpoint_digest: string | null;
  bundle_hex: string;
  bundle_bytes: number;
  created_at: number;
}

interface VerifiedItemCreationRow extends Record<string, SqlStorageValue> {
  asset_id: string;
  initial_owner_id: string;
  item_type: string;
  quantity: number;
  output_index: number;
  source_event: string;
  checkpoint_digest: string;
  inventory_session_id: string;
  current_owner_id: string;
  current_version: number;
  inventory_checkpoint_digest: string;
  inventory_epoch: number;
  inventory_game_manifest_digest: string | null;
  inventory_public_state_root: string | null;
  inventory_last_event: string | null;
  replay_key: string;
  status: "eligible" | "revoked";
  created_at: number;
}

interface CommitResult {
  decision: "initialized" | AnchorHeadDecision;
  epoch: number;
  digest: string;
  replay_key?: string;
}

const MAX_JSON_BODY_BYTES = 2_200_000;
const MAX_ENVELOPE_HEX_CHARS = 131_072;
const MAX_REPLAY_BUNDLE_HEX_CHARS = 2_097_152;
const MAX_INVENTORY_BUNDLE_HEX_CHARS = 524_288;
const MAX_GAP_ITEMS = 256;
const CHECKPOINT_DELIVERY_LEASE_MS = 30_000;
const LOCATION_HINTS = new Set([
  "wnam",
  "enam",
  "sam",
  "weur",
  "eeur",
  "apac",
  "apac-ne",
  "apac-se",
  "oc",
  "afr",
  "me",
]);
const EXPLICIT_REPLAY_REASONS: Record<AuditMode, ReadonlySet<ReplayReason>> = {
  pve: new Set(["high_value", "challenge"]),
  pvp: new Set(["dispute"]),
  open: new Set(["sample", "challenge", "marketplace"]),
};
let witnessSourceBucketKeySecret: string | undefined;
let witnessSourceBucketKeyPromise: Promise<CryptoKey> | undefined;

const worker = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return jsonResponse({ ok: true, service: "converge-game-audit" });
    }

    const route = parseRoute(url.pathname);
    if (!route) {
      return jsonError("not_found", 404);
    }
    if (
      (route.action === "configure" ||
        route.action === "replay" ||
        route.action === "market-listing" ||
        route.action.startsWith("checkpoint-")) &&
      !(request.method === "POST" &&
        route.action === "checkpoint-witness-approvals") &&
      !(request.method === "GET" &&
        route.action === "checkpoint-witness-collections") &&
      !authorized(request, env.ADMIN_TOKEN)
    ) {
      return jsonError("unauthorized", 401);
    }

    const id = env.AUDIT_SHARD.idFromName(`${route.mode}:${route.unit}`);
    const requestedHint = url.searchParams.get("location_hint");
    const locationHint = requestedHint && LOCATION_HINTS.has(requestedHint)
      ? requestedHint as DurableObjectLocationHint
      : undefined;
    const stub = env.AUDIT_SHARD.get(
      id,
      locationHint ? { locationHint } : undefined,
    );
    const headers = new Headers(request.headers);
    headers.delete("x-audit-internal");
    headers.delete("x-audit-source-bucket");
    if (route.action === "checkpoint-witness-approvals") {
      if (!env.WITNESS_SOURCE_BUCKET_KEY ||
        env.WITNESS_SOURCE_BUCKET_KEY.length < 32) {
        return jsonError(
          "checkpoint_witness_source_bucketing_not_configured",
          503,
        );
      }
      headers.set(
        "x-audit-source-bucket",
        await checkpointWitnessSourceBucket(
          request,
          env.WITNESS_SOURCE_BUCKET_KEY,
        ),
      );
    }
    headers.set("x-audit-mode", route.mode);
    headers.set("x-audit-unit", route.unit);
    return stub.fetch(new Request(request, { headers }));
  },

  async queue(
    batch: MessageBatch<AuditQueueWireBody>,
    env: Env,
    _ctx: ExecutionContext,
  ): Promise<void> {
    for (const message of batch.messages) {
      logAuditQueueMessageShape(batch.queue, message.body);
      const decoded = decodeAuditQueueBody(message.body);
      if (!decoded.ok) {
        console.error(JSON.stringify({
          event: "audit_queue_message",
          stage: "decode_refused",
          queue: batch.queue,
          reason: decoded.reason,
        }));
        message.retry();
        continue;
      }
      const job = decoded.value;
      if (isCheckpointDeliveryJob(job)) {
        logCheckpointDelivery("consumer_started", batch.queue, job);
        if (await deliverCheckpointJob(job, env)) {
          logCheckpointDelivery("ack_committed", batch.queue, job);
          message.ack();
        } else {
          logCheckpointDelivery("retry_scheduled", batch.queue, job);
          message.retry();
        }
        continue;
      }
      if (
        typeof job === "object" && job !== null &&
        "kind" in job && job.kind === "checkpoint-delivery-v1"
      ) {
        console.error(JSON.stringify({
          event: "checkpoint_delivery",
          stage: "invalid_queue_message",
          queue: batch.queue,
        }));
      }
      if (!isReplayJob(job)) {
        message.retry();
        continue;
      }
      try {
        const id = env.AUDIT_SHARD.idFromName(`${job.mode}:${job.unit}`);
        const stub = env.AUDIT_SHARD.get(id);
        const response = await stub.fetch("https://audit.internal/replay-delivered", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-audit-internal": "queue-consumer",
            "x-audit-mode": job.mode,
            "x-audit-unit": job.unit,
          },
          body: JSON.stringify(job),
        });
        if (response.ok) {
          message.ack();
        } else {
          console.error(
            "replay delivery refused",
            response.status,
            await response.text(),
          );
          message.retry();
        }
      } catch (error) {
        console.error("replay delivery failed", error);
        message.retry();
      }
    }
  },
} satisfies ExportedHandler<Env, AuditQueueWireBody>;

export default worker;

function logAuditQueueMessageShape(queue: string, value: unknown): void {
  const isRecord = typeof value === "object" && value !== null &&
    !Array.isArray(value);
  console.log(JSON.stringify({
    event: "audit_queue_message",
    queue,
    body_type: value === null ? "null" : Array.isArray(value) ? "array" : typeof value,
    fields: isRecord ? Object.keys(value).sort() : [],
  }));
}

function logCheckpointDelivery(
  stage: "consumer_started" | "ack_committed" | "retry_scheduled",
  queue: string,
  job: CheckpointDeliveryJob,
): void {
  console.log(JSON.stringify({
    event: "checkpoint_delivery",
    stage,
    queue,
    mode: job.mode,
    unit: job.unit,
    destination_id: job.destination_id,
    epoch: job.epoch,
  }));
}

export function checkpointDestinationObjectName(
  job: Pick<CheckpointDeliveryJob, "mode" | "unit" | "destination_id">,
): string {
  return JSON.stringify([
    "checkpoint-destination-v1",
    job.mode,
    job.unit,
    job.destination_id,
  ]);
}

async function deliverCheckpointJob(
  job: CheckpointDeliveryJob,
  env: Env,
): Promise<boolean> {
  try {
    const source = env.AUDIT_SHARD.get(
      env.AUDIT_SHARD.idFromName(`${job.mode}:${job.unit}`),
    );
    const authentication = await source.fetch(
      "https://audit.internal/checkpoint-delivery-authenticate",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-audit-internal": "checkpoint-queue-consumer",
          "x-audit-mode": job.mode,
          "x-audit-unit": job.unit,
        },
        body: JSON.stringify(job),
      },
    );
    if (!authentication.ok) {
      console.error(
        "checkpoint delivery was absent from source outbox",
        authentication.status,
        await authentication.text(),
      );
      return false;
    }
    const ack = await receiveCheckpointAtAuthority(job, env);
    if (!ack) return false;
    const acknowledged = await source.fetch(
      "https://audit.internal/checkpoint-ack",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-audit-internal": "checkpoint-authority-ack",
          "x-audit-mode": job.mode,
          "x-audit-unit": job.unit,
        },
        body: JSON.stringify({ job, ack }),
      },
    );
    if (!acknowledged.ok) {
      console.error(
        "checkpoint ACK was not committed",
        acknowledged.status,
        await acknowledged.text(),
      );
      return false;
    }
    return true;
  } catch (error) {
    console.error("checkpoint delivery failed", error);
    return false;
  }
}

async function receiveCheckpointAtAuthority(
  job: CheckpointDeliveryJob,
  env: Env,
): Promise<SuccessfulCheckpointAuthorityAck | undefined> {
  const destination = env.AUDIT_SHARD.get(
    env.AUDIT_SHARD.idFromName(checkpointDestinationObjectName(job)),
  );
  const receive = await destination.fetch(
    "https://audit.internal/checkpoint-receive",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-audit-internal": "checkpoint-queue-consumer",
        "x-audit-mode": job.mode,
        "x-audit-unit": job.unit,
      },
      body: JSON.stringify(job),
    },
  );
  if (!receive.ok) {
    console.error(
      "checkpoint authority refused delivery",
      receive.status,
      await receive.text(),
    );
    return undefined;
  }
  const ack: unknown = await receive.json();
  return isCheckpointAuthorityAck(ack) && checkpointAckMatchesJob(ack, job)
    ? ack
    : undefined;
}

export class GameAuditShard extends DurableObject<Env> {
  private readonly auditEnv: Env;
  private readonly checkpointRuntime: CheckpointRuntimeStore;
  private readonly checkpointReceiver: CheckpointReceiverStore;
  private readonly checkpointWitnessCollections: CheckpointWitnessCollectionStore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.auditEnv = env;
    this.checkpointRuntime = new CheckpointRuntimeStore(this.ctx.storage);
    this.checkpointReceiver = new CheckpointReceiverStore(this.ctx.storage);
    this.checkpointWitnessCollections = new CheckpointWitnessCollectionStore(
      this.ctx.storage,
    );
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS audit_config (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        mode TEXT NOT NULL,
        unit_key TEXT NOT NULL,
        session_id TEXT NOT NULL,
        authority_key TEXT NOT NULL,
        initial_epoch INTEGER NOT NULL,
        initial_previous_digest TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS anchor_head (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        epoch INTEGER NOT NULL,
        digest TEXT NOT NULL,
        previous_digest TEXT NOT NULL,
        observer_id TEXT NOT NULL,
        anchor_root TEXT NOT NULL,
        anchor_size INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS anchor_history (
        epoch INTEGER PRIMARY KEY,
        digest TEXT NOT NULL,
        previous_digest TEXT NOT NULL,
        observer_id TEXT NOT NULL,
        anchor_root TEXT NOT NULL,
        anchor_size INTEGER NOT NULL,
        envelope_hex TEXT NOT NULL,
        envelope_bytes INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS anchor_forks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        accepted_epoch INTEGER NOT NULL,
        accepted_digest TEXT NOT NULL,
        observed_epoch INTEGER NOT NULL,
        conflicting_digest TEXT NOT NULL,
        conflicting_previous_digest TEXT NOT NULL,
        observed_at INTEGER NOT NULL,
        UNIQUE(kind, observed_epoch, conflicting_digest)
      );
      CREATE TABLE IF NOT EXISTS replay_outbox (
        idempotency_key TEXT PRIMARY KEY,
        reason TEXT NOT NULL,
        epoch INTEGER NOT NULL,
        digest TEXT NOT NULL,
        checkpoint_digest TEXT,
        status TEXT NOT NULL CHECK (status IN ('pending', 'queued', 'delivered')),
        attempts INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        queued_at INTEGER,
        delivered_at INTEGER,
        replay_decision TEXT,
        replay_error TEXT,
        replay_compute_ms REAL,
        decided_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS replay_artifacts (
        idempotency_key TEXT PRIMARY KEY,
        kind TEXT NOT NULL CHECK (
          kind IN ('pve-v1', 'pve-v2', 'pvp-v1', 'open-pve-v1', 'open-pve-v2')
        ),
        checkpoint_digest TEXT NOT NULL,
        target_session_id TEXT NOT NULL,
        audit_checkpoint_digest TEXT,
        seal_checkpoint_digest TEXT,
        transparency_log_session_id TEXT,
        transparency_publisher_key TEXT,
        transparency_checkpoint_digest TEXT,
        bundle_hex TEXT NOT NULL,
        bundle_bytes INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS verified_item_creations (
        asset_id TEXT PRIMARY KEY,
        initial_owner_id TEXT NOT NULL,
        item_type TEXT NOT NULL,
        quantity INTEGER NOT NULL CHECK (quantity > 0),
        output_index INTEGER NOT NULL CHECK (output_index >= 0),
        source_event TEXT NOT NULL,
        checkpoint_digest TEXT NOT NULL,
        inventory_session_id TEXT NOT NULL,
        current_owner_id TEXT NOT NULL,
        current_version INTEGER NOT NULL CHECK (current_version >= 0),
        inventory_checkpoint_digest TEXT NOT NULL,
        inventory_epoch INTEGER NOT NULL CHECK (inventory_epoch >= 0),
        inventory_game_manifest_digest TEXT,
        inventory_public_state_root TEXT,
        inventory_last_event TEXT,
        replay_key TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('eligible', 'revoked')),
        created_at INTEGER NOT NULL,
        UNIQUE(source_event, output_index)
      );
    `);
    this.migrateReplayArtifacts();
    this.addAuditConfigColumnIfMissing("initial_epoch", "INTEGER");
    this.addAuditConfigColumnIfMissing("initial_previous_digest", "TEXT");
    this.addReplayOutboxColumnIfMissing("replay_decision", "TEXT");
    this.addReplayOutboxColumnIfMissing("replay_error", "TEXT");
    this.addReplayOutboxColumnIfMissing("replay_compute_ms", "REAL");
    this.addReplayOutboxColumnIfMissing("decided_at", "INTEGER");
    this.addReplayOutboxColumnIfMissing("checkpoint_digest", "TEXT");
    this.addVerifiedItemCreationColumnIfMissing("inventory_session_id", "TEXT");
    this.addVerifiedItemCreationColumnIfMissing("current_owner_id", "TEXT");
    this.addVerifiedItemCreationColumnIfMissing("current_version", "INTEGER");
    this.addVerifiedItemCreationColumnIfMissing(
      "inventory_checkpoint_digest",
      "TEXT",
    );
    this.addVerifiedItemCreationColumnIfMissing("inventory_epoch", "INTEGER");
    this.addVerifiedItemCreationColumnIfMissing(
      "inventory_game_manifest_digest",
      "TEXT",
    );
    this.addVerifiedItemCreationColumnIfMissing(
      "inventory_public_state_root",
      "TEXT",
    );
    this.addVerifiedItemCreationColumnIfMissing("inventory_last_event", "TEXT");
    this.ctx.storage.sql.exec(`
      UPDATE verified_item_creations
      SET inventory_session_id = COALESCE(
            inventory_session_id,
            (SELECT target_session_id
             FROM replay_artifacts
             WHERE idempotency_key = verified_item_creations.replay_key),
            ''
          ),
          current_owner_id = COALESCE(current_owner_id, initial_owner_id),
          current_version = COALESCE(current_version, 0),
          inventory_checkpoint_digest = COALESCE(
            inventory_checkpoint_digest,
            checkpoint_digest
          ),
          inventory_epoch = COALESCE(inventory_epoch, 0)
    `);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const mode = request.headers.get("x-audit-mode");
    const unit = request.headers.get("x-audit-unit");
    if (!mode || !isAuditMode(mode) || !unit || !isUnitKey(unit)) {
      return jsonError("invalid_shard_boundary", 400);
    }
    const action = url.pathname.split("/").filter(Boolean).at(-1);

    switch (`${request.method} ${action}`) {
      case "POST configure":
        return this.configure(request, mode, unit);
      case "POST checkpoint-configure":
        return this.configureCheckpointRuntime(request, mode, unit);
      case "POST checkpoint-closures":
        return this.storeCheckpointClosure(request, mode, unit);
      case "POST checkpoint-witness-collections":
        return this.startCheckpointWitnessCollection(request, mode, unit);
      case "GET checkpoint-witness-collections":
        return this.getCheckpointWitnessCollection(url, mode, unit);
      case "POST checkpoint-witness-approvals":
        return this.submitCheckpointWitnessApproval(request, mode, unit);
      case "POST checkpoint-seals":
        return this.sealCheckpoint(request, mode, unit);
      case "POST anchors":
        return this.submitAnchor(request, mode, unit);
      case "POST replay":
        return this.requestCentralReplay(request, mode, unit);
      case "POST market-listing":
        return this.checkMarketListing(request, mode, unit);
      case "POST replay-delivered":
        return request.headers.get("x-audit-internal") === "queue-consumer"
          ? this.classifyDeliveredReplay(request, mode, unit)
          : jsonError("not_found", 404);
      case "POST checkpoint-receive":
        return request.headers.get("x-audit-internal") ===
            "checkpoint-queue-consumer"
          ? this.receiveCheckpointDelivery(request, mode, unit)
          : jsonError("not_found", 404);
      case "POST checkpoint-receiver-configure":
        return request.headers.get("x-audit-internal") ===
            "checkpoint-control-plane"
          ? this.configureCheckpointReceiver(request, mode, unit)
          : jsonError("not_found", 404);
      case "POST checkpoint-delivery-authenticate":
        return request.headers.get("x-audit-internal") ===
            "checkpoint-queue-consumer"
          ? this.authenticateCheckpointDelivery(request, mode, unit)
          : jsonError("not_found", 404);
      case "POST checkpoint-ack":
        return request.headers.get("x-audit-internal") ===
            "checkpoint-authority-ack"
          ? this.commitCheckpointAck(request, mode, unit)
          : jsonError("not_found", 404);
      case "GET head":
        return this.getHead(mode, unit);
      case "GET gap":
        return this.getGap(url, mode, unit);
      case "GET stats":
        return this.getStats(mode, unit);
      case "GET checkpoint-state":
        return this.getCheckpointState(mode, unit);
      case "GET policy":
        return jsonResponse({ mode, unit, ...AUDIT_MODE_POLICIES[mode] });
      case "GET ws":
        return this.openWebSocket(request, mode, unit);
      default:
        return jsonError("not_found", 404);
    }
  }

  webSocketMessage(socket: WebSocket, message: ArrayBuffer | string): void {
    if (message === "ping") {
      socket.send("pong");
    }
  }

  async alarm(): Promise<void> {
    const pending = this.ctx.storage.sql.exec<ReplayOutboxRow>(
      `SELECT idempotency_key, reason, epoch, digest, status, attempts,
              checkpoint_digest, created_at, queued_at, delivered_at,
              replay_decision, replay_error, replay_compute_ms, decided_at
       FROM replay_outbox
       WHERE status = 'pending'
       ORDER BY created_at ASC
       LIMIT 32`,
    ).toArray();
    let retryNeeded = false;
    for (const row of pending) {
      if (!(await this.dispatchReplayJob(row.idempotency_key))) {
        retryNeeded = true;
      }
    }
    const config = this.config();
    if (config) {
      await this.dispatchCheckpointDeliveries(config.mode, config.unit_key);
    }
    const checkpointRetryAt = this.checkpointRuntime.nextDeliveryRetryAt();
    const replayRetryAt = retryNeeded ? Date.now() + 5_000 : undefined;
    const nextAlarm = minimumDefined(checkpointRetryAt, replayRetryAt);
    if (nextAlarm !== undefined) {
      await this.ctx.storage.setAlarm(Math.max(Date.now() + 1_000, nextAlarm));
    }
  }

  private async configure(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const sessionId = stringField(body.value, "session_id");
    const authorityKey = stringField(body.value, "authority_key");
    const initialEpoch = numberField(body.value, "initial_epoch");
    const initialPreviousDigest = stringField(
      body.value,
      "initial_previous_digest",
    );
    if (
      !sessionId ||
      sessionId.length > 4_096 ||
      !authorityKey ||
      !/^[0-9a-f]{64}$/.test(authorityKey) ||
      initialEpoch === undefined ||
      initialEpoch < 0 ||
      !initialPreviousDigest ||
      initialPreviousDigest.length > 4_096
    ) {
      return jsonError("invalid_configuration", 400);
    }

    const existing = this.config();
    if (existing) {
      if (
        existing.mode === mode &&
        existing.unit_key === unit &&
        existing.session_id === sessionId &&
        existing.authority_key === authorityKey &&
        existing.initial_epoch === initialEpoch &&
        existing.initial_previous_digest === initialPreviousDigest
      ) {
        return jsonResponse({ ok: true, decision: "configuration_duplicate" });
      }
      return jsonError("configuration_conflict", 409);
    }

    this.ctx.storage.sql.exec(
      `INSERT INTO audit_config
       (singleton, mode, unit_key, session_id, authority_key, initial_epoch,
        initial_previous_digest, created_at)
       VALUES (1, ?, ?, ?, ?, ?, ?, ?)`,
      mode,
      unit,
      sessionId,
      authorityKey,
      initialEpoch,
      initialPreviousDigest,
      Date.now(),
    );
    return jsonResponse(
      { ok: true, decision: "configured", mode, unit },
      201,
    );
  }

  private async submitAnchor(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const config = this.config();
    if (!config || config.mode !== mode || config.unit_key !== unit) {
      return jsonError("shard_not_configured", 409);
    }
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const envelopeHex = stringField(body.value, "envelope_hex");
    if (
      !envelopeHex ||
      envelopeHex.length > MAX_ENVELOPE_HEX_CHARS ||
      envelopeHex.length % 2 !== 0 ||
      !/^[0-9a-f]+$/.test(envelopeHex)
    ) {
      return jsonError("invalid_envelope_hex", 400);
    }

    const verified = await verifyAnchorEnvelope(
      envelopeHex,
      config.authority_key,
      config.session_id,
    );
    if (!verified.ok) {
      return jsonError(verified.error, 422);
    }

    const result = this.ctx.storage.transactionSync(() =>
      this.commitVerifiedAnchor(verified, envelopeHex, config)
    );
    const replayQueue = result.replay_key
      ? await this.dispatchReplayJob(result.replay_key)
        ? "queued"
        : "pending"
      : undefined;
    if (
      result.decision === "initialized" ||
      result.decision === "advance" ||
      result.decision.endsWith("fork")
    ) {
      this.broadcast({ type: "anchor_head", mode, unit, ...result });
    }
    const status = result.decision === "initialized" || result.decision === "advance"
      ? 202
      : result.decision === "duplicate"
      ? 200
      : 409;
    return jsonResponse(
      { ok: status < 400, ...result, replay_queue: replayQueue },
      status,
    );
  }

  private async configureCheckpointRuntime(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const auditConfig = this.config();
    if (!auditConfig || auditConfig.mode !== mode || auditConfig.unit_key !== unit) {
      return jsonError("shard_not_configured", 409);
    }
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const protocolVersion = numberField(body.value, "protocol_version");
    const purpose = stringField(body.value, "purpose");
    const manifestDigest = stringField(body.value, "manifest_digest");
    const initialEpoch = numberField(body.value, "initial_epoch");
    const initialDigest = stringField(body.value, "initial_digest");
    const outboxCapacity = numberField(body.value, "outbox_capacity");
    const destinations = stringArrayField(body.value, "destinations");
    const authenticationPolicy = objectField(
      body.value,
      "authentication_policy",
    );
    if (
      protocolVersion === undefined ||
      protocolVersion <= 0 ||
      !isMoonBitInt(protocolVersion) ||
      !boundedNonEmptyString(purpose, 256) ||
      !boundedNonEmptyString(manifestDigest, 4_096) ||
      initialEpoch === undefined ||
      initialEpoch < -1 ||
      !isMoonBitInt(initialEpoch) ||
      !boundedNonEmptyString(initialDigest, 4_096) ||
      outboxCapacity === undefined ||
      outboxCapacity < 0 ||
      outboxCapacity > 100_000 ||
      !isMoonBitInt(outboxCapacity) ||
      !destinations ||
      destinations.length === 0 ||
      destinations.length > 32 ||
      new Set(destinations).size !== destinations.length ||
      destinations.some((destination) => !boundedNonEmptyString(destination, 256)) ||
      !isCheckpointDeliveryAuthenticationPolicy(authenticationPolicy)
    ) {
      return jsonError("invalid_checkpoint_configuration", 400);
    }
    const sortedDestinations = [...destinations].sort();
    const boundary = {
      protocol_version: protocolVersion,
      purpose,
      manifest_digest: manifestDigest,
      scope_id: auditConfig.session_id,
      unit_id: unit,
    };
    const result = this.checkpointRuntime.configure({
      ...boundary,
      initial_epoch: initialEpoch,
      initial_digest: initialDigest,
      outbox_capacity: outboxCapacity,
      destinations: sortedDestinations,
      authentication_policy: authenticationPolicy,
    });
    if (result.decision === "conflict") {
      return jsonError("checkpoint_configuration_conflict", 409);
    }
    const provisioned = await this.provisionCheckpointDestinations(
      mode,
      unit,
      boundary,
      initialEpoch,
      initialDigest,
      sortedDestinations,
      authenticationPolicy,
    );
    if (!provisioned.ok) {
      return jsonResponse(
        {
          ok: false,
          decision: "destination_provisioning_failed",
          destination_id: provisioned.destination_id,
        },
        503,
      );
    }
    return jsonResponse(
      {
        ok: true,
        decision: result.decision === "configured"
          ? "configured"
          : "configuration_duplicate",
        destinations_provisioned: provisioned.count,
      },
      result.decision === "configured" ? 201 : 200,
    );
  }

  private async provisionCheckpointDestinations(
    mode: AuditMode,
    unit: string,
    boundary: CheckpointReceiverConfiguration["boundary"],
    initialEpoch: number,
    initialDigest: string,
    destinations: string[],
    authenticationPolicy: CheckpointDeliveryAuthenticationPolicy,
  ): Promise<
    | { ok: true; count: number }
    | { ok: false; destination_id: string }
  > {
    let count = 0;
    for (const destinationId of destinations) {
      const receiver = this.auditEnv.AUDIT_SHARD.get(
        this.auditEnv.AUDIT_SHARD.idFromName(
          checkpointDestinationObjectName({
            mode,
            unit,
            destination_id: destinationId,
          }),
        ),
      );
      const response = await receiver.fetch(
        "https://audit.internal/checkpoint-receiver-configure",
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-audit-internal": "checkpoint-control-plane",
            "x-audit-mode": mode,
            "x-audit-unit": unit,
          },
          body: JSON.stringify({
            boundary,
            destination_id: destinationId,
            initial_epoch: initialEpoch,
            initial_digest: initialDigest,
            authentication_policy: authenticationPolicy,
          }),
        },
      );
      if (!response.ok) return { ok: false, destination_id: destinationId };
      if (!this.checkpointRuntime.markDestinationProvisioned(destinationId)) {
        return { ok: false, destination_id: destinationId };
      }
      count += 1;
    }
    return { ok: true, count };
  }

  private async storeCheckpointClosure(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const auditConfig = this.config();
    const runtimeConfig = this.checkpointRuntime.config();
    if (
      !auditConfig ||
      auditConfig.mode !== mode ||
      auditConfig.unit_key !== unit ||
      !runtimeConfig
    ) {
      return jsonError("checkpoint_runtime_not_configured", 409);
    }
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const epoch = numberField(body.value, "epoch");
    const rosterDigest = stringField(body.value, "roster_digest");
    const frontierDigest = stringField(body.value, "frontier_digest");
    const certificateDigest = stringField(body.value, "certificate_digest");
    const frontierComplete = booleanField(body.value, "frontier_complete");
    const conflictFree = booleanField(body.value, "conflict_free");
    const quorumSatisfied = booleanField(body.value, "quorum_satisfied");
    if (
      epoch === undefined ||
      epoch < 0 ||
      !isMoonBitInt(epoch) ||
      !boundedNonEmptyString(rosterDigest, 4_096) ||
      !boundedNonEmptyString(frontierDigest, 4_096) ||
      !boundedNonEmptyString(certificateDigest, 4_096) ||
      frontierComplete === undefined ||
      conflictFree === undefined ||
      quorumSatisfied === undefined
    ) {
      return jsonError("invalid_checkpoint_closure", 400);
    }
    const closure = {
      epoch,
      roster_digest: rosterDigest,
      frontier_digest: frontierDigest,
      certificate_digest: certificateDigest,
    };
    const decision = await openCheckpointClosure({
      boundary: {
        protocol_version: runtimeConfig.protocol_version,
        purpose: runtimeConfig.purpose,
        manifest_digest: runtimeConfig.manifest_digest,
        scope_id: runtimeConfig.scope_id,
        unit_id: runtimeConfig.unit_id,
      },
      closure,
      frontierComplete,
      conflictFree,
      quorumSatisfied,
    });
    if (decision === "ready") {
      const stored = this.checkpointRuntime.storeClosure(closure);
      if (stored.decision === "conflict") {
        return jsonError("checkpoint_closure_conflict", 409);
      }
      return jsonResponse(
        {
          ok: true,
          decision: stored.decision === "stored" ? "stored" : "duplicate",
          epoch,
        },
        stored.decision === "stored" ? 201 : 200,
      );
    }
    if (decision.startsWith("pending_")) {
      return jsonResponse({ ok: false, decision: "pending", reason: decision }, 202);
    }
    if (decision.startsWith("conflict_")) {
      return jsonResponse({ ok: false, decision: "conflict", reason: decision }, 409);
    }
    return jsonResponse({ ok: false, decision: "refused", reason: decision }, 400);
  }

  private async startCheckpointWitnessCollection(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const auditConfig = this.config();
    const runtimeConfig = this.checkpointRuntime.config();
    const policy = this.checkpointRuntime.authenticationPolicy();
    if (
      !auditConfig ||
      auditConfig.mode !== mode ||
      auditConfig.unit_key !== unit ||
      !runtimeConfig ||
      !policy
    ) return jsonError("checkpoint_runtime_not_configured", 409);
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const destinationId = stringField(body.value, "destination_id");
    const epoch = numberField(body.value, "epoch");
    const previousCheckpoint = stringField(body.value, "previous_checkpoint");
    const checkpointDigest = stringField(body.value, "checkpoint_digest");
    const canonicalEnvelope = stringField(body.value, "canonical_envelope");
    const deadlineAt = numberField(body.value, "deadline_at");
    const producerAuthentication = objectField(
      body.value,
      "producer_authentication",
    );
    const now = Date.now();
    const destinations: unknown = JSON.parse(runtimeConfig.destinations_json);
    if (
      !boundedNonEmptyString(destinationId, 256) ||
      !Array.isArray(destinations) ||
      !destinations.includes(destinationId) ||
      epoch === undefined ||
      epoch < 0 ||
      !isMoonBitInt(epoch) ||
      !boundedNonEmptyString(previousCheckpoint, 4_096) ||
      !boundedNonEmptyString(checkpointDigest, 4_096) ||
      !boundedNonEmptyString(canonicalEnvelope, MAX_ENVELOPE_HEX_CHARS) ||
      deadlineAt === undefined ||
      !Number.isSafeInteger(deadlineAt) ||
      deadlineAt <= now ||
      deadlineAt > now + 86_400_000 ||
      !isCheckpointDeliveryAuthentication(producerAuthentication)
    ) return jsonError("invalid_checkpoint_witness_collection", 400);
    const runtimeCapability = await loadCheckpointRuntime();
    const result = this.checkpointWitnessCollections.start(
      runtimeCapability,
      {
        statement: {
          boundary: checkpointBoundaryFromConfig(runtimeConfig),
          destination_id: destinationId,
          epoch,
          previous_checkpoint: previousCheckpoint,
          checkpoint_digest: checkpointDigest,
          canonical_envelope: canonicalEnvelope,
        },
        producer_authentication: producerAuthentication,
        deadline_at: deadlineAt,
      },
      policy,
      now,
    );
    if (result.decision === "conflict") {
      return jsonError("checkpoint_witness_collection_conflict", 409);
    }
    if (result.decision === "refused") {
      return jsonResponse(
        { ok: false, decision: "refused", reason: result.reason },
        409,
      );
    }
    return jsonResponse(
      {
        ok: true,
        decision: result.decision,
        ...result.collection,
        authentication_policy: policy,
      },
      result.decision === "started" ? 201 : 200,
    );
  }

  private getCheckpointWitnessCollection(
    url: URL,
    _mode: AuditMode,
    _unit: string,
  ): Response {
    const policy = this.checkpointRuntime.authenticationPolicy();
    const collectionId = url.searchParams.get("collection_id");
    if (!policy) return jsonError("checkpoint_runtime_not_configured", 409);
    if (!collectionId || collectionId.length > 1_024) {
      return jsonError("invalid_checkpoint_witness_collection_id", 400);
    }
    const collection = this.checkpointWitnessCollections.get(
      collectionId,
      policy,
      Date.now(),
    );
    return collection
      ? jsonResponse({ ok: true, ...collection, authentication_policy: policy })
      : jsonError("checkpoint_witness_collection_not_found", 404);
  }

  private async submitCheckpointWitnessApproval(
    request: Request,
    _mode: AuditMode,
    _unit: string,
  ): Promise<Response> {
    const policy = this.checkpointRuntime.authenticationPolicy();
    if (!policy) return jsonError("checkpoint_runtime_not_configured", 409);
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const collectionId = stringField(body.value, "collection_id");
    const approval = objectField(body.value, "approval");
    if (
      !boundedNonEmptyString(collectionId, 1_024) ||
      !isCheckpointDeliveryApproval(approval)
    ) return jsonError("invalid_checkpoint_witness_approval", 400);
    const sourceBucket = request.headers.get("x-audit-source-bucket");
    if (!sourceBucket || !/^[0-9a-f]{64}$/.test(sourceBucket)) {
      return jsonError("invalid_checkpoint_witness_source", 400);
    }
    const now = Date.now();
    const admission = this.checkpointWitnessCollections.reserveSubmission(
      collectionId,
      sourceBucket,
      now,
    );
    if (admission.decision === "unknown") {
      return jsonError("checkpoint_witness_collection_not_found", 404);
    }
    if (admission.decision === "limited") {
      const response = jsonError("checkpoint_witness_source_rate_limited", 429);
      response.headers.set(
        "retry-after",
        Math.ceil(admission.retry_after_ms / 1_000).toString(),
      );
      return response;
    }
    const runtimeCapability = await loadCheckpointRuntime();
    const result = this.checkpointWitnessCollections.submit(
      runtimeCapability,
      collectionId,
      approval,
      policy,
      now,
    );
    if (result.decision === "unknown") {
      return jsonError("checkpoint_witness_collection_not_found", 404);
    }
    if (result.decision === "refused" || result.decision === "conflict") {
      return jsonResponse({ ok: false, ...result }, 409);
    }
    if (!("collection" in result)) {
      return jsonError("checkpoint_witness_approval_refused", 409);
    }
    const status = result.decision === "duplicate"
      ? 200
      : result.collection.status === "ready"
      ? 201
      : 202;
    return jsonResponse({ ok: true, ...result, ...result.collection }, status);
  }

  private async sealCheckpoint(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const auditConfig = this.config();
    if (!auditConfig || auditConfig.mode !== mode || auditConfig.unit_key !== unit) {
      return jsonError("shard_not_configured", 409);
    }
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const epoch = numberField(body.value, "epoch");
    const previousCheckpoint = stringField(body.value, "previous_checkpoint");
    const checkpointDigest = stringField(body.value, "checkpoint_digest");
    const canonicalEnvelope = stringField(body.value, "canonical_envelope");
    const destinations = stringArrayField(body.value, "destinations");
    const authentications = checkpointDeliveryAuthenticationArrayField(
      body.value,
      "authentications",
    );
    const collectionReferences = checkpointWitnessCollectionReferenceArrayField(
      body.value,
      "authentication_collection_ids",
    );
    const hasAuthentications = hasOwnField(body.value, "authentications");
    const hasCollectionReferences = hasOwnField(
      body.value,
      "authentication_collection_ids",
    );
    const rawFaultPoint = request.headers.get("x-audit-fault-point");
    const faultPoint = rawFaultPoint === null
      ? undefined
      : isCheckpointSealFaultPoint(rawFaultPoint)
      ? rawFaultPoint
      : null;
    const rawDispatchMode = request.headers.get("x-audit-checkpoint-dispatch");
    const dispatchMode = rawDispatchMode === null || rawDispatchMode === "direct"
      ? "direct"
      : rawDispatchMode === "deferred"
      ? "deferred"
      : null;
    if (
      epoch === undefined ||
      epoch < 0 ||
      !isMoonBitInt(epoch) ||
      !boundedNonEmptyString(previousCheckpoint, 4_096) ||
      !boundedNonEmptyString(checkpointDigest, 4_096) ||
      !boundedNonEmptyString(canonicalEnvelope, MAX_ENVELOPE_HEX_CHARS) ||
      !destinations ||
      destinations.length === 0 ||
      destinations.length > 32 ||
      destinations.some((destination) => !boundedNonEmptyString(destination, 256)) ||
      hasAuthentications === hasCollectionReferences ||
      (hasAuthentications && !authentications) ||
      (hasCollectionReferences && !collectionReferences) ||
      faultPoint === null ||
      dispatchMode === null
    ) {
      return jsonError("invalid_checkpoint_seal", 400);
    }
    const runtimeCapability = await loadCheckpointRuntime();
    const runtimeConfig = this.checkpointRuntime.config();
    const policy = this.checkpointRuntime.authenticationPolicy();
    if (!runtimeConfig || !policy) {
      return jsonError("checkpoint_runtime_not_configured", 409);
    }
    const boundary = {
      protocol_version: runtimeConfig.protocol_version,
      purpose: runtimeConfig.purpose,
      manifest_digest: runtimeConfig.manifest_digest,
      scope_id: runtimeConfig.scope_id,
      unit_id: runtimeConfig.unit_id,
    };
    const effectiveAuthentications: Array<{
      destination_id: string;
      authentication: CheckpointDeliveryAuthentication;
    }> = [];
    if (authentications) {
      effectiveAuthentications.push(...authentications);
    } else {
      for (const reference of collectionReferences!) {
        const statement: CheckpointWitnessStatement = {
          boundary,
          destination_id: reference.destination_id,
          epoch,
          previous_checkpoint: previousCheckpoint,
          checkpoint_digest: checkpointDigest,
          canonical_envelope: canonicalEnvelope,
        };
        const ready = this.checkpointWitnessCollections.readyAuthentication(
          runtimeCapability,
          reference.collection_id,
          statement,
          policy,
          Date.now(),
        );
        if (!ready.ok) {
          return jsonResponse(
            { ok: false, decision: "refused", reason: ready.reason },
            409,
          );
        }
        effectiveAuthentications.push({
          destination_id: reference.destination_id,
          authentication: ready.authentication,
        });
      }
    }
    for (const value of effectiveAuthentications) {
      const verification = verifyCheckpointDeliveryAuthenticationSync(
        runtimeCapability,
        {
        boundary,
        destinationId: value.destination_id,
        epoch,
        previousCheckpoint,
        checkpointDigest,
        canonicalEnvelope,
        policy,
        authentication: value.authentication,
        },
      );
      if (!verification.ok) {
        return jsonResponse(
          {
            ok: false,
            decision: "refused",
            reason: "checkpoint_delivery_authentication_refused",
            authentication_error: verification.error,
          },
          409,
        );
      }
    }
    try {
      const result = this.checkpointRuntime.seal(
        runtimeCapability,
        {
          epoch,
          previous_checkpoint: previousCheckpoint,
          checkpoint_digest: checkpointDigest,
          canonical_envelope: canonicalEnvelope,
          destinations,
          authentications: effectiveAuthentications,
        },
        faultPoint,
      );
      if (result.decision === "committed") {
        await this.ctx.storage.sync();
        const deliveryDispatch = await this.dispatchCheckpointDeliveries(
          mode,
          unit,
          dispatchMode,
        );
        return jsonResponse({ ok: true, ...result, delivery_dispatch: deliveryDispatch }, 202);
      }
      if (result.decision === "duplicate") {
        await this.ctx.storage.sync();
        const deliveryDispatch = await this.dispatchCheckpointDeliveries(
          mode,
          unit,
          dispatchMode,
        );
        return jsonResponse({ ok: true, ...result, delivery_dispatch: deliveryDispatch }, 200);
      }
      return jsonResponse({ ok: false, ...result }, 409);
    } catch (error) {
      if (error instanceof InjectedCheckpointSealFault) {
        return jsonResponse(
          {
            ok: false,
            decision: "fault_injected",
            fault_point: error.faultPoint,
          },
          503,
        );
      }
      throw error;
    }
  }

  private getCheckpointState(mode: AuditMode, unit: string): Response {
    const config = this.config();
    if (!config || config.mode !== mode || config.unit_key !== unit) {
      return jsonError("shard_not_configured", 409);
    }
    const state = this.checkpointRuntime.state(mode);
    return state
      ? jsonResponse({ ok: true, mode, unit, ...state })
      : jsonError("checkpoint_runtime_not_configured", 404);
  }

  private async receiveCheckpointDelivery(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    if (
      !isCheckpointDeliveryJob(body.value) ||
      body.value.mode !== mode ||
      body.value.unit !== unit
    ) {
      return jsonError("invalid_checkpoint_delivery", 400);
    }
    const runtimeCapability = await loadCheckpointRuntime();
    const authentication = this.checkpointReceiver.authenticate(
      runtimeCapability,
      body.value,
    );
    if (authentication.decision === "not_configured") {
      return jsonError("checkpoint_receiver_not_configured", 409);
    }
    if (authentication.decision === "refused") {
      return jsonResponse(
        {
          ok: false,
          error: "checkpoint_delivery_authentication_refused",
          authentication_error: authentication.verification.error,
        },
        401,
      );
    }
    const ack = this.checkpointReceiver.receive(authentication.delivery);
    if (!ack) return jsonError("checkpoint_receiver_not_configured", 409);
    if (ack.decision === "accepted") {
      return jsonResponse({ ok: true, ...ack }, 202);
    }
    if (ack.decision === "duplicate") {
      return jsonResponse({ ok: true, ...ack }, 200);
    }
    return jsonResponse({ ok: false, ...ack }, 409);
  }

  private async configureCheckpointReceiver(
    request: Request,
    _mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    if (
      !isCheckpointReceiverConfiguration(body.value) ||
      body.value.boundary.unit_id !== unit
    ) {
      return jsonError("invalid_checkpoint_receiver_configuration", 400);
    }
    const result = this.checkpointReceiver.configure(body.value);
    if (result.decision === "conflict") {
      return jsonError("checkpoint_receiver_configuration_conflict", 409);
    }
    return jsonResponse(
      { ok: true, ...result },
      result.decision === "configured" ? 201 : 200,
    );
  }

  private async authenticateCheckpointDelivery(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    if (
      !isCheckpointDeliveryJob(body.value) ||
      body.value.mode !== mode ||
      body.value.unit !== unit ||
      !this.checkpointRuntime.authenticateDelivery(mode, body.value)
    ) {
      return jsonError("checkpoint_delivery_not_in_source_outbox", 409);
    }
    return jsonResponse({
      ok: true,
      authenticated: true,
      idempotency_key: body.value.idempotency_key,
    });
  }

  private async commitCheckpointAck(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const value = body.value as Record<string, unknown>;
    const job = value.job;
    const ack = value.ack;
    if (
      !isCheckpointDeliveryJob(job) ||
      job.mode !== mode ||
      job.unit !== unit ||
      !isCheckpointAuthorityAck(ack) ||
      !checkpointAckMatchesJob(ack, job)
    ) {
      return jsonError("invalid_checkpoint_ack", 400);
    }
    const runtimeCapability = await loadCheckpointRuntime();
    const result = this.checkpointRuntime.acknowledgeDelivery(
      runtimeCapability,
      job,
      ack,
      true,
    );
    if (result.decision === "refused") {
      return jsonResponse({ ok: false, ...result }, 409);
    }
    await this.dispatchCheckpointDeliveries(mode, unit);
    return jsonResponse({ ok: true, ...result });
  }

  private async dispatchCheckpointDeliveries(
    mode: AuditMode,
    unit: string,
    dispatchMode: "direct" | "deferred" = "direct",
  ): Promise<{
    mode: "direct" | "deferred";
    pending_before: number;
    in_flight_before: number;
    claimed: number;
    acknowledged: number;
    unsettled: number;
    errors: string[];
  }> {
    const runtimeCapability = await loadCheckpointRuntime();
    const before = this.checkpointRuntime.state(mode) as
      | { outbox: { pending: number; in_flight: number } }
      | undefined;
    const now = Date.now();
    const claims = this.checkpointRuntime.claimDeliveries(
      mode,
      unit,
      now,
      CHECKPOINT_DELIVERY_LEASE_MS,
    );
    let acknowledged = 0;
    let unsettled = 0;
    const errors: string[] = [];
    for (const claim of dispatchMode === "direct" ? claims : []) {
      try {
        const ack = await receiveCheckpointAtAuthority(
          claim.job,
          this.auditEnv,
        );
        if (!ack) {
          unsettled += 1;
          continue;
        }
        const result = this.checkpointRuntime.acknowledgeDelivery(
          runtimeCapability,
          claim.job,
          ack,
          true,
        );
        if (result.decision === "refused") {
          console.error("checkpoint direct ACK was refused", result.reason);
          unsettled += 1;
          errors.push(result.reason);
        } else {
          acknowledged += 1;
        }
      } catch (error) {
        console.error("checkpoint direct delivery failed", error);
        unsettled += 1;
        errors.push(error instanceof Error ? error.message : "unknown_error");
      }
    }
    const retryAt = this.checkpointRuntime.nextDeliveryRetryAt();
    if (retryAt !== undefined) {
      const current = await this.ctx.storage.getAlarm();
      const requested = Math.max(Date.now() + 1_000, retryAt);
      if (current === null || requested < current) {
        await this.ctx.storage.setAlarm(requested);
      }
    }
    return {
      mode: dispatchMode,
      pending_before: before?.outbox.pending ?? 0,
      in_flight_before: before?.outbox.in_flight ?? 0,
      claimed: claims.length,
      acknowledged,
      unsettled,
      errors,
    };
  }

  private commitVerifiedAnchor(
    verified: VerifiedAnchor,
    envelopeHex: string,
    config: AuditConfigRow,
  ): CommitResult {
    const known = this.historyAt(verified.epoch);
    const head = this.head();
    if (!head) {
      if (
        verified.epoch !== config.initial_epoch ||
        verified.previous_digest !== config.initial_previous_digest
      ) {
        return {
          decision: "boundary_rejected",
          epoch: verified.epoch,
          digest: verified.digest,
        };
      }
      this.insertHistoryAndHead(verified, envelopeHex);
      return {
        decision: "initialized",
        epoch: verified.epoch,
        digest: verified.digest,
      };
    }

    const decision = classifyAnchorHead({
      boundaryMatches:
        verified.session_id === config.session_id &&
        verified.publisher_key === config.authority_key,
      epochKnown: known !== undefined,
      knownDigestMatches: known?.digest === verified.digest,
      currentEpoch: head.epoch,
      incomingEpoch: verified.epoch,
      parentMatches: verified.previous_digest === head.digest,
    });

    if (decision === "advance") {
      this.insertHistoryAndHead(verified, envelopeHex);
    } else if (
      decision === "same_epoch_fork" ||
      decision === "wrong_parent_fork"
    ) {
      this.ctx.storage.sql.exec(
        `INSERT OR IGNORE INTO anchor_forks
         (kind, accepted_epoch, accepted_digest, observed_epoch,
          conflicting_digest, conflicting_previous_digest, observed_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        decision,
        decision === "same_epoch_fork" ? verified.epoch : head.epoch,
        decision === "same_epoch_fork" ? known?.digest ?? head.digest : head.digest,
        verified.epoch,
        verified.digest,
        verified.previous_digest,
        Date.now(),
      );
      const replayKey = this.insertReplayOutbox(
        config.mode,
        config.unit_key,
        "fork",
        verified.epoch,
        verified.digest,
      );
      return {
        decision,
        epoch: verified.epoch,
        digest: verified.digest,
        replay_key: replayKey,
      };
    }
    return { decision, epoch: verified.epoch, digest: verified.digest };
  }

  private async requestCentralReplay(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const config = this.config();
    const head = this.head();
    if (!config || !head) return jsonError("head_not_found", 404);
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const reason = stringField(body.value, "reason");
    if (!reason || !isExplicitReplayReason(mode, reason)) {
      return jsonError("replay_reason_not_allowed", 400);
    }
    const bundleHex = stringField(body.value, "bundle_hex");
    const checkpointDigest = stringField(body.value, "checkpoint_digest");
    const targetSessionId = stringField(body.value, "target_session_id");
    const auditCheckpointDigest = stringField(
      body.value,
      "audit_checkpoint_digest",
    );
    const sealCheckpointDigest = stringField(
      body.value,
      "seal_checkpoint_digest",
    );
    const transparencyLogSessionId = stringField(
      body.value,
      "transparency_log_session_id",
    );
    const transparencyPublisherKey = stringField(
      body.value,
      "transparency_publisher_key",
    );
    const transparencyCheckpointDigest = stringField(
      body.value,
      "transparency_checkpoint_digest",
    );
    const hasArtifact = bundleHex !== undefined ||
      checkpointDigest !== undefined ||
      targetSessionId !== undefined ||
      auditCheckpointDigest !== undefined ||
      sealCheckpointDigest !== undefined ||
      transparencyLogSessionId !== undefined ||
      transparencyPublisherKey !== undefined ||
      transparencyCheckpointDigest !== undefined;
    const commonArtifactValid = Boolean(
      bundleHex &&
        bundleHex.length <= MAX_REPLAY_BUNDLE_HEX_CHARS &&
        bundleHex.length % 2 === 0 &&
        /^[0-9a-f]+$/.test(bundleHex) &&
        checkpointDigest &&
        /^[0-9a-f]{64}$/.test(checkpointDigest),
    );
    const modeBoundaryValid = mode === "open"
      ? Boolean(
        targetSessionId &&
          targetSessionId.length <= 4_096 &&
          auditCheckpointDigest &&
          /^[0-9a-f]{64}$/.test(auditCheckpointDigest) &&
          sealCheckpointDigest &&
          /^[0-9a-f]{64}$/.test(sealCheckpointDigest) &&
          transparencyLogSessionId &&
          transparencyLogSessionId.length <= 4_096 &&
          transparencyPublisherKey &&
          /^[0-9a-f]{64}$/.test(transparencyPublisherKey) &&
          transparencyCheckpointDigest &&
          /^[0-9a-f]{64}$/.test(transparencyCheckpointDigest),
      )
      : targetSessionId === undefined &&
        auditCheckpointDigest === undefined &&
        sealCheckpointDigest === undefined &&
        transparencyLogSessionId === undefined &&
        transparencyPublisherKey === undefined &&
        transparencyCheckpointDigest === undefined;
    if (
      hasArtifact &&
      (!commonArtifactValid || !modeBoundaryValid)
    ) {
      return jsonError("invalid_replay_artifact", 400);
    }
    const storedTargetSessionId = hasArtifact
      ? targetSessionId ?? config.session_id
      : undefined;
    const key = replayIdempotencyKey(
      mode,
      unit,
      reason,
      head.epoch,
      head.digest,
      checkpointDigest,
    );
    const inserted = this.ctx.storage.transactionSync(() => {
      const insertedKey = this.insertReplayOutbox(
        mode,
        unit,
        reason,
        head.epoch,
        head.digest,
        checkpointDigest,
      );
      if (insertedKey && bundleHex && checkpointDigest) {
        const kind = mode === "open"
          ? "open-pve-v2"
          : mode === "pve"
          ? "pve-v2"
          : "pvp-v1";
        this.ctx.storage.sql.exec(
          `INSERT INTO replay_artifacts
           (idempotency_key, kind, checkpoint_digest, target_session_id,
            audit_checkpoint_digest, seal_checkpoint_digest,
            transparency_log_session_id, transparency_publisher_key,
            transparency_checkpoint_digest, bundle_hex, bundle_bytes, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          insertedKey,
          kind,
          checkpointDigest,
          storedTargetSessionId ?? config.session_id,
          auditCheckpointDigest ?? null,
          sealCheckpointDigest ?? null,
          transparencyLogSessionId ?? null,
          transparencyPublisherKey ?? null,
          transparencyCheckpointDigest ?? null,
          bundleHex,
          bundleHex.length / 2,
          Date.now(),
        );
      }
      return insertedKey;
    });
    if (!inserted) {
      const artifact = this.replayArtifactAt(key);
      if (
        bundleHex &&
        checkpointDigest &&
        (artifact?.bundle_hex !== bundleHex ||
          artifact.checkpoint_digest !== checkpointDigest ||
          artifact.target_session_id !== storedTargetSessionId ||
          artifact.audit_checkpoint_digest !==
            (auditCheckpointDigest ?? null) ||
          artifact.seal_checkpoint_digest !== (sealCheckpointDigest ?? null) ||
          artifact.transparency_log_session_id !==
            (transparencyLogSessionId ?? null) ||
          artifact.transparency_publisher_key !==
            (transparencyPublisherKey ?? null) ||
          artifact.transparency_checkpoint_digest !==
            (transparencyCheckpointDigest ?? null))
      ) {
        return jsonError("replay_artifact_conflict", 409);
      }
      return jsonResponse({
        ok: true,
        decision: "duplicate",
        idempotency_key: key,
        reason,
        epoch: head.epoch,
        digest: head.digest,
        checkpoint_digest: checkpointDigest,
      });
    }
    const queued = await this.dispatchReplayJob(key);
    return jsonResponse({
      ok: queued,
      decision: queued ? "queued" : "pending",
      idempotency_key: key,
      reason,
      epoch: head.epoch,
      digest: head.digest,
      checkpoint_digest: checkpointDigest,
    }, queued ? 202 : 503);
  }

  private async classifyDeliveredReplay(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    if (!isReplayJob(body.value)) return jsonError("invalid_replay_job", 400);
    const job = body.value;
    const row = this.replayOutboxAt(job.idempotency_key);
    if (!row) return jsonError("replay_job_not_found", 404);
    if (row.status === "delivered" && row.replay_decision) {
      return jsonResponse({
        ok: true,
        decision: row.replay_decision,
        transport: "delivery_duplicate",
        mode,
        unit,
        idempotency_key: job.idempotency_key,
      });
    }
    const anchorMatchesJob = this.replayJobMatchesStoredEvidence(job, row);
    const artifact = this.replayArtifactAt(job.idempotency_key);
    const checkpointLinkValid = Boolean(
      artifact &&
        job.checkpoint_digest &&
        row.checkpoint_digest === job.checkpoint_digest &&
        artifact.checkpoint_digest === job.checkpoint_digest,
    );
    const replayStarted = performance.now();
    const verification = artifact && checkpointLinkValid &&
        mode === "pve" && artifact.kind === "pve-v2"
      ? await verifyPveReplayBundle(
        artifact.bundle_hex,
        this.config()?.session_id ?? "",
        this.config()?.authority_key ?? "",
        artifact.checkpoint_digest,
      )
      : artifact && checkpointLinkValid &&
          mode === "pvp" && artifact.kind === "pvp-v1"
      ? await verifyPvpReplayBundle(
        artifact.bundle_hex,
        this.config()?.session_id ?? "",
        this.config()?.authority_key ?? "",
        artifact.checkpoint_digest,
      )
      : artifact && checkpointLinkValid &&
          mode === "open" && artifact.kind === "open-pve-v2" &&
          artifact.audit_checkpoint_digest &&
          artifact.seal_checkpoint_digest &&
          artifact.transparency_log_session_id &&
          artifact.transparency_publisher_key &&
          artifact.transparency_checkpoint_digest
      ? await verifyOpenWorldPveReplayBundle(
        artifact.bundle_hex,
        this.config()?.session_id ?? "",
        artifact.target_session_id,
        this.config()?.authority_key ?? "",
        artifact.transparency_log_session_id,
        artifact.transparency_publisher_key,
        artifact.transparency_checkpoint_digest,
        artifact.audit_checkpoint_digest,
        artifact.seal_checkpoint_digest,
        artifact.checkpoint_digest,
      )
      : undefined;
    const replayComputeMs = verification
      ? performance.now() - replayStarted
      : null;
    const itemCreations = artifact?.kind === "open-pve-v2" && verification?.ok
      ? normalizeVerifiedItemCreations(
        verification,
      )
      : [];
    const itemCreationCheckpointBound = itemCreations !== undefined &&
      (artifact?.kind !== "open-pve-v2" ||
        itemCreations.every((item) =>
          item.checkpoint_digest === artifact.checkpoint_digest
        ));
    let decision = await classifyCentralReplayArtifacts({
      anchorMatchesJob,
      transcriptPresent: artifact !== undefined,
      checkpointLinkValid,
      kernelReplayComplete: verification?.complete ?? false,
      kernelReplayMatches: (verification?.ok ?? false) &&
        itemCreations !== undefined &&
        itemCreationCheckpointBound,
    });
    const itemCreationConflictFree = itemCreations !== undefined &&
      this.itemCreationsCanBeStored(itemCreations);
    const creationPersistenceAllowed = await marketplaceCreationPersistAllowed({
      openWorldBoundary: artifact?.kind === "open-pve-v2",
      centralReplayVerified: decision === "verified",
      summaryNormalized: itemCreations !== undefined,
      checkpointBound: itemCreationCheckpointBound,
      conflictFree: itemCreationConflictFree,
    });
    if (artifact?.kind === "open-pve-v2" &&
      decision === "verified" &&
      !creationPersistenceAllowed) {
      decision = "replay_mismatch";
    }
    const replayError = verification && !verification.ok
      ? verification.error
      : itemCreations === undefined
      ? "invalid_verified_item_creations"
      : decision === "replay_mismatch" && verification?.ok
      ? "verified_item_creation_conflict"
      : null;
    const decidedAt = Date.now();
    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec(
        `UPDATE replay_outbox
         SET status = 'delivered', delivered_at = ?, replay_decision = ?,
             replay_error = ?, replay_compute_ms = ?, decided_at = ?
         WHERE idempotency_key = ?`,
        decidedAt,
        decision,
        replayError,
        replayComputeMs,
        decidedAt,
        job.idempotency_key,
      );
      if (creationPersistenceAllowed && itemCreations) {
        this.storeVerifiedItemCreations(
          itemCreations,
          job.idempotency_key,
          decidedAt,
        );
      }
    });
    return jsonResponse({
      ok: true,
      decision,
      transport: "delivered",
      mode,
      unit,
      idempotency_key: job.idempotency_key,
      replay: verification,
    });
  }

  private async checkMarketListing(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Promise<Response> {
    if (mode !== "open") return jsonError("not_found", 404);
    const config = this.config();
    if (!config || config.mode !== mode || config.unit_key !== unit) {
      return jsonError("shard_not_configured", 409);
    }
    const body = await readJsonBody(request);
    if (!body.ok) return body.response;
    const assetId = stringField(body.value, "asset_id");
    const sellerId = stringField(body.value, "seller_id");
    const inventoryBundleHex = stringField(
      body.value,
      "inventory_bundle_hex",
    );
    const inventoryCheckpointDigest = stringField(
      body.value,
      "inventory_checkpoint_digest",
    );
    const inventoryGameManifestDigest = stringField(
      body.value,
      "inventory_game_manifest_digest",
    );
    if (
      !assetId || assetId.length > 4_096 ||
      !sellerId || sellerId.length > 4_096
    ) {
      return jsonError("invalid_market_listing", 400);
    }
    const proofFieldCount = [
      inventoryBundleHex,
      inventoryCheckpointDigest,
      inventoryGameManifestDigest,
    ].filter((value) => value !== undefined).length;
    if (
      proofFieldCount !== 0 &&
      (proofFieldCount !== 3 ||
        !inventoryBundleHex ||
        inventoryBundleHex.length > MAX_INVENTORY_BUNDLE_HEX_CHARS ||
        inventoryBundleHex.length % 2 !== 0 ||
        !/^[0-9a-f]+$/.test(inventoryBundleHex) ||
        !inventoryCheckpointDigest ||
        !/^[0-9a-f]{64}$/.test(inventoryCheckpointDigest) ||
        !inventoryGameManifestDigest ||
        !/^[0-9a-f]{64}$/.test(inventoryGameManifestDigest))
    ) {
      return jsonError("invalid_inventory_listing_proof", 400);
    }
    let creation = this.verifiedItemCreationAt(assetId);
    if (!creation) {
      return jsonResponse({
        ok: true,
        allowed: false,
        decision: "creation_not_verified",
        asset_id: assetId,
        seller_id: sellerId,
      }, 404);
    }
    if (creation.status !== "eligible") {
      return jsonResponse({
        ok: true,
        allowed: false,
        decision: "creation_revoked",
        asset_id: assetId,
        seller_id: sellerId,
      }, 403);
    }
    let previousCheckpoint: string | undefined;
    let approvalCount: number | undefined;
    let requiredApprovals: number | undefined;
    if (
      inventoryBundleHex &&
      inventoryCheckpointDigest &&
      inventoryGameManifestDigest
    ) {
      if (
        creation.inventory_game_manifest_digest !== null &&
        creation.inventory_game_manifest_digest !== inventoryGameManifestDigest
      ) {
        return jsonResponse({
          ok: true,
          allowed: false,
          decision: "inventory_manifest_mismatch",
          asset_id: assetId,
          seller_id: sellerId,
        }, 409);
      }
      const verification = await verifyInventoryListingProofBundle(
        inventoryBundleHex,
        creation.inventory_session_id,
        config.authority_key,
        inventoryCheckpointDigest,
        inventoryGameManifestDigest,
        creation.asset_id,
        creation.initial_owner_id,
        creation.item_type,
        creation.quantity,
        creation.source_event,
        creation.output_index,
        sellerId,
        false,
      );
      if (!verification.ok) {
        return jsonResponse({
          ok: true,
          allowed: false,
          decision: "inventory_proof_refused",
          proof_error: verification.error,
          asset_id: assetId,
          seller_id: sellerId,
        }, 403);
      }
      const sameHead = verification.checkpoint_digest ===
        creation.inventory_checkpoint_digest;
      if (sameHead) {
        if (
          verification.epoch !== creation.inventory_epoch ||
          verification.current_owner_id !== creation.current_owner_id ||
          verification.version !== creation.current_version
        ) {
          return jsonResponse({
            ok: true,
            allowed: false,
            decision: "inventory_head_conflict",
            asset_id: assetId,
            seller_id: sellerId,
          }, 409);
        }
      } else if (!await inventoryHeadAdvanceAllowed({
        creationEligible: creation.status === "eligible",
        proofVerified: true,
        manifestMatches: creation.inventory_game_manifest_digest === null ||
          creation.inventory_game_manifest_digest === inventoryGameManifestDigest,
        parentMatches: verification.previous_checkpoint ===
          creation.inventory_checkpoint_digest,
        epochAdvances: verification.epoch > creation.inventory_epoch,
        ownerVersionConsistent:
          verification.current_owner_id === creation.current_owner_id
            ? verification.version >= creation.current_version
            : verification.version > creation.current_version,
      })) {
        return jsonResponse({
          ok: true,
          allowed: false,
          decision: "inventory_stale_or_wrong_parent",
          asset_id: assetId,
          seller_id: sellerId,
          current_checkpoint: creation.inventory_checkpoint_digest,
          submitted_previous_checkpoint: verification.previous_checkpoint,
        }, 409);
      } else {
        const expectedHead = creation.inventory_checkpoint_digest;
        const expectedEpoch = creation.inventory_epoch;
        let advanced = false;
        this.ctx.storage.transactionSync(() => {
          const latest = this.verifiedItemCreationAt(assetId);
          if (
            latest?.status === "eligible" &&
            latest.inventory_checkpoint_digest === expectedHead &&
            latest.inventory_epoch === expectedEpoch
          ) {
            this.ctx.storage.sql.exec(
              `UPDATE verified_item_creations
               SET current_owner_id = ?, current_version = ?,
                   inventory_checkpoint_digest = ?, inventory_epoch = ?,
                   inventory_game_manifest_digest = ?,
                   inventory_public_state_root = ?, inventory_last_event = ?
               WHERE asset_id = ?`,
              verification.current_owner_id,
              verification.version,
              verification.checkpoint_digest,
              verification.epoch,
              inventoryGameManifestDigest,
              verification.public_state_root,
              verification.last_event,
              assetId,
            );
            advanced = true;
          }
        });
        if (!advanced) {
          return jsonResponse({
            ok: true,
            allowed: false,
            decision: "inventory_head_raced",
            asset_id: assetId,
            seller_id: sellerId,
          }, 409);
        }
        creation = this.verifiedItemCreationAt(assetId) ?? creation;
      }
      previousCheckpoint = verification.previous_checkpoint;
      approvalCount = verification.approval_count;
      requiredApprovals = verification.required_approvals;
    }
    if (creation.current_owner_id !== sellerId) {
      return jsonResponse({
        ok: true,
        allowed: false,
        decision: "seller_mismatch",
        asset_id: assetId,
        seller_id: sellerId,
      }, 403);
    }
    return jsonResponse({
      ok: true,
      allowed: true,
      decision: "eligible_current_owner",
      asset_id: assetId,
      seller_id: sellerId,
      item_type: creation.item_type,
      quantity: creation.quantity,
      source_event: creation.source_event,
      checkpoint_digest: creation.inventory_checkpoint_digest,
      previous_checkpoint: previousCheckpoint,
      current_version: creation.current_version,
      inventory_epoch: creation.inventory_epoch,
      approval_count: approvalCount,
      required_approvals: requiredApprovals,
    });
  }

  private itemCreationsCanBeStored(
    creations: VerifiedItemCreation[],
  ): boolean {
    for (const creation of creations) {
      const existing = this.verifiedItemCreationAt(creation.asset_id);
      if (
        existing &&
        (existing.initial_owner_id !== creation.initial_owner_id ||
          existing.item_type !== creation.item_type ||
          existing.quantity !== creation.quantity ||
          existing.output_index !== creation.output_index ||
          existing.source_event !== creation.source_event ||
          existing.checkpoint_digest !== creation.checkpoint_digest ||
          existing.inventory_session_id !== creation.inventory_session_id ||
          existing.inventory_epoch !== creation.checkpoint_epoch)
      ) {
        return false;
      }
      const source = this.ctx.storage.sql.exec<VerifiedItemCreationRow>(
        `SELECT asset_id, initial_owner_id, item_type, quantity, output_index,
                source_event, checkpoint_digest, inventory_session_id,
                current_owner_id, current_version, inventory_checkpoint_digest,
                inventory_epoch, inventory_game_manifest_digest,
                inventory_public_state_root, inventory_last_event,
                replay_key, status, created_at
         FROM verified_item_creations
         WHERE source_event = ? AND output_index = ?`,
        creation.source_event,
        creation.output_index,
      ).toArray()[0];
      if (source && source.asset_id !== creation.asset_id) return false;
    }
    return true;
  }

  private storeVerifiedItemCreations(
    creations: VerifiedItemCreation[],
    replayKey: string,
    createdAt: number,
  ): void {
    for (const creation of creations) {
      this.ctx.storage.sql.exec(
        `INSERT OR IGNORE INTO verified_item_creations
         (asset_id, initial_owner_id, item_type, quantity, output_index,
          source_event, checkpoint_digest, inventory_session_id,
          current_owner_id, current_version, inventory_checkpoint_digest,
          inventory_epoch, inventory_game_manifest_digest,
          inventory_public_state_root, inventory_last_event,
          replay_key, status, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, NULL, NULL, NULL,
                 ?, 'eligible', ?)`,
        creation.asset_id,
        creation.initial_owner_id,
        creation.item_type,
        creation.quantity,
        creation.output_index,
        creation.source_event,
        creation.checkpoint_digest,
        creation.inventory_session_id,
        creation.initial_owner_id,
        creation.checkpoint_digest,
        creation.checkpoint_epoch,
        replayKey,
        createdAt,
      );
    }
  }

  private replayJobMatchesStoredEvidence(
    job: ReplayJob,
    row: ReplayOutboxRow,
  ): boolean {
    const config = this.config();
    if (
      !config ||
      config.mode !== job.mode ||
      config.unit_key !== job.unit ||
      row.idempotency_key !== job.idempotency_key ||
      row.reason !== job.reason ||
      row.epoch !== job.epoch ||
      row.digest !== job.digest ||
      (row.checkpoint_digest ?? undefined) !== job.checkpoint_digest
    ) {
      return false;
    }
    if (job.reason === "fork") {
      return this.ctx.storage.sql.exec<{ count: number }>(
        `SELECT COUNT(*) AS count FROM anchor_forks
         WHERE observed_epoch = ? AND conflicting_digest = ?`,
        job.epoch,
        job.digest,
      ).toArray()[0]?.count === 1;
    }
    const history = this.historyAt(job.epoch);
    return history?.digest === job.digest;
  }

  private insertReplayOutbox(
    mode: AuditMode,
    unit: string,
    reason: ReplayReason,
    epoch: number,
    digest: string,
    checkpointDigest?: string,
  ): string | undefined {
    const key = replayIdempotencyKey(
      mode,
      unit,
      reason,
      epoch,
      digest,
      checkpointDigest,
    );
    this.ctx.storage.sql.exec(
      `INSERT OR IGNORE INTO replay_outbox
       (idempotency_key, reason, epoch, digest, checkpoint_digest, status,
        attempts, created_at)
       VALUES (?, ?, ?, ?, ?, 'pending', 0, ?)`,
      key,
      reason,
      epoch,
      digest,
      checkpointDigest ?? null,
      Date.now(),
    );
    const changed = this.ctx.storage.sql.exec<{ changed: number }>(
      "SELECT changes() AS changed",
    ).toArray()[0]?.changed ?? 0;
    return changed === 1 ? key : undefined;
  }

  private async dispatchReplayJob(key: string): Promise<boolean> {
    const row = this.replayOutboxAt(key);
    if (!row || row.status !== "pending") return row !== undefined;
    const config = this.config();
    if (!config) return false;
    const job: ReplayJob = {
      version: 1,
      idempotency_key: row.idempotency_key,
      mode: config.mode,
      unit: config.unit_key,
      reason: row.reason,
      epoch: row.epoch,
      digest: row.digest,
      ...(row.checkpoint_digest
        ? { checkpoint_digest: row.checkpoint_digest }
        : {}),
      created_at: row.created_at,
    };
    try {
      await this.auditEnv.REPLAY_QUEUE.send(job);
      this.ctx.storage.sql.exec(
        `UPDATE replay_outbox
         SET status = 'queued', attempts = attempts + 1, queued_at = ?
         WHERE idempotency_key = ? AND status = 'pending'`,
        Date.now(),
        key,
      );
      return true;
    } catch {
      this.ctx.storage.sql.exec(
        `UPDATE replay_outbox SET attempts = attempts + 1
         WHERE idempotency_key = ?`,
        key,
      );
      await this.ctx.storage.setAlarm(Date.now() + 1_000);
      return false;
    }
  }

  private insertHistoryAndHead(
    verified: VerifiedAnchor,
    envelopeHex: string,
  ): void {
    const now = Date.now();
    this.ctx.storage.sql.exec(
      `INSERT INTO anchor_history
       (epoch, digest, previous_digest, observer_id, anchor_root, anchor_size,
        envelope_hex, envelope_bytes, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      verified.epoch,
      verified.digest,
      verified.previous_digest,
      verified.observer_id,
      verified.anchor_root,
      verified.anchor_size,
      envelopeHex,
      verified.envelope_bytes,
      now,
    );
    this.ctx.storage.sql.exec(
      `INSERT INTO anchor_head
       (singleton, epoch, digest, previous_digest, observer_id, anchor_root,
        anchor_size, updated_at)
       VALUES (1, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(singleton) DO UPDATE SET
         epoch = excluded.epoch,
         digest = excluded.digest,
         previous_digest = excluded.previous_digest,
         observer_id = excluded.observer_id,
         anchor_root = excluded.anchor_root,
         anchor_size = excluded.anchor_size,
         updated_at = excluded.updated_at`,
      verified.epoch,
      verified.digest,
      verified.previous_digest,
      verified.observer_id,
      verified.anchor_root,
      verified.anchor_size,
      now,
    );
  }

  private getHead(mode: AuditMode, unit: string): Response {
    const config = this.config();
    const head = this.head();
    if (!config || !head) return jsonError("head_not_found", 404);
    return jsonResponse({ mode, unit, session_id: config.session_id, ...head });
  }

  private getGap(url: URL, mode: AuditMode, unit: string): Response {
    const afterEpoch = integerParam(url, "after_epoch");
    const targetEpoch = integerParam(url, "target_epoch");
    const maxItems = integerParam(url, "max_items");
    const afterDigest = url.searchParams.get("after_digest");
    if (
      afterEpoch === undefined ||
      targetEpoch === undefined ||
      maxItems === undefined ||
      maxItems <= 0 ||
      maxItems > MAX_GAP_ITEMS ||
      targetEpoch <= afterEpoch ||
      !afterDigest
    ) {
      return jsonError("invalid_gap_request", 400);
    }
    const rows = this.ctx.storage.sql.exec<HistoryRow>(
      `SELECT epoch, digest, previous_digest, observer_id, anchor_root,
              anchor_size, envelope_hex, envelope_bytes, updated_at
       FROM anchor_history
       WHERE epoch > ? AND epoch <= ?
       ORDER BY epoch ASC
       LIMIT ?`,
      afterEpoch,
      targetEpoch,
      maxItems,
    ).toArray();
    let expectedEpoch = afterEpoch + 1;
    let expectedPrevious = afterDigest;
    for (const row of rows) {
      if (row.epoch !== expectedEpoch || row.previous_digest !== expectedPrevious) {
        return jsonError("gap_source_not_contiguous", 409);
      }
      expectedEpoch += 1;
      expectedPrevious = row.digest;
    }
    if (rows.length === 0) return jsonError("gap_unavailable", 404);
    return jsonResponse({
      mode,
      unit,
      has_more: rows.at(-1)!.epoch < targetEpoch,
      envelopes: rows.map((row) => row.envelope_hex),
    });
  }

  private getStats(mode: AuditMode, unit: string): Response {
    const history = this.scalarCount("anchor_history");
    const forks = this.scalarCount("anchor_forks");
    const bytes = this.ctx.storage.sql.exec<{ total: number }>(
      "SELECT COALESCE(SUM(envelope_bytes), 0) AS total FROM anchor_history",
    ).toArray()[0]?.total ?? 0;
    const replayArtifacts = this.ctx.storage.sql.exec<{
      stored: number;
      bytes: number;
    }>(
      `SELECT COUNT(*) AS stored, COALESCE(SUM(bundle_bytes), 0) AS bytes
       FROM replay_artifacts`,
    ).toArray()[0] ?? { stored: 0, bytes: 0 };
    const replayCompute = this.ctx.storage.sql.exec<{
      count: number;
      mean_ms: number;
      max_ms: number;
    }>(
      `SELECT COUNT(replay_compute_ms) AS count,
              COALESCE(AVG(replay_compute_ms), 0) AS mean_ms,
              COALESCE(MAX(replay_compute_ms), 0) AS max_ms
       FROM replay_outbox`,
    ).toArray()[0] ?? { count: 0, mean_ms: 0, max_ms: 0 };
    const itemCreations = this.ctx.storage.sql.exec<{
      eligible: number;
      revoked: number;
    }>(
      `SELECT
         SUM(CASE WHEN status = 'eligible' THEN 1 ELSE 0 END) AS eligible,
         SUM(CASE WHEN status = 'revoked' THEN 1 ELSE 0 END) AS revoked
       FROM verified_item_creations`,
    ).toArray()[0] ?? { eligible: 0, revoked: 0 };
    return jsonResponse({
      mode,
      unit,
      history,
      forks,
      envelope_bytes: bytes,
      replay_outbox: {
        pending: this.replayCount("pending"),
        queued: this.replayCount("queued"),
        delivered: this.replayCount("delivered"),
      },
      replay_decisions: {
        awaiting_transcript: this.replayDecisionCount("awaiting_transcript"),
        verified: this.replayDecisionCount("verified"),
        refused: this.replayRefusalCount(),
      },
      replay_artifacts: replayArtifacts,
      replay_compute: replayCompute,
      verified_item_creations: {
        eligible: itemCreations.eligible ?? 0,
        revoked: itemCreations.revoked ?? 0,
      },
      policy: AUDIT_MODE_POLICIES[mode],
    });
  }

  private openWebSocket(
    request: Request,
    mode: AuditMode,
    unit: string,
  ): Response {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return jsonError("expected_websocket", 426);
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.serializeAttachment({ mode, unit });
    this.ctx.acceptWebSocket(server);
    server.send(JSON.stringify({ type: "connected", mode, unit, head: this.head() }));
    return new Response(null, { status: 101, webSocket: client });
  }

  private broadcast(value: unknown): void {
    const message = JSON.stringify(value);
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.send(message);
      } catch {
        // A later close event removes an unhealthy hibernating socket.
      }
    }
  }

  private config(): AuditConfigRow | undefined {
    return this.ctx.storage.sql.exec<AuditConfigRow>(
      `SELECT mode, unit_key, session_id, authority_key, initial_epoch,
              initial_previous_digest, created_at
       FROM audit_config WHERE singleton = 1`,
    ).toArray()[0];
  }

  private head(): HeadRow | undefined {
    return this.ctx.storage.sql.exec<HeadRow>(
      `SELECT epoch, digest, previous_digest, observer_id, anchor_root,
              anchor_size, updated_at
       FROM anchor_head WHERE singleton = 1`,
    ).toArray()[0];
  }

  private historyAt(epoch: number): HistoryRow | undefined {
    return this.ctx.storage.sql.exec<HistoryRow>(
      `SELECT epoch, digest, previous_digest, observer_id, anchor_root,
              anchor_size, envelope_hex, envelope_bytes, updated_at
       FROM anchor_history WHERE epoch = ?`,
      epoch,
    ).toArray()[0];
  }

  private replayOutboxAt(key: string): ReplayOutboxRow | undefined {
    return this.ctx.storage.sql.exec<ReplayOutboxRow>(
      `SELECT idempotency_key, reason, epoch, digest, status, attempts,
              checkpoint_digest, created_at, queued_at, delivered_at,
              replay_decision, replay_error, replay_compute_ms, decided_at
       FROM replay_outbox WHERE idempotency_key = ?`,
      key,
    ).toArray()[0];
  }

  private replayArtifactAt(key: string): ReplayArtifactRow | undefined {
    return this.ctx.storage.sql.exec<ReplayArtifactRow>(
      `SELECT idempotency_key, kind, checkpoint_digest, target_session_id,
              audit_checkpoint_digest, seal_checkpoint_digest,
              transparency_log_session_id, transparency_publisher_key,
              transparency_checkpoint_digest, bundle_hex,
              bundle_bytes, created_at
       FROM replay_artifacts WHERE idempotency_key = ?`,
      key,
    ).toArray()[0];
  }

  private verifiedItemCreationAt(
    assetId: string,
  ): VerifiedItemCreationRow | undefined {
    return this.ctx.storage.sql.exec<VerifiedItemCreationRow>(
      `SELECT asset_id, initial_owner_id, item_type, quantity, output_index,
              source_event, checkpoint_digest, inventory_session_id,
              current_owner_id, current_version, inventory_checkpoint_digest,
              inventory_epoch, inventory_game_manifest_digest,
              inventory_public_state_root, inventory_last_event,
              replay_key, status, created_at
       FROM verified_item_creations WHERE asset_id = ?`,
      assetId,
    ).toArray()[0];
  }

  private replayCount(status: ReplayOutboxRow["status"]): number {
    return this.ctx.storage.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM replay_outbox WHERE status = ?",
      status,
    ).toArray()[0]?.count ?? 0;
  }

  private replayDecisionCount(decision: CentralReplayArtifactDecision): number {
    return this.ctx.storage.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM replay_outbox WHERE replay_decision = ?",
      decision,
    ).toArray()[0]?.count ?? 0;
  }

  private replayRefusalCount(): number {
    return this.ctx.storage.sql.exec<{ count: number }>(
      `SELECT COUNT(*) AS count FROM replay_outbox
       WHERE replay_decision IS NOT NULL
         AND replay_decision NOT IN ('awaiting_transcript', 'verified')`,
    ).toArray()[0]?.count ?? 0;
  }

  private scalarCount(table: "anchor_history" | "anchor_forks"): number {
    return this.ctx.storage.sql.exec<{ count: number }>(
      `SELECT COUNT(*) AS count FROM ${table}`,
    ).toArray()[0]?.count ?? 0;
  }

  private addAuditConfigColumnIfMissing(name: string, sqlType: string): void {
    const columns = this.ctx.storage.sql.exec<{ name: string }>(
      "PRAGMA table_info(audit_config)",
    ).toArray();
    if (!columns.some((column) => column.name === name)) {
      this.ctx.storage.sql.exec(
        `ALTER TABLE audit_config ADD COLUMN ${name} ${sqlType}`,
      );
    }
  }

  private addReplayOutboxColumnIfMissing(name: string, sqlType: string): void {
    const columns = this.ctx.storage.sql.exec<{ name: string }>(
      "PRAGMA table_info(replay_outbox)",
    ).toArray();
    if (!columns.some((column) => column.name === name)) {
      this.ctx.storage.sql.exec(
        `ALTER TABLE replay_outbox ADD COLUMN ${name} ${sqlType}`,
      );
    }
  }

  private addVerifiedItemCreationColumnIfMissing(
    name: string,
    sqlType: string,
  ): void {
    const columns = this.ctx.storage.sql.exec<{ name: string }>(
      "PRAGMA table_info(verified_item_creations)",
    ).toArray();
    if (!columns.some((column) => column.name === name)) {
      this.ctx.storage.sql.exec(
        `ALTER TABLE verified_item_creations ADD COLUMN ${name} ${sqlType}`,
      );
    }
  }

  private migrateReplayArtifacts(): void {
    const schema = this.ctx.storage.sql.exec<{ sql: string }>(
      `SELECT sql FROM sqlite_master
       WHERE type = 'table' AND name = 'replay_artifacts'`,
    ).toArray()[0]?.sql;
    if (
      !schema ||
      (schema.includes("'open-pve-v2'") &&
        schema.includes("'pve-v2'") &&
        schema.includes("target_session_id") &&
        schema.includes("audit_checkpoint_digest") &&
        schema.includes("seal_checkpoint_digest") &&
        schema.includes("transparency_log_session_id") &&
        schema.includes("transparency_publisher_key") &&
        schema.includes("transparency_checkpoint_digest"))
    ) return;
    const hasTargetSession = schema.includes("target_session_id");
    const hasAuditCheckpoint = schema.includes("audit_checkpoint_digest");
    const hasSealCheckpoint = schema.includes("seal_checkpoint_digest");
    const hasTransparencyLogSession = schema.includes(
      "transparency_log_session_id",
    );
    const hasTransparencyPublisher = schema.includes(
      "transparency_publisher_key",
    );
    const hasTransparencyCheckpoint = schema.includes(
      "transparency_checkpoint_digest",
    );
    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec(
        "ALTER TABLE replay_artifacts RENAME TO replay_artifacts_legacy",
      );
      this.ctx.storage.sql.exec(`
        CREATE TABLE replay_artifacts (
          idempotency_key TEXT PRIMARY KEY,
          kind TEXT NOT NULL CHECK (
            kind IN ('pve-v1', 'pve-v2', 'pvp-v1', 'open-pve-v1', 'open-pve-v2')
          ),
          checkpoint_digest TEXT NOT NULL,
          target_session_id TEXT NOT NULL,
          audit_checkpoint_digest TEXT,
          seal_checkpoint_digest TEXT,
          transparency_log_session_id TEXT,
          transparency_publisher_key TEXT,
          transparency_checkpoint_digest TEXT,
          bundle_hex TEXT NOT NULL,
          bundle_bytes INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        )
      `);
      const targetSessionExpression = hasTargetSession
        ? "target_session_id"
        : "(SELECT session_id FROM audit_config LIMIT 1)";
      const auditCheckpointExpression = hasAuditCheckpoint
        ? "audit_checkpoint_digest"
        : "NULL";
      const sealCheckpointExpression = hasSealCheckpoint
        ? "seal_checkpoint_digest"
        : "NULL";
      const transparencyLogSessionExpression = hasTransparencyLogSession
        ? "transparency_log_session_id"
        : "NULL";
      const transparencyPublisherExpression = hasTransparencyPublisher
        ? "transparency_publisher_key"
        : "NULL";
      const transparencyCheckpointExpression = hasTransparencyCheckpoint
        ? "transparency_checkpoint_digest"
        : "NULL";
      this.ctx.storage.sql.exec(`
        INSERT INTO replay_artifacts
        (idempotency_key, kind, checkpoint_digest, target_session_id,
         audit_checkpoint_digest, seal_checkpoint_digest,
         transparency_log_session_id, transparency_publisher_key,
         transparency_checkpoint_digest, bundle_hex, bundle_bytes, created_at)
        SELECT idempotency_key, kind, checkpoint_digest,
               ${targetSessionExpression}, ${auditCheckpointExpression},
               ${sealCheckpointExpression}, ${transparencyLogSessionExpression},
               ${transparencyPublisherExpression},
               ${transparencyCheckpointExpression}, bundle_hex, bundle_bytes,
               created_at
        FROM replay_artifacts_legacy
      `);
      this.ctx.storage.sql.exec("DROP TABLE replay_artifacts_legacy");
    });
  }
}

function parseRoute(pathname: string): {
  mode: AuditMode;
  unit: string;
  action: string;
} | undefined {
  const parts = pathname.split("/").filter(Boolean);
  if (parts.length !== 4 || parts[0] !== "v1" || !isAuditMode(parts[1])) {
    return undefined;
  }
  const unit = decodeURIComponent(parts[2]);
  if (!isUnitKey(unit)) return undefined;
  return { mode: parts[1], unit, action: parts[3] };
}

function authorized(request: Request, token: string | undefined): boolean {
  return Boolean(token) && request.headers.get("authorization") === `Bearer ${token}`;
}

async function checkpointWitnessSourceBucket(
  request: Request,
  secret: string,
): Promise<string> {
  const source = request.headers.get("cf-connecting-ip") ?? "unknown-source";
  if (witnessSourceBucketKeySecret !== secret || !witnessSourceBucketKeyPromise) {
    witnessSourceBucketKeySecret = secret;
    witnessSourceBucketKeyPromise = crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
  }
  const key = await witnessSourceBucketKeyPromise;
  const digest = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`checkpoint-witness-source-v1:${source}`),
  );
  return Array.from(new Uint8Array(digest), (value) =>
    value.toString(16).padStart(2, "0")
  ).join("");
}

function isExplicitReplayReason(
  mode: AuditMode,
  value: string,
): value is ReplayReason {
  return EXPLICIT_REPLAY_REASONS[mode].has(value as ReplayReason);
}

function replayIdempotencyKey(
  mode: AuditMode,
  unit: string,
  reason: ReplayReason,
  epoch: number,
  digest: string,
  checkpointDigest?: string,
): string {
  const base = `replay-v1:${mode}:${unit}:${reason}:${epoch}:${digest}`;
  return checkpointDigest ? `${base}:${checkpointDigest}` : base;
}

function isReplayJob(value: unknown): value is ReplayJob {
  if (!value || typeof value !== "object") return false;
  const job = value as Partial<ReplayJob>;
  return job.version === 1 &&
    typeof job.idempotency_key === "string" &&
    job.idempotency_key.length <= 1_024 &&
    typeof job.mode === "string" &&
    isAuditMode(job.mode) &&
    typeof job.unit === "string" &&
    isUnitKey(job.unit) &&
    typeof job.reason === "string" &&
    isReplayReason(job.reason) &&
    typeof job.epoch === "number" &&
    Number.isSafeInteger(job.epoch) &&
    job.epoch >= 0 &&
    typeof job.digest === "string" &&
    /^[0-9a-f]{64}$/.test(job.digest) &&
    (job.checkpoint_digest === undefined ||
      (typeof job.checkpoint_digest === "string" &&
        /^[0-9a-f]{64}$/.test(job.checkpoint_digest))) &&
    typeof job.created_at === "number" &&
    Number.isSafeInteger(job.created_at) &&
    job.created_at >= 0 &&
    job.idempotency_key === replayIdempotencyKey(
      job.mode,
      job.unit,
      job.reason,
      job.epoch,
      job.digest,
      job.checkpoint_digest,
    );
}

function isCheckpointDeliveryJob(value: unknown): value is CheckpointDeliveryJob {
  if (!value || typeof value !== "object") return false;
  const job = value as Partial<CheckpointDeliveryJob>;
  const boundary = job.boundary;
  if (!boundary || typeof boundary !== "object") return false;
  return job.kind === "checkpoint-delivery-v1" &&
    job.version === 1 &&
    typeof job.mode === "string" &&
    isAuditMode(job.mode) &&
    typeof job.unit === "string" &&
    isUnitKey(job.unit) &&
    boundary.protocol_version > 0 &&
    Number.isSafeInteger(boundary.protocol_version) &&
    boundedNonEmptyString(boundary.purpose, 256) &&
    boundedNonEmptyString(boundary.manifest_digest, 4_096) &&
    boundedNonEmptyString(boundary.scope_id, 4_096) &&
    boundary.unit_id === job.unit &&
    boundedNonEmptyString(job.destination_id, 256) &&
    typeof job.initial_epoch === "number" &&
    Number.isSafeInteger(job.initial_epoch) &&
    job.initial_epoch >= -1 &&
    boundedNonEmptyString(job.initial_digest, 4_096) &&
    typeof job.epoch === "number" &&
    Number.isSafeInteger(job.epoch) &&
    job.epoch >= 0 &&
    boundedNonEmptyString(job.previous_checkpoint, 4_096) &&
    boundedNonEmptyString(job.checkpoint_digest, 4_096) &&
    boundedNonEmptyString(job.canonical_envelope, MAX_ENVELOPE_HEX_CHARS) &&
    isCheckpointDeliveryAuthentication(job.authentication) &&
    typeof job.created_order === "number" &&
    Number.isSafeInteger(job.created_order) &&
    job.created_order >= 0 &&
    typeof job.created_at === "number" &&
    Number.isSafeInteger(job.created_at) &&
    job.created_at >= 0 &&
    job.state === "in_flight" &&
    typeof job.idempotency_key === "string" &&
    job.idempotency_key === checkpointDeliveryIdempotencyKey(
      boundary,
      job.destination_id,
      job.epoch,
      job.checkpoint_digest,
    );
}

function isCheckpointReceiverConfiguration(
  value: unknown,
): value is CheckpointReceiverConfiguration {
  if (!value || typeof value !== "object") return false;
  const configuration = value as Partial<CheckpointReceiverConfiguration>;
  const boundary = configuration.boundary;
  return boundary !== undefined &&
    typeof boundary === "object" &&
    typeof boundary.protocol_version === "number" &&
    Number.isSafeInteger(boundary.protocol_version) &&
    boundary.protocol_version > 0 &&
    boundedNonEmptyString(boundary.purpose, 256) &&
    boundedNonEmptyString(boundary.manifest_digest, 4_096) &&
    boundedNonEmptyString(boundary.scope_id, 4_096) &&
    boundedNonEmptyString(boundary.unit_id, 256) &&
    isUnitKey(boundary.unit_id) &&
    boundedNonEmptyString(configuration.destination_id, 256) &&
    typeof configuration.initial_epoch === "number" &&
    Number.isSafeInteger(configuration.initial_epoch) &&
    configuration.initial_epoch >= -1 &&
    boundedNonEmptyString(configuration.initial_digest, 4_096) &&
    isCheckpointDeliveryAuthenticationPolicy(
      configuration.authentication_policy,
    );
}

function isCheckpointDeliveryAuthenticationPolicy(
  value: unknown,
): value is CheckpointDeliveryAuthenticationPolicy {
  if (!value || typeof value !== "object") return false;
  const policy = value as Partial<CheckpointDeliveryAuthenticationPolicy>;
  if (
    !boundedNonEmptyString(policy.producer_id, 256) ||
    typeof policy.producer_key !== "string" ||
    !/^[0-9a-f]{64}$/.test(policy.producer_key) ||
    !Array.isArray(policy.witnesses) ||
    policy.witnesses.length === 0 ||
    policy.witnesses.length > 32 ||
    typeof policy.required_approvals !== "number" ||
    !Number.isSafeInteger(policy.required_approvals) ||
    policy.required_approvals <= 0 ||
    policy.required_approvals > policy.witnesses.length
  ) return false;
  const ids = new Set<string>();
  const keys = new Set<string>();
  for (const value of policy.witnesses as unknown[]) {
    if (!value || typeof value !== "object") return false;
    const witness = value as Record<string, unknown>;
    const witnessId = witness.witness_id;
    const witnessKey = witness.witness_key;
    if (
      typeof witnessId !== "string" ||
      !boundedNonEmptyString(witnessId, 256) ||
      typeof witnessKey !== "string" ||
      !/^[0-9a-f]{64}$/.test(witnessKey) ||
      witnessId === policy.producer_id ||
      witnessKey === policy.producer_key ||
      ids.has(witnessId) ||
      keys.has(witnessKey)
    ) return false;
    ids.add(witnessId);
    keys.add(witnessKey);
  }
  return true;
}

function isCheckpointDeliveryAuthentication(
  value: unknown,
): value is CheckpointDeliveryAuthentication {
  if (!value || typeof value !== "object") return false;
  const authentication = value as Partial<CheckpointDeliveryAuthentication>;
  return authentication.version === 1 &&
    boundedNonEmptyString(authentication.producer_id, 256) &&
    typeof authentication.producer_key === "string" &&
    /^[0-9a-f]{64}$/.test(authentication.producer_key) &&
    typeof authentication.statement_digest === "string" &&
    /^[0-9a-f]{64}$/.test(authentication.statement_digest) &&
    typeof authentication.producer_signature === "string" &&
    /^[0-9a-f]{128}$/.test(authentication.producer_signature) &&
    Array.isArray(authentication.approvals) &&
    authentication.approvals.length <= 32 &&
    authentication.approvals.every(isCheckpointDeliveryApproval);
}

function isCheckpointDeliveryApproval(
  value: unknown,
): value is CheckpointDeliveryApproval {
  if (!value || typeof value !== "object") return false;
  const approval = value as Record<string, unknown>;
  return typeof approval.statement_digest === "string" &&
    /^[0-9a-f]{64}$/.test(approval.statement_digest) &&
    boundedNonEmptyString(
      typeof approval.witness_id === "string"
        ? approval.witness_id
        : undefined,
      256,
    ) &&
    typeof approval.witness_key === "string" &&
    /^[0-9a-f]{64}$/.test(approval.witness_key) &&
    typeof approval.digest === "string" &&
    /^[0-9a-f]{64}$/.test(approval.digest) &&
    typeof approval.signature === "string" &&
    /^[0-9a-f]{128}$/.test(approval.signature);
}

function isCheckpointAuthorityAck(
  value: unknown,
): value is SuccessfulCheckpointAuthorityAck {
  if (!value || typeof value !== "object") return false;
  const ack = value as Partial<CheckpointAuthorityAck>;
  return (ack.decision === "accepted" || ack.decision === "duplicate") &&
    boundedNonEmptyString(ack.authority_id, 256) &&
    typeof ack.boundary === "object" &&
    ack.boundary !== null &&
    typeof ack.epoch === "number" &&
    Number.isSafeInteger(ack.epoch) &&
    ack.epoch >= 0 &&
    boundedNonEmptyString(ack.checkpoint_digest, 4_096);
}

function checkpointAckMatchesJob(
  ack: CheckpointAuthorityAck,
  job: CheckpointDeliveryJob,
): boolean {
  return (ack.decision === "accepted" || ack.decision === "duplicate") &&
    ack.authority_id === job.destination_id &&
    sameCheckpointBoundary(ack.boundary, job.boundary) &&
    ack.epoch === job.epoch &&
    ack.checkpoint_digest === job.checkpoint_digest;
}

function sameCheckpointBoundary(
  left: CheckpointAuthorityAck["boundary"],
  right: CheckpointDeliveryJob["boundary"],
): boolean {
  return left.protocol_version === right.protocol_version &&
    left.purpose === right.purpose &&
    left.manifest_digest === right.manifest_digest &&
    left.scope_id === right.scope_id &&
    left.unit_id === right.unit_id;
}

function minimumDefined(
  left: number | undefined,
  right: number | undefined,
): number | undefined {
  if (left === undefined) return right;
  if (right === undefined) return left;
  return Math.min(left, right);
}

function isReplayReason(value: string): value is ReplayReason {
  return value === "fork" ||
    value === "sample" ||
    value === "challenge" ||
    value === "high_value" ||
    value === "dispute" ||
    value === "marketplace";
}

function normalizeVerifiedItemCreations(
  verification: unknown,
): VerifiedItemCreation[] | undefined {
  if (!verification || typeof verification !== "object") return undefined;
  const raw = (verification as Record<string, unknown>)[
    "verified_item_creations"
  ];
  if (!Array.isArray(raw)) return undefined;
  const assetIds = new Set<string>();
  const sourceOutputs = new Set<string>();
  const creations: VerifiedItemCreation[] = [];
  for (const value of raw) {
    if (!value || typeof value !== "object") return undefined;
    const item = value as Record<string, unknown>;
    const assetId = item.asset_id;
    const initialOwnerId = item.initial_owner_id;
    const itemType = item.item_type;
    const quantity = item.quantity;
    const outputIndex = item.output_index;
    const sourceEvent = item.source_event;
    const checkpointDigest = item.checkpoint_digest;
    const inventorySessionId = item.inventory_session_id;
    const checkpointEpoch = item.checkpoint_epoch;
    if (
      typeof assetId !== "string" ||
      assetId.length === 0 ||
      assetId.length > 4_096 ||
      typeof initialOwnerId !== "string" ||
      initialOwnerId.length === 0 ||
      initialOwnerId.length > 4_096 ||
      typeof itemType !== "string" ||
      itemType.length === 0 ||
      itemType.length > 4_096 ||
      typeof quantity !== "number" ||
      !Number.isSafeInteger(quantity) ||
      quantity <= 0 ||
      typeof outputIndex !== "number" ||
      !Number.isSafeInteger(outputIndex) ||
      outputIndex < 0 ||
      typeof sourceEvent !== "string" ||
      !/^[0-9a-f]{64}$/.test(sourceEvent) ||
      typeof checkpointDigest !== "string" ||
      !/^[0-9a-f]{64}$/.test(checkpointDigest) ||
      typeof inventorySessionId !== "string" ||
      inventorySessionId.length === 0 ||
      inventorySessionId.length > 4_096 ||
      typeof checkpointEpoch !== "number" ||
      !Number.isSafeInteger(checkpointEpoch) ||
      checkpointEpoch < 0 ||
      assetIds.has(assetId)
    ) {
      return undefined;
    }
    const sourceOutput = `${sourceEvent}:${outputIndex}`;
    if (sourceOutputs.has(sourceOutput)) return undefined;
    assetIds.add(assetId);
    sourceOutputs.add(sourceOutput);
    creations.push({
      asset_id: assetId,
      initial_owner_id: initialOwnerId,
      item_type: itemType,
      quantity,
      output_index: outputIndex,
      source_event: sourceEvent,
      checkpoint_digest: checkpointDigest,
      inventory_session_id: inventorySessionId,
      checkpoint_epoch: checkpointEpoch,
    });
  }
  return creations;
}

function integerParam(url: URL, name: string): number | undefined {
  const raw = url.searchParams.get(name);
  if (!raw || !/^-?[0-9]+$/.test(raw)) return undefined;
  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : undefined;
}

function stringField(value: unknown, name: string): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const field = (value as Record<string, unknown>)[name];
  return typeof field === "string" ? field : undefined;
}

function numberField(value: unknown, name: string): number | undefined {
  if (!value || typeof value !== "object") return undefined;
  const field = (value as Record<string, unknown>)[name];
  return typeof field === "number" && Number.isSafeInteger(field)
    ? field
    : undefined;
}

function booleanField(value: unknown, name: string): boolean | undefined {
  if (!value || typeof value !== "object") return undefined;
  const field = (value as Record<string, unknown>)[name];
  return typeof field === "boolean" ? field : undefined;
}

function stringArrayField(value: unknown, name: string): string[] | undefined {
  if (!value || typeof value !== "object") return undefined;
  const field = (value as Record<string, unknown>)[name];
  return Array.isArray(field) && field.every((item) => typeof item === "string")
    ? field
    : undefined;
}

function objectField(value: unknown, name: string): unknown {
  if (!value || typeof value !== "object") return undefined;
  const field = (value as Record<string, unknown>)[name];
  return field && typeof field === "object" ? field : undefined;
}

function hasOwnField(value: unknown, name: string): boolean {
  return Boolean(value) &&
    typeof value === "object" &&
    Object.prototype.hasOwnProperty.call(value, name);
}

function checkpointDeliveryAuthenticationArrayField(
  value: unknown,
  name: string,
): Array<{
  destination_id: string;
  authentication: CheckpointDeliveryAuthentication;
}> | undefined {
  if (!value || typeof value !== "object") return undefined;
  const field = (value as Record<string, unknown>)[name];
  if (!Array.isArray(field) || field.length > 32) return undefined;
  const result: Array<{
    destination_id: string;
    authentication: CheckpointDeliveryAuthentication;
  }> = [];
  for (const value of field) {
    if (!value || typeof value !== "object") return undefined;
    const record = value as Record<string, unknown>;
    const destinationId = record.destination_id;
    const authentication = record.authentication;
    if (
      typeof destinationId !== "string" ||
      !boundedNonEmptyString(destinationId, 256) ||
      !isCheckpointDeliveryAuthentication(authentication)
    ) return undefined;
    result.push({
      destination_id: destinationId,
      authentication,
    });
  }
  return result;
}

function checkpointWitnessCollectionReferenceArrayField(
  value: unknown,
  name: string,
): Array<{ destination_id: string; collection_id: string }> | undefined {
  if (!value || typeof value !== "object") return undefined;
  const field = (value as Record<string, unknown>)[name];
  if (!Array.isArray(field) || field.length > 32) return undefined;
  const result: Array<{ destination_id: string; collection_id: string }> = [];
  for (const value of field) {
    if (!value || typeof value !== "object") return undefined;
    const record = value as Record<string, unknown>;
    const destinationId = record.destination_id;
    const collectionId = record.collection_id;
    if (
      typeof destinationId !== "string" ||
      !boundedNonEmptyString(destinationId, 256) ||
      typeof collectionId !== "string" ||
      !boundedNonEmptyString(collectionId, 1_024)
    ) return undefined;
    result.push({ destination_id: destinationId, collection_id: collectionId });
  }
  return result;
}

function checkpointBoundaryFromConfig(config: {
  protocol_version: number;
  purpose: string;
  manifest_digest: string;
  scope_id: string;
  unit_id: string;
}): CheckpointReceiverConfiguration["boundary"] {
  return {
    protocol_version: config.protocol_version,
    purpose: config.purpose,
    manifest_digest: config.manifest_digest,
    scope_id: config.scope_id,
    unit_id: config.unit_id,
  };
}

function boundedNonEmptyString(
  value: string | undefined,
  maxLength: number,
): value is string {
  return value !== undefined && value.length > 0 && value.length <= maxLength;
}

function isMoonBitInt(value: number): boolean {
  return Number.isInteger(value) && value >= -2_147_483_648 && value <= 2_147_483_647;
}

function isCheckpointSealFaultPoint(
  value: string,
): value is CheckpointSealFaultPoint {
  return value === "after_history" ||
    value === "after_head" ||
    value === "after_outbox" ||
    value === "after_closure";
}

async function readJsonBody(request: Request): Promise<
  | { ok: true; value: unknown }
  | { ok: false; response: Response }
> {
  const declared = request.headers.get("content-length");
  if (declared && Number(declared) > MAX_JSON_BODY_BYTES) {
    return { ok: false, response: jsonError("body_too_large", 413) };
  }
  if (!request.body) {
    return { ok: false, response: jsonError("missing_body", 400) };
  }
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_JSON_BODY_BYTES) {
      await reader.cancel();
      return { ok: false, response: jsonError("body_too_large", 413) };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { ok: true, value: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { ok: false, response: jsonError("invalid_json", 400) };
  }
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function jsonError(error: string, status: number): Response {
  return jsonResponse({ ok: false, error }, status);
}
