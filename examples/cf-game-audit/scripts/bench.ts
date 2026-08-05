import {
  summarizeLatency,
  type LatencySummary,
} from "../src/benchmark-metrics";

type AuditModule = typeof import("../../../target/js/release/build/mizchi/converge/x/game_audit/worker/worker.js");

const audit = await import(
  new URL(
    "../../../target/js/release/build/mizchi/converge/x/game_audit/worker/worker.js",
    import.meta.url,
  ).href
) as AuditModule;

type AuditMode = "pve" | "pvp" | "open";
type ReplayReason = "challenge" | "dispute" | "sample";

interface Fixture {
  ok: true;
  envelope_hex: string;
  authority_key: string;
  digest: string;
  previous_digest: string;
  epoch: number;
}

interface ReplayFixture {
  ok: true;
  bundle_hex: string;
  bundle_bytes: number;
  checkpoint_digest: string;
}

interface OpenWorldReplayFixture extends ReplayFixture {
  asset_id: string;
  item_type: string;
  quantity: number;
  output_index: number;
  source_event: string;
  encounter_session_id: string;
  audit_checkpoint_digest: string;
  seal_checkpoint_digest: string;
  transparency_log_session_id: string;
  transparency_publisher_key: string;
  transparency_checkpoint_digest: string;
}

const BASE_URL = process.env.AUDIT_BASE_URL ?? "http://127.0.0.1:8787";
const ADMIN_TOKEN = process.env.AUDIT_ADMIN_TOKEN ?? "test-admin-token";
const HEADS = positiveInteger(process.env.AUDIT_BENCH_HEADS, 64);
const CONTENDERS = positiveInteger(process.env.AUDIT_BENCH_CONTENDERS, 16);
const PARALLEL_SHARDS = positiveInteger(process.env.AUDIT_BENCH_SHARDS, 8);
const HEADS_PER_SHARD = positiveInteger(
  process.env.AUDIT_BENCH_HEADS_PER_SHARD,
  8,
);
const MARKET_LISTING_READS = positiveInteger(
  process.env.AUDIT_BENCH_MARKET_LISTING_READS,
  20,
);
const LOCATION_HINT = process.env.AUDIT_LOCATION_HINT;
const BENCH_MODES = (process.env.AUDIT_BENCH_MODES ?? "pve,pvp,open")
  .split(",")
  .filter((mode): mode is AuditMode =>
    mode === "pve" || mode === "pvp" || mode === "open"
  );
const REPLAY_REASONS: Record<AuditMode, ReplayReason> = {
  pve: "challenge",
  pvp: "dispute",
  open: "sample",
};
const SEED =
  "000102030405060708090a0b0c0d0e0f" +
  "101112131415161718191a1b1c1d1e1f";
const PLAYER_SEED =
  "202122232425262728292a2b2c2d2e2f" +
  "303132333435363738393a3b3c3d3e3f";

function positiveInteger(raw: string | undefined, fallback: number): number {
  const value = Number(raw);
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}

function makeFixture(
  sessionId: string,
  observerId: string,
  epoch: number,
  previousDigest: string,
): Fixture {
  const value = JSON.parse(
    audit.audit_benchmark_make_anchor_envelope(
      SEED,
      sessionId,
      observerId,
      epoch,
      previousDigest,
    ),
  ) as Fixture;
  if (!value.ok) throw new Error("fixture generation failed");
  return value;
}

function makeChain(
  sessionId: string,
  observerId: string,
  count: number,
): Fixture[] {
  const fixtures: Fixture[] = [];
  let previous = "genesis";
  for (let epoch = 1; epoch <= count; epoch++) {
    const value = makeFixture(sessionId, observerId, epoch, previous);
    fixtures.push(value);
    previous = value.digest;
  }
  return fixtures;
}

function endpoint(path: string, withLocationHint = false): string {
  const url = new URL(path, BASE_URL);
  if (withLocationHint && LOCATION_HINT) {
    url.searchParams.set("location_hint", LOCATION_HINT);
  }
  return url.toString();
}

async function timedFetch(url: string, init?: RequestInit): Promise<{
  response: Response;
  elapsed: number;
}> {
  const started = performance.now();
  const response = await fetch(url, init);
  const elapsed = performance.now() - started;
  return { response, elapsed };
}

function round(value: number): number {
  return Math.round(value * 1_000) / 1_000;
}

