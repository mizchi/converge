import {
  approveCheckpointWitnessCollection,
  signCheckpointWitnessApproval,
  type AuditMode,
  type PublicCheckpointWitnessCollection,
} from "../src/witness-client";
import {
  cleanWitnessAuthorityPathMs,
  cleanWitnessSealPathMs,
  summarizeLatency,
} from "../src/benchmark-metrics";
import {
  observeSingleCheckpointDelivery,
} from "../src/checkpoint-observation";

type AuditModule = typeof import("../../../target/js/release/build/mizchi/converge/x/game_audit/worker/worker.js");

const audit = await import(
  new URL(
    "../../../target/js/release/build/mizchi/converge/x/game_audit/worker/worker.js",
    import.meta.url,
  ).href
) as AuditModule;

interface SizeSummary {
  count: number;
  mean_bytes: number;
  p50_bytes: number;
  p95_bytes: number;
  p99_bytes: number;
  max_bytes: number;
}

interface AnchorFixture {
  ok: true;
  authority_key: string;
  epoch: number;
  previous_digest: string;
}

interface DeliveryFixture {
  ok: true;
  policy: PublicCheckpointWitnessCollection["authentication_policy"];
  authentication: PublicCheckpointWitnessCollection["producer_authentication"];
}

interface RunMeasurement {
  collection_start_ms: number;
  hostile_rejection_ms: number[];
  hostile_limit_ms: number;
  approval_roundtrip_ms: number[];
  quorum_wall_ms: number;
  server_collection_ms: number;
  seal_ms: number;
  authority_ack_ms: number;
  post_seal_ack_observation_ms: number;
  authority_ack_poll_attempts: number;
  authority_ack_decision: "accepted" | "duplicate";
  approval_bytes: number[];
}

type SourceMode = "synthetic-headers" | "single-egress";
type ApprovalMode = "sequential" | "parallel";
type CheckpointDispatchMode = "direct" | "deferred";

const BASE_URL = process.env.AUDIT_BASE_URL ?? "http://127.0.0.1:8787";
const ADMIN_TOKEN = process.env.AUDIT_ADMIN_TOKEN ?? "test-admin-token";
const RUNS = positiveInteger(process.env.AUDIT_WITNESS_BENCH_RUNS, 20);
const MODE = auditMode(process.env.AUDIT_WITNESS_BENCH_MODE ?? "pvp");
const LOCATION_HINT = process.env.AUDIT_LOCATION_HINT;
const SOURCE_MODE = sourceMode(
  process.env.AUDIT_WITNESS_BENCH_SOURCE_MODE ?? "synthetic-headers",
);
const APPROVAL_MODE = approvalMode(
  process.env.AUDIT_WITNESS_BENCH_APPROVAL_MODE ?? "sequential",
);
const CHECKPOINT_DISPATCH_MODE = checkpointDispatchMode(
  process.env.AUDIT_WITNESS_BENCH_DISPATCH_MODE ?? "direct",
);
const ACK_TIMEOUT_MS = positiveInteger(
  process.env.AUDIT_WITNESS_ACK_TIMEOUT_MS,
  30_000,
);
const ACK_POLL_INTERVAL_MS = positiveInteger(
  process.env.AUDIT_WITNESS_ACK_POLL_INTERVAL_MS,
  100,
);
const PRODUCER_SEED =
  "000102030405060708090a0b0c0d0e0f" +
  "101112131415161718191a1b1c1d1e1f";
const WITNESS_SEEDS = [
  "404142434445464748494a4b4c4d4e4f" +
    "505152535455565758595a5b5c5d5e5f",
  "606162636465666768696a6b6c6d6e6f" +
    "707172737475767778797a7b7c7d7e7f",
  "808182838485868788898a8b8c8d8e8f" +
    "909192939495969798999a9b9c9d9e9f",
  "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf" +
    "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf",
];
const WITNESS_IDS = WITNESS_SEEDS.map((_, index) => `checkpoint-witness-${index}`);
const HOSTILE_SOURCE = "192.0.2.10";
const VALID_SOURCE = "198.51.100.20";

const measurements: RunMeasurement[] = [];
for (let run = 0; run < RUNS; run++) measurements.push(await measureRun(run));

