import { EphemeralRelay, loadWasm, type NsEntries } from "./wasm";

export interface Env {
  SIGNALING_RELAY: DurableObjectNamespace;
}

const DEFAULT_NS = ["state"];
const GOSSIP_FANOUT = 3;
const SEEN_TTL_MS = 30_000; // TTL for seen message deduplication

// --- Worker entrypoint ---

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }
    const url = new URL(request.url);
    if (url.pathname === "/ws") {
      const room = url.searchParams.get("room") ?? "main";
      const id = env.SIGNALING_RELAY.idFromName(room);
      const stub = env.SIGNALING_RELAY.get(id);
      return stub.fetch(request);
    }
    return new Response("Not Found", { status: 404 });
  },
};

// --- Durable Object: Signaling Relay ---

type Mode = "star" | "gossip";

interface Session {
  peerId: string;
  team: number;
}

export class SignalingRelay implements DurableObject {
  private relay: EphemeralRelay | null = null;
  private state: DurableObjectState;
  private sessions: Map<WebSocket, Session> = new Map();
  private mode: Mode | null = null; // set by first connection
  private namespaces: string[] = DEFAULT_NS;

  // Gossip deduplication
  private seenMessages: Map<string, number> = new Map(); // msgId -> expiry timestamp

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
    const requestedMode = (url.searchParams.get("mode") ?? "star") as Mode;

    // First connection sets the mode
    if (this.mode === null) {
      this.mode = requestedMode;
      console.log(`[room] mode set to ${this.mode}`);
    }

    // Parse custom namespaces
    const nsParam = url.searchParams.get("ns");
    if (nsParam) {
      this.namespaces = nsParam.split(",");
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();

    this.sessions.set(server, { peerId, team });
    console.log(`[join] peer=${peerId} team=${team} mode=${this.mode} sessions=${this.sessions.size}`);

    // Send current snapshot + mode info
    const snapshot = this.relay!.snapshot(this.namespaces);
    server.send(JSON.stringify({
      type: "snapshot",
      mode: this.mode,
      entries: snapshot,
    }));

    // Notify others
    this.broadcast(server, JSON.stringify({
      type: "peer_joined",
      peer_id: peerId,
      team,
    }));

    server.addEventListener("message", (event) => {
      try {
        const msg = JSON.parse(event.data as string);
        this.handleMessage(server, msg);
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

  private handleMessage(sender: WebSocket, msg: { type: string; entries?: NsEntries; msgId?: string }) {
    if (msg.type === "state") {
      const entries: NsEntries = msg.entries ?? {};
      const changed = this.relay!.merge(entries);

      if (this.mode === "star") {
        // Star mode: broadcast diff to all other clients
        if (Object.keys(changed).length > 0) {
          this.broadcast(sender, JSON.stringify({ type: "diff", entries: changed }));
        }
      } else {
        // Gossip mode: forward to fanout random peers
        const session = this.sessions.get(sender);
        const msgId = msg.msgId ?? `${session?.peerId}:${Date.now()}`;

        if (this.isSeenMessage(msgId)) {
          return; // Deduplicate
        }
        this.markSeen(msgId);

        if (Object.keys(changed).length > 0) {
          this.gossipForward(sender, changed, msgId);
        }
      }
    } else if (msg.type === "gossip_relay") {
      // Client re-gossiping after receiving a gossip_diff
      const msgId = msg.msgId;
      if (!msgId || this.isSeenMessage(msgId)) {
        return; // Already seen
      }
      this.markSeen(msgId);

      const entries: NsEntries = msg.entries ?? {};
      const changed = this.relay!.merge(entries);
      if (Object.keys(changed).length > 0) {
        this.gossipForward(sender, changed, msgId);
      }
    }
  }

  private gossipForward(sender: WebSocket, entries: NsEntries, msgId: string) {
    const targets = this.pickRandomPeers(sender, GOSSIP_FANOUT);
    const data = JSON.stringify({ type: "gossip_diff", entries, msgId });
    for (const ws of targets) {
      try { ws.send(data); } catch { /* skip */ }
    }
  }

  private pickRandomPeers(exclude: WebSocket, count: number): WebSocket[] {
    const candidates: WebSocket[] = [];
    for (const [ws] of this.sessions) {
      if (ws !== exclude && ws.readyState === 1) {
        candidates.push(ws);
      }
    }
    // Fisher-Yates partial shuffle
    const n = candidates.length;
    const pick = Math.min(count, n);
    for (let i = 0; i < pick; i++) {
      const j = i + Math.floor(Math.random() * (n - i));
      [candidates[i], candidates[j]] = [candidates[j], candidates[i]];
    }
    return candidates.slice(0, pick);
  }

  private isSeenMessage(msgId: string): boolean {
    const expiry = this.seenMessages.get(msgId);
    if (expiry === undefined) return false;
    if (Date.now() > expiry) {
      this.seenMessages.delete(msgId);
      return false;
    }
    return true;
  }

  private markSeen(msgId: string) {
    this.seenMessages.set(msgId, Date.now() + SEEN_TTL_MS);
    // Periodic cleanup
    if (this.seenMessages.size > 1000) {
      const now = Date.now();
      for (const [id, expiry] of this.seenMessages) {
        if (now > expiry) this.seenMessages.delete(id);
      }
    }
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