async function configureUnit(
  mode: AuditMode,
  unit: string,
  sessionId: string,
  first: Fixture,
): Promise<number> {
  const result = await timedFetch(
    endpoint(`/v1/${mode}/${unit}/configure`, true),
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${ADMIN_TOKEN}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        session_id: sessionId,
        authority_key: first.authority_key,
        initial_epoch: first.epoch,
        initial_previous_digest: first.previous_digest,
      }),
    },
  );
  if (result.response.status !== 201) {
    throw new Error(
      `configure ${mode}: ${result.response.status} ${await result.response.text()}`,
    );
  }
  return result.elapsed;
}

async function submitFixture(
  mode: AuditMode,
  unit: string,
  fixture: Fixture,
): Promise<{ response: Response; elapsed: number }> {
  return timedFetch(endpoint(`/v1/${mode}/${unit}/anchors`), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ envelope_hex: fixture.envelope_hex }),
  });
}

async function runParallelShards(
  mode: AuditMode,
): Promise<Record<string, unknown>> {
  const nonce = `${Date.now()}-${crypto.randomUUID().slice(0, 8)}`;
  const shards = Array.from({ length: PARALLEL_SHARDS }, (_, index) => {
    const unit = `bench-${mode}-parallel-${nonce}-${index}`;
    const sessionId = `cf:${mode}:${unit}`;
    return {
      unit,
      sessionId,
      fixtures: makeChain(
        sessionId,
        `observer-${mode}-parallel-${index}`,
        HEADS_PER_SHARD,
      ),
    };
  });
  const configureLatencies = await Promise.all(
    shards.map((shard) =>
      configureUnit(
        mode,
        shard.unit,
        shard.sessionId,
        shard.fixtures[0],
      )
    ),
  );
  const commitLatencies: number[] = [];
  const started = performance.now();
  await Promise.all(
    shards.map(async (shard) => {
      for (const fixture of shard.fixtures) {
        const result = await submitFixture(mode, shard.unit, fixture);
        if (result.response.status !== 202) {
          throw new Error(
            `parallel commit ${mode}/${shard.unit}/${fixture.epoch}: ` +
              `${result.response.status} ${await result.response.text()}`,
          );
        }
        commitLatencies.push(result.elapsed);
      }
    }),
  );
  const wallMs = performance.now() - started;
  const totalHeads = PARALLEL_SHARDS * HEADS_PER_SHARD;
  return {
    shards: PARALLEL_SHARDS,
    heads_per_shard: HEADS_PER_SHARD,
    total_heads: totalHeads,
    configure: summarizeLatency(configureLatencies),
    commit: summarizeLatency(commitLatencies),
    wall_ms: round(wallMs),
    throughput_heads_per_second: round(totalHeads / (wallMs / 1_000)),
  };
}

