import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import {
  HttpPeerCheckpointSender,
  PeerCheckpointDispatcher,
  type PeerCheckpointDelivery,
  type PeerCheckpointSender,
  type PeerRouteEndpoint,
  type RawPeerCheckpointResponse,
} from "../src/peer-checkpoint-transport.ts";
import { MoonBitPeerDeliveryPolicy } from "../src/moonbit-peer-policy.ts";
import {
  PeerRouteSqliteStore,
  PeerRouteStoreCorruptError,
} from "../src/peer-route-sqlite.ts";
import {
  type PlayerLocalStoreConfiguration,
  PlayerLocalSqliteStore,
} from "../src/player-local-sqlite.ts";

const configuration: PlayerLocalStoreConfiguration = {
  boundary: {
    protocol_version: 1,
    purpose: "checkpoint-v1",
    manifest_digest: "manifest-local",
    scope_id: "player-alice",
    unit_id: "match-1",
  },
  genesis_digest: "genesis",
  outbox_capacity: 8,
};

const delivery: PeerCheckpointDelivery = {
  boundary: configuration.boundary,
  epoch: 0,
  checkpoint_digest: "checkpoint-0",
  canonical_envelope: "checkpoint-envelope-0",
};

const transportConfiguration = {
  max_in_flight: 2,
  max_parallel: 2,
  lease_duration_ms: 50,
  base_backoff_ms: 10,
  max_backoff_ms: 100,
};

function endpoint(peer_id: string, port = 1): PeerRouteEndpoint {
  return {
    peer_id,
    endpoint_url: `http://127.0.0.1:${port}/checkpoint`,
  };
}

async function withRouteStore(t: test.TestContext): Promise<{
  path: string;
  store: PeerRouteSqliteStore;
}> {
  const directory = await mkdtemp(join(tmpdir(), "converge-peer-route-"));
  t.after(async () => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "audit.sqlite");
  const local = PlayerLocalSqliteStore.open(path, configuration);
  local.close();
  return {
    path,
    store: PeerRouteSqliteStore.open(path, configuration.boundary),
  };
}

function response(
  peer_id: string,
  checkpoint_digest = delivery.checkpoint_digest,
  authentication = "valid",
): RawPeerCheckpointResponse {
  return {
    kind: "converge-peer-checkpoint-ack-v1",
    peer_id,
    checkpoint_digest,
    canonical_response: `ack:${peer_id}:${checkpoint_digest}`,
    authentication,
  };
}

class ScriptedSender implements PeerCheckpointSender {
  readonly attempted: string[] = [];
  readonly maximum_attempt_duration_ms = 40;
  active = 0;
  maxActive = 0;
  private readonly scripts: ReadonlyMap<
    string,
    () => Promise<RawPeerCheckpointResponse>
  >;

  constructor(
    scripts: ReadonlyMap<
      string,
      () => Promise<RawPeerCheckpointResponse>
    >,
  ) {
    this.scripts = scripts;
  }

  async send(
    route: PeerRouteEndpoint,
    _delivery: PeerCheckpointDelivery,
    _signal: AbortSignal,
  ): Promise<RawPeerCheckpointResponse> {
    this.attempted.push(route.peer_id);
    this.active += 1;
    this.maxActive = Math.max(this.maxActive, this.active);
    try {
      const script = this.scripts.get(route.peer_id);
      if (!script) throw new Error("missing scripted peer");
      return await script();
    } finally {
      this.active -= 1;
    }
  }
}

async function validResponse(
  value: RawPeerCheckpointResponse,
): Promise<boolean> {
  return value.authentication === "valid";
}