console.log(JSON.stringify({
  benchmark: "checkpoint-witness-authority-settlement-v2",
  generated_at: new Date().toISOString(),
  base_url: BASE_URL,
  mode: MODE,
  location_hint: LOCATION_HINT,
  runs: RUNS,
  crypto: "experimental_sha256_ed25519_unaudited",
  source_bucketing: "server_secret_hmac_sha256",
  statistics: {
    percentile_method: "nearest_rank",
  },
  load: {
    source_mode: SOURCE_MODE,
    approval_mode: APPROVAL_MODE,
    checkpoint_dispatch_mode: CHECKPOINT_DISPATCH_MODE,
    hostile_burst_size: 9,
    hostile_max_bursts: SOURCE_MODE === "single-egress" ? 3 : 1,
    hostile_source: SOURCE_MODE === "synthetic-headers"
      ? HOSTILE_SOURCE
      : "client-egress",
    valid_approvals_per_collection: 3,
    valid_source: SOURCE_MODE === "synthetic-headers"
      ? VALID_SOURCE
      : "client-egress-after-retry-after",
    authority_ack_timeout_ms: ACK_TIMEOUT_MS,
    authority_ack_poll_interval_ms: ACK_POLL_INTERVAL_MS,
  },
  latency: {
    collection_start: summarizeLatency(
      measurements.map((value) => value.collection_start_ms),
    ),
    hostile_rejection: summarizeLatency(
      measurements.flatMap((value) => value.hostile_rejection_ms),
    ),
    hostile_limit: summarizeLatency(
      measurements.map((value) => value.hostile_limit_ms),
    ),
    approval_roundtrip: summarizeLatency(
      measurements.flatMap((value) => value.approval_roundtrip_ms),
    ),
    quorum_wall: summarizeLatency(
      measurements.map((value) => value.quorum_wall_ms),
    ),
    clean_seal_path: summarizeLatency(measurements.map((value) =>
      cleanWitnessSealPathMs({
        collectionStartMs: value.collection_start_ms,
        quorumWallMs: value.quorum_wall_ms,
        sealMs: value.seal_ms,
      })
    )),
    clean_authority_path: summarizeLatency(measurements.map((value) =>
      cleanWitnessAuthorityPathMs({
        collectionStartMs: value.collection_start_ms,
        quorumWallMs: value.quorum_wall_ms,
        authorityAckMs: value.authority_ack_ms,
      })
    )),
    server_collection: summarizeLatency(
      measurements.map((value) => value.server_collection_ms),
    ),
    seal: summarizeLatency(measurements.map((value) => value.seal_ms)),
    authority_ack: summarizeLatency(
      measurements.map((value) => value.authority_ack_ms),
    ),
    post_seal_ack_observation: summarizeLatency(
      measurements.map((value) => value.post_seal_ack_observation_ms),
    ),
  },
  delivery: {
    acknowledged: measurements.length,
    ack_decisions: {
      accepted: measurements.filter((value) =>
        value.authority_ack_decision === "accepted"
      ).length,
      duplicate: measurements.filter((value) =>
        value.authority_ack_decision === "duplicate"
      ).length,
    },
    poll_attempts: summarizeLatency(
      measurements.map((value) => value.authority_ack_poll_attempts),
    ),
  },
  payload: {
    approval_request: summarizeBytes(
      measurements.flatMap((value) => value.approval_bytes),
    ),
  },
}, null, 2));