async function measureReplayDelivery(
  mode: AuditMode,
  unit: string,
): Promise<{ result: Record<string, unknown>; stats: unknown }> {
  const reason = REPLAY_REASONS[mode];
  const sessionId = `cf:${mode}:${unit}`;
  const replayArtifact = mode === "pve"
    ? JSON.parse(
      audit.audit_benchmark_make_pve_replay_bundle(
        SEED,
        PLAYER_SEED,
        sessionId,
      ),
    ) as ReplayFixture
    : mode === "pvp"
    ? JSON.parse(
      audit.audit_benchmark_make_pvp_replay_bundle(
        SEED,
        PLAYER_SEED,
        sessionId,
      ),
    ) as ReplayFixture
    : JSON.parse(
      audit.audit_benchmark_make_open_world_pve_replay_bundle(
        SEED,
        PLAYER_SEED,
        sessionId,
        `${sessionId}:encounter-0`,
      ),
    ) as OpenWorldReplayFixture;
  const enqueue = await timedFetch(endpoint(`/v1/${mode}/${unit}/replay`), {
    method: "POST",
    headers: {
      authorization: `Bearer ${ADMIN_TOKEN}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      reason,
      ...(replayArtifact
        ? {
          bundle_hex: replayArtifact.bundle_hex,
          checkpoint_digest: replayArtifact.checkpoint_digest,
          ...(mode === "open"
            ? {
              target_session_id: (replayArtifact as OpenWorldReplayFixture)
                .encounter_session_id,
              audit_checkpoint_digest:
                (replayArtifact as OpenWorldReplayFixture)
                  .audit_checkpoint_digest,
              seal_checkpoint_digest:
                (replayArtifact as OpenWorldReplayFixture)
                  .seal_checkpoint_digest,
              transparency_log_session_id:
                (replayArtifact as OpenWorldReplayFixture)
                  .transparency_log_session_id,
              transparency_publisher_key:
                (replayArtifact as OpenWorldReplayFixture)
                  .transparency_publisher_key,
              transparency_checkpoint_digest:
                (replayArtifact as OpenWorldReplayFixture)
                  .transparency_checkpoint_digest,
            }
            : {}),
        }
        : {}),
    }),
  });
  if (enqueue.response.status !== 202) {
    throw new Error(
      `replay enqueue ${mode}: ${enqueue.response.status} ` +
        `${await enqueue.response.text()}`,
    );
  }
  const enqueueBody = await enqueue.response.json() as {
    idempotency_key: string;
  };
  const deliveryStarted = performance.now();
  let polls = 0;
  while (performance.now() - deliveryStarted < 10_000) {
    polls += 1;
    const statsResponse = await fetch(endpoint(`/v1/${mode}/${unit}/stats`));
    if (!statsResponse.ok) {
      throw new Error(`replay stats ${mode}: ${statsResponse.status}`);
    }
    const stats = await statsResponse.json() as {
      replay_outbox?: { delivered?: number };
      replay_decisions?: {
        awaiting_transcript?: number;
        verified?: number;
        refused?: number;
      };
    };
    if ((stats.replay_outbox?.delivered ?? 0) >= 1) {
      const auditDecision = (stats.replay_decisions?.verified ?? 0) > 0
        ? "verified"
        : (stats.replay_decisions?.awaiting_transcript ?? 0) > 0
        ? "awaiting_transcript"
        : "refused";
      let marketplaceListing: LatencySummary | undefined;
      let inventoryHeadAdvance:
        | { elapsed_ms: number; bundle_bytes: number }
        | undefined;
      if (mode === "open") {
        const openReplay = replayArtifact as OpenWorldReplayFixture;
        const inventory = JSON.parse(
          audit.audit_benchmark_make_inventory_listing_proof_bundle(
            SEED,
            PLAYER_SEED,
            openReplay.encounter_session_id,
            openReplay.checkpoint_digest,
            1,
            openReplay.asset_id,
            "alice",
            "bob",
            openReplay.item_type,
            openReplay.quantity,
            openReplay.source_event,
            openReplay.output_index,
            1,
          ),
        ) as {
          ok: true;
          bundle_hex: string;
          bundle_bytes: number;
          checkpoint_digest: string;
          game_manifest_digest: string;
        };
        const advanced = await timedFetch(
          endpoint(`/v1/open/${unit}/market-listing`),
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${ADMIN_TOKEN}`,
              "content-type": "application/json",
            },
            body: JSON.stringify({
              asset_id: openReplay.asset_id,
              seller_id: "bob",
              inventory_bundle_hex: inventory.bundle_hex,
              inventory_checkpoint_digest: inventory.checkpoint_digest,
              inventory_game_manifest_digest: inventory.game_manifest_digest,
            }),
          },
        );
        if (!advanced.response.ok) {
          throw new Error(
            `inventory head advance: ${advanced.response.status} ` +
              `${await advanced.response.text()}`,
          );
        }
        inventoryHeadAdvance = {
          elapsed_ms: round(advanced.elapsed),
          bundle_bytes: inventory.bundle_bytes,
        };
        const latencies: number[] = [];
        for (let index = 0; index < MARKET_LISTING_READS; index++) {
          const listing = await timedFetch(
            endpoint(`/v1/open/${unit}/market-listing`),
            {
              method: "POST",
              headers: {
                authorization: `Bearer ${ADMIN_TOKEN}`,
                "content-type": "application/json",
              },
              body: JSON.stringify({
                asset_id: openReplay.asset_id,
                seller_id: "bob",
              }),
            },
          );
          if (!listing.response.ok) {
            throw new Error(
              `market listing: ${listing.response.status} ${await listing.response.text()}`,
            );
          }
          const listingBody = await listing.response.json() as {
            allowed?: boolean;
          };
          if (!listingBody.allowed) {
            throw new Error("market listing was not allowed");
          }
          latencies.push(listing.elapsed);
        }
        marketplaceListing = summarizeLatency(latencies);
      }
      return {
        result: {
          reason,
          idempotency_key: enqueueBody.idempotency_key,
          enqueue_ms: round(enqueue.elapsed),
          delivered_ms: round(performance.now() - deliveryStarted),
          audit_decision: auditDecision,
          bundle_bytes: replayArtifact?.bundle_bytes ?? 0,
          polls,
          ...(marketplaceListing
            ? { marketplace_listing: marketplaceListing }
            : {}),
          ...(inventoryHeadAdvance
            ? { inventory_head_advance: inventoryHeadAdvance }
            : {}),
        },
        stats,
      };
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`replay delivery ${mode}: timed out after 10000ms`);
}