test("uses MoonBit fair selection and persists success/failure across restart", async (t) => {
  const { path, store } = await withRouteStore(t);
  assert.deepEqual(
    store.configureRoutes([endpoint("peer-a"), endpoint("peer-b"), endpoint("peer-c")]),
    { decision: "configured", inserted: 3 },
  );
  const policy = await MoonBitPeerDeliveryPolicy.load();
  const sender = new ScriptedSender(
    new Map([
      [
        "peer-a",
        async () => {
          await new Promise((resolve) => setTimeout(resolve, 5));
          return response("peer-a");
        },
      ],
      [
        "peer-b",
        async () => {
          await new Promise((resolve) => setTimeout(resolve, 5));
          throw new Error("peer unavailable");
        },
      ],
      ["peer-c", async () => response("peer-c")],
    ]),
  );
  const dispatcher = new PeerCheckpointDispatcher(
    store,
    policy,
    sender,
    validResponse,
    transportConfiguration,
  );
  assert.deepEqual(await dispatcher.dispatch(delivery, 100), {
    decision: "accepted",
    peer_id: "peer-a",
    attempted: 2,
    authenticated: 1,
    failed: 1,
  });
  assert.deepEqual(sender.attempted, ["peer-a", "peer-b"]);
  assert.equal(sender.maxActive, 2);
  const beforeRestart = store.routes(100);
  assert.equal(beforeRestart.find((route) => route.peer_id === "peer-a")?.last_attempt_order, 1);
  assert.deepEqual(
    beforeRestart.find((route) => route.peer_id === "peer-b"),
    {
      peer_id: "peer-b",
      endpoint_url: endpoint("peer-b").endpoint_url,
      available: true,
      quarantined: false,
      failures: 1,
      next_retry_at_ms: 110,
      last_attempt_order: 2,
      lease_expires_at_ms: null,
    },
  );
  store.close();

  const restarted = PeerRouteSqliteStore.open(path, configuration.boundary);
  const fairSender = new ScriptedSender(
    new Map([
      ["peer-a", async () => response("peer-a")],
      ["peer-b", async () => response("peer-b")],
      ["peer-c", async () => response("peer-c")],
    ]),
  );
  const fairDispatcher = new PeerCheckpointDispatcher(
    restarted,
    policy,
    fairSender,
    validResponse,
    { ...transportConfiguration, max_parallel: 1 },
  );
  assert.equal((await fairDispatcher.dispatch(delivery, 100)).decision, "accepted");
  assert.deepEqual(fairSender.attempted, ["peer-c"]);
  restarted.close();
});

test("durable route lease applies backpressure and becomes retryable after restart", async (t) => {
  const { path, store } = await withRouteStore(t);
  store.configureRoutes([endpoint("peer-a")]);
  const claims = store.claimRoutes(["peer-a"], 100, 50);
  assert.equal(claims.length, 1);
  store.close();

  const policy = await MoonBitPeerDeliveryPolicy.load();
  const restarted = PeerRouteSqliteStore.open(path, configuration.boundary);
  const sender = new ScriptedSender(
    new Map([["peer-a", async () => response("peer-a")]]),
  );
  const dispatcher = new PeerCheckpointDispatcher(
    restarted,
    policy,
    sender,
    validResponse,
    { ...transportConfiguration, max_in_flight: 1, max_parallel: 1 },
  );
  assert.deepEqual(await dispatcher.dispatch(delivery, 120), {
    decision: "backpressured",
  });
  assert.deepEqual(sender.attempted, []);
  assert.equal((await dispatcher.dispatch(delivery, 151)).decision, "accepted");
  assert.deepEqual(sender.attempted, ["peer-a"]);
  restarted.close();
});

test("refuses a sender deadline longer than its durable route lease", async (t) => {
  const { store } = await withRouteStore(t);
  const policy = await MoonBitPeerDeliveryPolicy.load();
  const sender = new ScriptedSender(new Map());
  Object.defineProperty(sender, "maximum_attempt_duration_ms", { value: 51 });
  assert.throws(
    () =>
      new PeerCheckpointDispatcher(
        store,
        policy,
        sender,
        validResponse,
        transportConfiguration,
      ),
    /sender deadline must not exceed durable lease/,
  );
  store.close();
});

test("persists authenticated fork evidence and quarantines only the forking route", async (t) => {
  const { path, store } = await withRouteStore(t);
  store.configureRoutes([endpoint("peer-a"), endpoint("peer-b")]);
  const policy = await MoonBitPeerDeliveryPolicy.load();
  const sender = new ScriptedSender(
    new Map([
      ["peer-a", async () => response("peer-a")],
      ["peer-b", async () => response("peer-b", "checkpoint-fork")],
    ]),
  );
  const dispatcher = new PeerCheckpointDispatcher(
    store,
    policy,
    sender,
    validResponse,
    transportConfiguration,
  );
  assert.deepEqual(await dispatcher.dispatch(delivery, 100), {
    decision: "fork_detected",
    fork_peers: ["peer-b"],
    attempted: 2,
    authenticated: 2,
    failed: 0,
  });
  assert.equal(store.routes(100).find((route) => route.peer_id === "peer-b")?.quarantined, true);
  assert.deepEqual(store.forkEvidence(), [
    {
      peer_id: "peer-b",
      expected_digest: "checkpoint-0",
      conflicting_digest: "checkpoint-fork",
      received_at_ms: 101,
      canonical_response: "ack:peer-b:checkpoint-fork",
    },
  ]);
  store.close();

  const corrupt = new DatabaseSync(path);
  corrupt.exec(
    "UPDATE player_local_peer_routes SET quarantined = 0 WHERE peer_id = 'peer-b'",
  );
  corrupt.close();
  assert.throws(
    () => PeerRouteSqliteStore.open(path, configuration.boundary),
    PeerRouteStoreCorruptError,
  );
});