async function measureRun(run: number): Promise<RunMeasurement> {
  const nonce = `${Date.now()}-${run}-${crypto.randomUUID().slice(0, 8)}`;
  const unit = `witness-bench-${nonce}`;
  const sessionId = `cf:${MODE}:${unit}`;
  const destinationId = "authority-1";
  const anchor = JSON.parse(
    audit.audit_benchmark_make_anchor_envelope(
      PRODUCER_SEED,
      sessionId,
      "observer-witness-bench",
      0,
      "genesis",
    ),
  ) as AnchorFixture;
  await expectStatus(
    "configure",
    postJson(`/v1/${MODE}/${unit}/configure`, {
      session_id: sessionId,
      authority_key: anchor.authority_key,
      initial_epoch: anchor.epoch,
      initial_previous_digest: anchor.previous_digest,
    }, true, true),
    201,
  );

  const statement = {
    destination_id: destinationId,
    epoch: 0,
    previous_checkpoint: "genesis",
    checkpoint_digest: `checkpoint-${nonce}`,
    canonical_envelope: `canonical-envelope-${nonce}`,
  };
  const producerOnly = deliveryFixture(MODE, unit, statement, 0);
  await expectStatus(
    "checkpoint configure",
    postJson(`/v1/${MODE}/${unit}/checkpoint-configure`, {
      protocol_version: 1,
      purpose: "checkpoint-v1",
      manifest_digest: "manifest-1",
      initial_epoch: -1,
      initial_digest: "genesis",
      outbox_capacity: 8,
      destinations: [destinationId],
      authentication_policy: producerOnly.policy,
    }, true),
    201,
  );
  await expectStatus(
    "checkpoint closure",
    postJson(`/v1/${MODE}/${unit}/checkpoint-closures`, {
      epoch: 0,
      roster_digest: "roster-0",
      frontier_digest: "frontier-0",
      certificate_digest: "certificate-0",
      frontier_complete: true,
      conflict_free: true,
      quorum_satisfied: true,
    }, true),
    201,
  );

  const collectionStart = await timedFetch(
    endpoint(`/v1/${MODE}/${unit}/checkpoint-witness-collections`),
    jsonRequest({
      ...statement,
      deadline_at: Date.now() + 60_000,
      producer_authentication: producerOnly.authentication,
    }, true),
  );
  await requireStatus("collection start", collectionStart.response, 201);
  const collection = await collectionStart.response.json() as
    PublicCheckpointWitnessCollection;
  const validApproval = await signCheckpointWitnessApproval({
    collection,
    witnessId: WITNESS_IDS[0],
    witnessSeedHex: WITNESS_SEEDS[0],
  });
  const invalidApproval = { ...validApproval, witness_id: "mallory" };

  const hostileRequest = () => timedFetch(
    endpoint(`/v1/${MODE}/${unit}/checkpoint-witness-approvals`),
    jsonRequest({
      collection_id: collection.collection_id,
      approval: invalidApproval,
    }, false, SOURCE_MODE === "synthetic-headers" ? HOSTILE_SOURCE : undefined),
  );
  let hostileRejectionMs: number[];
  let limited: { response: Response; elapsed: number };
  if (SOURCE_MODE === "synthetic-headers") {
    hostileRejectionMs = [];
    for (let attempt = 0; attempt < 8; attempt++) {
      const rejected = await hostileRequest();
      await requireStatus("hostile rejection", rejected.response, 409);
      hostileRejectionMs.push(rejected.elapsed);
    }
    limited = await hostileRequest();
    await requireStatus("hostile rate limit", limited.response, 429);
  } else {
    const rejected: Array<{ response: Response; elapsed: number }> = [];
    const limitedResponses: Array<{ response: Response; elapsed: number }> = [];
    for (let burst = 0; burst < 3 && limitedResponses.length === 0; burst++) {
      const hostileResponses = await Promise.all(
        Array.from({ length: 9 }, hostileRequest),
      );
      rejected.push(...hostileResponses.filter(
        (response) => response.response.status === 409,
      ));
      limitedResponses.push(...hostileResponses.filter(
        (response) => response.response.status === 429,
      ));
      const unexpected = hostileResponses.filter((response) =>
        response.response.status !== 409 && response.response.status !== 429
      );
      if (unexpected.length > 0) {
        throw new Error(
          `hostile burst: unexpected statuses ${
            unexpected.map((response) => response.response.status)
          }`,
        );
      }
    }
    if (limitedResponses.length === 0) {
      throw new Error("hostile burst: no 429 within 3 bursts");
    }
    hostileRejectionMs = rejected.map((response) => response.elapsed);
    limited = limitedResponses[0];
    const retryAfterSeconds = Number(limited.response.headers.get("retry-after"));
    if (!Number.isFinite(retryAfterSeconds) || retryAfterSeconds < 0) {
      throw new Error("hostile rate limit omitted Retry-After");
    }
    await new Promise((resolve) =>
      setTimeout(resolve, retryAfterSeconds * 1_000 + 100)
    );
  }

  const approvalRoundtripMs: number[] = [];
  const approvalBytes: number[] = [];
  const quorumStarted = performance.now();
  const submitValidApproval = async (index: number) => {
    const started = performance.now();
    const submitted = await approveCheckpointWitnessCollection({
      baseUrl: BASE_URL,
      mode: MODE,
      unit,
      collectionId: collection.collection_id,
      witnessId: WITNESS_IDS[index],
      witnessSeedHex: WITNESS_SEEDS[index],
      ...(SOURCE_MODE === "synthetic-headers"
        ? { fetchImpl: sourcedFetch(VALID_SOURCE) }
        : {}),
    });
    return {
      ...submitted,
      elapsed: round(performance.now() - started),
    };
  };
  const submissions = APPROVAL_MODE === "parallel"
    ? await Promise.all(Array.from({ length: 3 }, (_, index) =>
      submitValidApproval(index)))
    : [];
  if (APPROVAL_MODE === "sequential") {
    for (let index = 0; index < 3; index++) {
      submissions.push(await submitValidApproval(index));
    }
  }
  const statuses = submissions.map((submission) => submission.httpStatus).sort();
  if (statuses.join(",") !== "201,202,202") {
    throw new Error(`valid approvals: expected 201,202,202, got ${statuses}`);
  }
  for (const submission of submissions) {
    approvalRoundtripMs.push(submission.elapsed);
    approvalBytes.push(submission.approvalBytes);
  }
  const finalResponse = submissions.find((submission) =>
    submission.httpStatus === 201
  )?.response;
  const quorumWallMs = round(performance.now() - quorumStarted);
  const ready = record(finalResponse);
  const createdAt = numberValue(ready.created_at);
  const readyAt = numberValue(ready.ready_at);
  if (createdAt === undefined || readyAt === undefined) {
    throw new Error("valid approval response omitted collection timing");
  }

  const seal = await timedFetch(
    endpoint(`/v1/${MODE}/${unit}/checkpoint-seals`),
    jsonRequest({
      epoch: statement.epoch,
      previous_checkpoint: statement.previous_checkpoint,
      checkpoint_digest: statement.checkpoint_digest,
      canonical_envelope: statement.canonical_envelope,
      destinations: [statement.destination_id],
      authentication_collection_ids: [{
        destination_id: statement.destination_id,
        collection_id: collection.collection_id,
      }],
    }, true, undefined, {
      "x-audit-checkpoint-dispatch": CHECKPOINT_DISPATCH_MODE,
    }),
  );
  await requireStatus("collection-backed seal", seal.response, 202);
  const authorityAck = await waitForCheckpointAuthorityAck(unit, statement);
  return {
    collection_start_ms: round(collectionStart.elapsed),
    hostile_rejection_ms: hostileRejectionMs.map(round),
    hostile_limit_ms: round(limited.elapsed),
    approval_roundtrip_ms: approvalRoundtripMs,
    quorum_wall_ms: quorumWallMs,
    server_collection_ms: readyAt - createdAt,
    seal_ms: round(seal.elapsed),
    authority_ack_ms: round(seal.elapsed + authorityAck.elapsed),
    post_seal_ack_observation_ms: round(authorityAck.elapsed),
    authority_ack_poll_attempts: authorityAck.attempts,
    authority_ack_decision: authorityAck.decision,
    approval_bytes: approvalBytes,
  };
}