async function runMode(mode: AuditMode): Promise<Record<string, unknown>> {
  const unit = `bench-${mode}-${Date.now()}-${crypto.randomUUID().slice(0, 8)}`;
  const sessionId = `cf:${mode}:${unit}`;
  const fixtures = makeChain(sessionId, `observer-${mode}`, HEADS);
  const configureMs = await configureUnit(
    mode,
    unit,
    sessionId,
    fixtures[0],
  );

  const commits: number[] = [];
  for (const fixture of fixtures) {
    const result = await submitFixture(mode, unit, fixture);
    if (result.response.status !== 202) {
      throw new Error(
        `commit ${mode}/${fixture.epoch}: ${result.response.status} ` +
          `${await result.response.text()}`,
      );
    }
    commits.push(result.elapsed);
  }

  const duplicates: number[] = [];
  for (let index = 0; index < 10; index++) {
    const result = await submitFixture(mode, unit, fixtures.at(-1)!);
    if (result.response.status !== 200) {
      throw new Error(`duplicate ${mode}: ${result.response.status}`);
    }
    duplicates.push(result.elapsed);
  }

  const gap = await timedFetch(
    endpoint(
      `/v1/${mode}/${unit}/gap?after_epoch=0&after_digest=genesis&target_epoch=${HEADS}&max_items=${Math.min(HEADS, 256)}`,
    ),
  );
  if (!gap.response.ok) {
    throw new Error(`gap ${mode}: ${gap.response.status} ${await gap.response.text()}`);
  }
  const gapBody = await gap.response.json() as { envelopes: string[] };

  const contended = makeFixture(
    sessionId,
    `observer-${mode}`,
    HEADS + 1,
    fixtures.at(-1)!.digest,
  );
  const contentionStarted = performance.now();
  const contentionResults = await Promise.all(
    Array.from(
      { length: CONTENDERS },
      () => submitFixture(mode, unit, contended),
    ),
  );
  const contentionWallMs = performance.now() - contentionStarted;
  const statuses = contentionResults.map(({ response }) => response.status);
  const advances = statuses.filter((status) => status === 202).length;
  const deduplicated = statuses.filter((status) => status === 200).length;
  if (advances !== 1 || deduplicated !== CONTENDERS - 1) {
    throw new Error(
      `contention ${mode}: expected 1 advance and ${CONTENDERS - 1} duplicates, ` +
        `received ${JSON.stringify(statuses)}`,
    );
  }

  const replayDelivery = await measureReplayDelivery(mode, unit);
  const parallelShards = await runParallelShards(mode);
  return {
    mode,
    configure_ms: round(configureMs),
    cold_commit_ms: round(commits[0]),
    commit: summarizeLatency(commits),
    warm_commit: summarizeLatency(commits.slice(1)),
    duplicate: summarizeLatency(duplicates),
    gap_ms: round(gap.elapsed),
    gap_items: gapBody.envelopes.length,
    same_shard_contention: {
      requests: CONTENDERS,
      advances,
      duplicates: deduplicated,
      response: summarizeLatency(contentionResults.map(({ elapsed }) => elapsed)),
      wall_ms: round(contentionWallMs),
      throughput_requests_per_second: round(
        CONTENDERS / (contentionWallMs / 1_000),
      ),
    },
    replay_delivery: replayDelivery.result,
    parallel_shards: parallelShards,
    stats: replayDelivery.stats,
  };
}

async function main(): Promise<void> {
  const health = await timedFetch(endpoint("/health"));
  if (!health.response.ok) {
    throw new Error(`health check failed: ${health.response.status}`);
  }
  const started = new Date().toISOString();
  const results = [];
  for (const mode of BENCH_MODES) {
    results.push(await runMode(mode));
  }
  console.log(JSON.stringify({
    base_url: BASE_URL,
    location_hint: LOCATION_HINT ?? null,
    started,
    statistics: {
      percentile_method: "nearest_rank",
    },
    health_ms: round(health.elapsed),
    heads: HEADS,
    contenders: CONTENDERS,
    parallel_shards: PARALLEL_SHARDS,
    heads_per_shard: HEADS_PER_SHARD,
    results,
  }, null, 2));
}

await main();
