import { EphemeralRelay, loadWasm, type NsEntries } from "./wasm";

export interface Env {
  GAME_RELAY: DurableObjectNamespace;
}

const GAME_NS = ["pos", "hp", "gold", "alive", "monster_pos", "monster_hp", "monster_alive"];

// --- Worker entrypoint ---

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }
    const url = new URL(request.url);
    if (url.pathname === "/ws") {
      const id = env.GAME_RELAY.idFromName("main");
      const stub = env.GAME_RELAY.get(id);
      return stub.fetch(request);
    }
    return new Response("Not Found", { status: 404 });
  },
};

// --- Durable Object: P2P game relay ---

interface Session {
  peerId: string;
  team: number;
}

export class GameRelay implements DurableObject {
  private relay: EphemeralRelay | null = null;
  private state: DurableObjectState;
  private sessions: Map<WebSocket, Session> = new Map();

  constructor(state: DurableObjectState, _env: Env) {
    this.state = state;
    state.blockConcurrencyWhile(async () => {
      const w = await loadWasm();
      this.relay = new EphemeralRelay(w);
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname !== "/ws") {
      return new Response("Not Found", { status: 404 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    const peerId = url.searchParams.get("peer_id") ?? `anon-${Date.now()}`;
    const team = parseInt(url.searchParams.get("team") ?? "0", 10);

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();

    this.sessions.set(server, { peerId, team });
    console.log(`[join] peer=${peerId} team=${team} sessions=${this.sessions.size}`);

    // Send current snapshot
    const snapshot = this.relay!.snapshot(GAME_NS);
    server.send(JSON.stringify({ type: "snapshot", entries: snapshot }));

    // Notify others
    this.broadcast(server, JSON.stringify({
      type: "peer_joined",
      peer_id: peerId,
      team,
    }));

    server.addEventListener("message", (event) => {
      try {
        const msg = JSON.parse(event.data as string);
        if (msg.type === "state") {
          const entries: NsEntries = msg.entries;
          const changed = this.relay!.merge(entries);
          // Broadcast diff to all OTHER clients
          if (Object.keys(changed).length > 0) {
            this.broadcast(server, JSON.stringify({ type: "diff", entries: changed }));
          }
        }
      } catch (e) {
        console.error(`[ws error] ${e}`);
      }
    });

    server.addEventListener("close", () => {
      const session = this.sessions.get(server);
      this.sessions.delete(server);
      if (session) {
        this.broadcast(server, JSON.stringify({
          type: "peer_left",
          peer_id: session.peerId,
        }));
        console.log(`[leave] peer=${session.peerId} sessions=${this.sessions.size}`);
      }
    });

    server.addEventListener("error", () => {
      this.sessions.delete(server);
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  private broadcast(sender: WebSocket, data: string) {
    for (const [ws] of this.sessions) {
      if (ws !== sender && ws.readyState === 1) {
        try { ws.send(data); } catch { /* skip */ }
      }
    }
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
