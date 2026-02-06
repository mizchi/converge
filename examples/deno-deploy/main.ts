// crdt_db sync server

import { CrdtServer, loadWasm } from "./wasm.ts";
import { EventStore } from "./store.ts";

const PORT = parseInt(Deno.env.get("PORT") ?? "8080");

// Initialize
const kv = await Deno.openKv();
const wasm = await loadWasm();
const crdt = new CrdtServer(wasm);
const store = new EventStore(kv);

// Replay persisted events
const t0 = performance.now();
const replayed = await store.replayAll(crdt);
console.log(`Replayed ${replayed} events from KV in ${(performance.now() - t0).toFixed(1)}ms`);

const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "content-type",
};

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", ...CORS_HEADERS },
  });
}

function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ error: message }, status);
}

Deno.serve({ port: PORT }, async (req: Request) => {
  const url = new URL(req.url);
  const t = performance.now();

  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  // Catch up with events written by other isolates (1 KV read)
  const [caught, kvVersion] = await store.catchUp(crdt);
  if (caught > 0) {
    console.log(`Caught up ${caught} events from other isolates`);
  }

  // GET /api/state
  if (req.method === "GET" && url.pathname === "/api/state") {
    const state = crdt.syncState();
    console.log(`GET /api/state ${(performance.now() - t).toFixed(2)}ms`);
    return jsonResponse(state);
  }

  // POST /api/push
  if (req.method === "POST" && url.pathname === "/api/push") {
    try {
      const body = await req.json();
      const events = body.events;
      if (!Array.isArray(events)) {
        return errorResponse("events must be an array");
      }
      const ops = crdt.mergeRemote(events);
      await store.appendEvents(events, kvVersion);
      const ms = (performance.now() - t).toFixed(2);
      const totalOps = events.reduce((s: number, e: { ops: unknown[] }) => s + e.ops.length, 0);
      console.log(`POST /api/push events=${events.length} ops=${totalOps} merge_ops=${ops.length} ${ms}ms`);
      return jsonResponse({ ok: true, merge_ops: ops.length });
    } catch (e) {
      return errorResponse(`push failed: ${e}`);
    }
  }

  // POST /api/pull
  if (req.method === "POST" && url.pathname === "/api/pull") {
    try {
      const body = await req.json();
      const knownPeers = body.known_peers ?? {};
      const events = crdt.getPending(knownPeers);
      const state = crdt.syncState();
      const ms = (performance.now() - t).toFixed(2);
      const totalOps = events.reduce((s: number, e: { ops: unknown[] }) => s + e.ops.length, 0);
      console.log(`POST /api/pull events=${events.length} ops=${totalOps} ${ms}ms`);
      return jsonResponse({
        events,
        server_frontier: state.frontier,
      });
    } catch (e) {
      return errorResponse(`pull failed: ${e}`);
    }
  }

  return errorResponse("not found", 404);
});