async function waitForCheckpointAuthorityAck(
  unit: string,
  statement: {
    destination_id: string;
    epoch: number;
    checkpoint_digest: string;
  },
): Promise<{
  elapsed: number;
  attempts: number;
  decision: "accepted" | "duplicate";
}> {
  const started = performance.now();
  let attempts = 0;
  while (performance.now() - started < ACK_TIMEOUT_MS) {
    attempts += 1;
    const response = await fetch(
      endpoint(`/v1/${MODE}/${unit}/checkpoint-state`),
      { headers: { authorization: `Bearer ${ADMIN_TOKEN}` } },
    );
    await requireStatus("checkpoint state", response, 200);
    const observation = observeSingleCheckpointDelivery(
      await response.json(),
      {
        destinationId: statement.destination_id,
        epoch: statement.epoch,
        checkpointDigest: statement.checkpoint_digest,
      },
    );
    if (observation.state === "acknowledged") {
      return {
        elapsed: performance.now() - started,
        attempts,
        decision: observation.decision,
      };
    }
    await new Promise((resolve) => setTimeout(resolve, ACK_POLL_INTERVAL_MS));
  }
  throw new Error(
    `checkpoint authority ACK for ${MODE}:${unit} timed out after ${ACK_TIMEOUT_MS} ms`,
  );
}

