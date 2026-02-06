import { CrdtServer, loadWasm, type EventRun } from "./wasm";

export interface Env {
  CRDT_DOC: DurableObjectNamespace;
}

// --- Worker entrypoint: routes requests to Durable Object ---

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/")) {
      return jsonError("not found", 404);
    }

    // Single DO instance for the entire doc
    const id = env.CRDT_DOC.idFromName("main");
    const stub = env.CRDT_DOC.get(id);
    return stub.fetch(request);
  },
};

// --- Durable Object: stateful CRDT doc ---

export class CrdtDoc implements DurableObject {
  private crdt: CrdtServer | null = null;
  private state: DurableObjectState;

  constructor(state: DurableObjectState, _env: Env) {
    this.state = state;
    // blockConcurrencyWhile ensures init completes before any fetch
    state.blockConcurrencyWhile(async () => {
      const w = await loadWasm();
      this.crdt = new CrdtServer(w);

      // Replay persisted events
      const t0 = Date.now();
      const stored = await this.state.storage.list<EventRun>({ prefix: "event:" });
      let count = 0;
      for (const [, run] of stored) {
        this.crdt.mergeRemote([run]);
        count++;
      }
      console.log(`Replayed ${count} events in ${Date.now() - t0}ms`);
    });
  }

  async fetch(request: Request): Promise<Response> {
    const crdt = this.crdt!;
    const url = new URL(request.url);
    const t = Date.now();

    // GET /api/state
    if (request.method === "GET" && url.pathname === "/api/state") {
      const state = crdt.syncState();
      console.log(`GET /api/state ${Date.now() - t}ms`);
      return jsonOk(state);
    }

    // POST /api/push
    if (request.method === "POST" && url.pathname === "/api/push") {
      try {
        const body = await request.json() as { events: EventRun[] };
        const events = body.events;
        if (!Array.isArray(events)) {
          return jsonError("events must be an array");
        }

        const ops = crdt.mergeRemote(events);

        // Persist to DO storage (single batch put)
        const countVal = (await this.state.storage.get<number>("meta:count")) ?? 0;
        const puts: Record<string, EventRun | number> = {};
        let idx = countVal;
        for (const event of events) {
          puts[`event:${String(idx).padStart(10, "0")}`] = event;
          idx++;
        }
        puts["meta:count"] = idx;
        await this.state.storage.put(puts);

        const ms = Date.now() - t;
        const totalOps = events.reduce((s, e) => s + e.ops.length, 0);
        console.log(`POST /api/push events=${events.length} ops=${totalOps} merge_ops=${ops.length} ${ms}ms`);
        return jsonOk({ ok: true, merge_ops: ops.length });
      } catch (e) {
        return jsonError(`push failed: ${e}`);
      }
    }

    // POST /api/pull
    if (request.method === "POST" && url.pathname === "/api/pull") {
      try {
        const body = await request.json() as { known_peers?: Record<string, number> };
        const knownPeers = body.known_peers ?? {};
        const events = crdt.getPending(knownPeers);
        const state = crdt.syncState();
        const ms = Date.now() - t;
        const totalOps = events.reduce((s, e) => s + e.ops.length, 0);
        console.log(`POST /api/pull events=${events.length} ops=${totalOps} ${ms}ms`);
        return jsonOk({ events, server_frontier: state.frontier });
      } catch (e) {
        return jsonError(`pull failed: ${e}`);
      }
    }

    return jsonError("not found", 404);
  }
}

// --- Helpers ---

function corsHeaders(): HeadersInit {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type",
  };
}

function jsonOk(data: unknown): Response {
  return new Response(JSON.stringify(data), {
    headers: { "content-type": "application/json", ...corsHeaders() },
  });
}

function jsonError(message: string, status = 400): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders() },
  });
}