test("ignores unauthenticated fork bytes and backs off that route", async (t) => {
  const { store } = await withRouteStore(t);
  store.configureRoutes([endpoint("peer-a"), endpoint("peer-b")]);
  const policy = await MoonBitPeerDeliveryPolicy.load();
  const sender = new ScriptedSender(
    new Map([
      ["peer-a", async () => response("peer-a")],
      [
        "peer-b",
        async () => response("peer-b", "forged-checkpoint", "invalid"),
      ],
    ]),
  );
  const dispatcher = new PeerCheckpointDispatcher(
    store,
    policy,
    sender,
    validResponse,
    transportConfiguration,
  );
  assert.equal((await dispatcher.dispatch(delivery, 100)).decision, "accepted");
  assert.deepEqual(store.forkEvidence(), []);
  assert.equal(store.routes(100).find((route) => route.peer_id === "peer-b")?.failures, 1);
  store.close();
});

test("sends the bounded peer wire request over a real HTTP connection", async (t) => {
  const received: unknown[] = [];
  const server = createServer((request, responseStream) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
        peer_id: string;
      };
      received.push(body);
      responseStream.writeHead(200, { "content-type": "application/json" });
      responseStream.end(JSON.stringify(response(body.peer_id)));
    });
  });
  t.after(async () => closeServer(server));
  const port = await listen(server);
  const { store } = await withRouteStore(t);
  store.configureRoutes([endpoint("peer-http", port)]);
  const policy = await MoonBitPeerDeliveryPolicy.load();
  const dispatcher = new PeerCheckpointDispatcher(
    store,
    policy,
    new HttpPeerCheckpointSender({
      timeout_ms: 250,
      max_response_bytes: 4_096,
    }),
    validResponse,
    {
      ...transportConfiguration,
      max_in_flight: 1,
      max_parallel: 1,
      lease_duration_ms: 500,
    },
  );
  assert.equal((await dispatcher.dispatch(delivery, 100)).decision, "accepted");
  assert.deepEqual(received, [
    {
      kind: "converge-peer-checkpoint-v1",
      peer_id: "peer-http",
      boundary: configuration.boundary,
      epoch: 0,
      checkpoint_digest: "checkpoint-0",
      canonical_envelope: "checkpoint-envelope-0",
    },
  ]);
  store.close();
});

test("rejects an oversized peer response before authentication", async (t) => {
  const server = createServer((_request, responseStream) => {
    responseStream.writeHead(200, { "content-type": "application/json" });
    responseStream.end(
      JSON.stringify({ ...response("peer-large"), padding: "x".repeat(512) }),
    );
  });
  t.after(async () => closeServer(server));
  const port = await listen(server);
  const { store } = await withRouteStore(t);
  store.configureRoutes([endpoint("peer-large", port)]);
  const policy = await MoonBitPeerDeliveryPolicy.load();
  const dispatcher = new PeerCheckpointDispatcher(
    store,
    policy,
    new HttpPeerCheckpointSender({
      timeout_ms: 250,
      max_response_bytes: 128,
    }),
    validResponse,
    {
      ...transportConfiguration,
      max_in_flight: 1,
      max_parallel: 1,
      lease_duration_ms: 500,
    },
  );
  assert.deepEqual(await dispatcher.dispatch(delivery, 100), {
    decision: "no_authenticated_response",
    attempted: 1,
    authenticated: 0,
    failed: 1,
  });
  assert.equal(store.routes(100)[0]?.failures, 1);
  store.close();
});

async function listen(server: Server): Promise<number> {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("missing port");
  return address.port;
}

async function closeServer(server: Server): Promise<void> {
  if (!server.listening) return;
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}