function deliveryFixture(
  mode: AuditMode,
  unit: string,
  statement: {
    destination_id: string;
    epoch: number;
    previous_checkpoint: string;
    checkpoint_digest: string;
    canonical_envelope: string;
  },
  approvalCount: number,
): DeliveryFixture {
  return JSON.parse(audit.audit_benchmark_make_checkpoint_delivery_authentication(
    PRODUCER_SEED,
    "checkpoint-producer",
    WITNESS_SEEDS,
    WITNESS_IDS,
    3,
    approvalCount,
    1,
    "checkpoint-v1",
    "manifest-1",
    `cf:${mode}:${unit}`,
    unit,
    statement.destination_id,
    statement.epoch,
    statement.previous_checkpoint,
    statement.checkpoint_digest,
    statement.canonical_envelope,
  )) as DeliveryFixture;
}

function sourcedFetch(source: string): typeof fetch {
  return async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const headers = new Headers(request.headers);
    headers.set("cf-connecting-ip", source);
    return fetch(new Request(request, { headers }));
  };
}

function postJson(
  path: string,
  body: unknown,
  admin: boolean,
  withLocationHint = false,
): Promise<Response> {
  return fetch(endpoint(path, withLocationHint), jsonRequest(body, admin));
}

function jsonRequest(
  body: unknown,
  admin: boolean,
  source?: string,
  additionalHeaders: Record<string, string> = {},
): RequestInit {
  return {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(admin ? { authorization: `Bearer ${ADMIN_TOKEN}` } : {}),
      ...(source ? { "cf-connecting-ip": source } : {}),
      ...additionalHeaders,
    },
    body: JSON.stringify(body),
  };
}

function endpoint(path: string, withLocationHint = false): string {
  const url = new URL(path, BASE_URL);
  if (withLocationHint && LOCATION_HINT) {
    url.searchParams.set("location_hint", LOCATION_HINT);
  }
  return url.toString();
}

async function timedFetch(url: string, init: RequestInit): Promise<{
  response: Response;
  elapsed: number;
}> {
  const started = performance.now();
  const response = await fetch(url, init);
  return { response, elapsed: performance.now() - started };
}

async function expectStatus(
  label: string,
  responsePromise: Promise<Response>,
  expected: number,
): Promise<void> {
  await requireStatus(label, await responsePromise, expected);
}

async function requireStatus(
  label: string,
  response: Response,
  expected: number,
): Promise<void> {
  if (response.status !== expected) {
    throw new Error(
      `${label}: expected ${expected}, got ${response.status} ${await response.text()}`,
    );
  }
}

function summarizeBytes(values: number[]): SizeSummary {
  const summary = summarizeLatency(values);
  return {
    count: summary.count,
    mean_bytes: summary.mean_ms,
    p50_bytes: summary.p50_ms,
    p95_bytes: summary.p95_ms,
    p99_bytes: summary.p99_ms,
    max_bytes: summary.max_ms,
  };
}

function round(value: number): number {
  return Math.round(value * 1_000) / 1_000;
}

function positiveInteger(raw: string | undefined, fallback: number): number {
  const value = Number(raw);
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}

function auditMode(value: string): AuditMode {
  if (value === "pve" || value === "pvp" || value === "open") return value;
  throw new Error(`invalid AUDIT_WITNESS_BENCH_MODE: ${value}`);
}

function sourceMode(value: string): SourceMode {
  if (value === "synthetic-headers" || value === "single-egress") return value;
  throw new Error(`invalid AUDIT_WITNESS_BENCH_SOURCE_MODE: ${value}`);
}

function approvalMode(value: string): ApprovalMode {
  if (value === "sequential" || value === "parallel") return value;
  throw new Error(`invalid AUDIT_WITNESS_BENCH_APPROVAL_MODE: ${value}`);
}

function checkpointDispatchMode(value: string): CheckpointDispatchMode {
  if (value === "direct" || value === "deferred") return value;
  throw new Error(`invalid AUDIT_WITNESS_BENCH_DISPATCH_MODE: ${value}`);
}

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("expected object response");
  }
  return value as Record<string, unknown>;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
