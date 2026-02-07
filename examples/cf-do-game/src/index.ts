import {
  TICK_MS,
  WORLD_HEIGHT,
  WORLD_WIDTH,
  createInitialWorld,
  stepWorldWithDebug,
  toPublicWorldState,
  type PlayerInput,
  type TickDebugInfo,
  type WorldState,
} from "./game";
import { renderGameHtml } from "./ui";
import { EphemeralRelay, loadWasm, type NsEntries } from "./wasm";

export interface Env {
  GAME_RELAY: DurableObjectNamespace;
}

const SNAPSHOT_NAMESPACES = [
  "input",
  "input_x",
  "input_y",
  "input_name",
  "input_color",
  "pos",
  "hp",
  "gold",
  "alive",
  "monster_pos",
  "monster_hp",
  "monster_alive",
];

interface Session {
  peerId: string;
  debug: boolean;
}

// --- Worker entrypoint ---

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    const url = new URL(request.url);

    if (url.pathname === "/") {
      return new Response(renderGameHtml(), {
        headers: {
          "content-type": "text/html; charset=utf-8",
          ...corsHeaders(),
        },
      });
    }

    if (url.pathname === "/health") {
      return jsonOk({ ok: true, service: "cf-do-game" });
    }

    if (url.pathname === "/ws") {
      const room = url.searchParams.get("room") ?? "main";
      const id = env.GAME_RELAY.idFromName(room);
      const stub = env.GAME_RELAY.get(id);
      return stub.fetch(request);
    }

    if (url.pathname === "/debug") {
      const room = url.searchParams.get("room") ?? "main";
      const id = env.GAME_RELAY.idFromName(room);
      const stub = env.GAME_RELAY.get(id);
      return stub.fetch(request);
    }

    return new Response("Not Found", { status: 404 });
  },
};

// --- Durable Object ---

export class GameRelay implements DurableObject {
  private relay: EphemeralRelay | null = null;
  private state: DurableObjectState;
  private sessions: Map<WebSocket, Session> = new Map();
  private world: WorldState = createInitialWorld(1);
  private loop: ReturnType<typeof setInterval> | null = null;
  private lastDebug: TickDebugInfo = emptyDebugInfo();
  private debugHistory: TickDebugInfo[] = [];

  constructor(state: DurableObjectState, _env: Env) {
    this.state = state;
    state.blockConcurrencyWhile(async () => {
      const w = await loadWasm();
      this.relay = new EphemeralRelay(w);

      const persistedSeed = await this.state.storage.get<number>("world:seed");
      const seed = persistedSeed ?? (Date.now() & 0x7fffffff);
      this.world = createInitialWorld(seed);
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/debug") {
      return jsonOk({
        online: this.sessions.size,
        world: toPublicWorldState(this.world, this.sessions.size, this.lastDebug),
        recent_debug: this.debugHistory,
        peers: [...this.sessions.values()].map((session) => session.peerId),
      });
    }

    if (url.pathname !== "/ws") {
      return jsonError("Not Found", 404);
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return jsonError("Expected WebSocket", 426);
    }

    const peerId = sanitizePeerId(url.searchParams.get("peer_id")) ?? crypto.randomUUID().slice(0, 8);
    const debug = isTruthy(url.searchParams.get("debug"));

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();

    this.sessions.set(server, { peerId, debug });
    this.ensureLoop();

    server.send(JSON.stringify({
      type: "welcome",
      peer_id: peerId,
      world: { width: WORLD_WIDTH, height: WORLD_HEIGHT, tick_ms: TICK_MS },
    }));

    const snapshot = this.relay!.snapshot(SNAPSHOT_NAMESPACES);
    server.send(JSON.stringify({ type: "snapshot", entries: snapshot }));
    server.send(JSON.stringify({
      type: "game_state",
      state: toPublicWorldState(this.world, this.sessions.size, this.lastDebug),
    }));

    this.broadcast(server, JSON.stringify({
      type: "peer_joined",
      peer_id: peerId,
    }));

    server.addEventListener("message", (event) => {
      try {
        const msg = JSON.parse(String(event.data)) as { type?: string; entries?: NsEntries; t?: number };

        if (msg.type === "state" && msg.entries) {
          const changed = this.relay!.merge(msg.entries);
          if (Object.keys(changed).length > 0) {
            this.broadcast(server, JSON.stringify({ type: "diff", entries: changed }));
          }
          return;
        }

        if (msg.type === "ping") {
          server.send(JSON.stringify({ type: "pong", t: msg.t ?? Date.now() }));
        }
      } catch (error) {
        console.error(`[ws message error] ${error}`);
      }
    });

    server.addEventListener("close", () => {
      const session = this.sessions.get(server);
      this.sessions.delete(server);
      if (session) {
        this.broadcast(server, JSON.stringify({ type: "peer_left", peer_id: session.peerId }));
      }
      if (this.sessions.size === 0) {
        this.stopLoop();
      }
    });

    server.addEventListener("error", () => {
      this.sessions.delete(server);
      if (this.sessions.size === 0) {
        this.stopLoop();
      }
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  private ensureLoop() {
    if (this.loop !== null) return;
    this.loop = setInterval(() => {
      try {
        this.tick();
      } catch (error) {
        console.error(`[game tick error] ${error}`);
      }
    }, TICK_MS);
  }

  private stopLoop() {
    if (this.loop === null) return;
    clearInterval(this.loop);
    this.loop = null;
  }

  private tick() {
    if (!this.relay) return;
    const started = Date.now();

    const activePeerIds = new Set<string>();
    for (const session of this.sessions.values()) {
      activePeerIds.add(session.peerId);
    }

    const inputEntries = this.relay.getAll("input");
    const inputXEntries = this.relay.getAll("input_x");
    const inputYEntries = this.relay.getAll("input_y");
    const inputNameEntries = this.relay.getAll("input_name");
    const inputColorEntries = this.relay.getAll("input_color");
    const inputs: Record<string, PlayerInput> = {};

    for (const peerId of activePeerIds) {
      const legacy = parseInputValue(peerId, inputEntries[peerId]?.value);
      const prev = this.world.players[peerId];
      const x = parseEntryNumber(inputXEntries[peerId]?.value) ?? legacy?.x ?? prev?.x ?? WORLD_WIDTH / 2;
      const y = parseEntryNumber(inputYEntries[peerId]?.value) ?? legacy?.y ?? prev?.y ?? WORLD_HEIGHT / 2;
      const name = parseEntryName(inputNameEntries[peerId]?.value) ?? legacy?.name ?? prev?.name ??
        `Player-${peerId.slice(0, 4)}`;
      const color = parseEntryColor(inputColorEntries[peerId]?.value) ?? legacy?.color ?? prev?.color ?? colorFromPeer(peerId);
      inputs[peerId] = {
        peerId,
        name,
        color,
        x,
        y,
      };
    }

    const stepped = stepWorldWithDebug(this.world, inputs, activePeerIds);
    this.world = stepped.world;
    stepped.debug.tickComputeMs = Date.now() - started;
    this.lastDebug = stepped.debug;
    this.debugHistory.push(stepped.debug);
    if (this.debugHistory.length > 120) {
      this.debugHistory.shift();
    }

    const payload = JSON.stringify({
      type: "game_state",
      state: toPublicWorldState(this.world, this.sessions.size, stepped.debug),
    });
    this.broadcastAll(payload);

    if (this.world.tick % 200 === 0) {
      void this.state.storage.put("world:seed", this.world.seed);
    }
  }

  private broadcast(sender: WebSocket, data: string) {
    for (const [ws] of this.sessions) {
      if (ws !== sender && ws.readyState === 1) {
        try {
          ws.send(data);
        } catch {
          // Ignore send failures.
        }
      }
    }
  }

  private broadcastAll(data: string) {
    for (const [ws] of this.sessions) {
      if (ws.readyState !== 1) continue;
      try {
        ws.send(data);
      } catch {
        // Ignore send failures.
      }
    }
  }
}

function parseInputValue(peerId: string, value: unknown): PlayerInput | null {
  if (!value) {
    return null;
  }

  let rec: Record<string, unknown> | null = null;
  if (typeof value === "object") {
    rec = value as Record<string, unknown>;
  } else if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value) as unknown;
      if (parsed && typeof parsed === "object") {
        rec = parsed as Record<string, unknown>;
      }
    } catch {
      return null;
    }
  }
  if (!rec) return null;

  const x = asFiniteNumber(rec.x);
  const y = asFiniteNumber(rec.y);
  if (x === null || y === null) {
    return null;
  }

  const name = typeof rec.name === "string" && rec.name.trim().length > 0
    ? rec.name.trim().slice(0, 24)
    : `Player-${peerId.slice(0, 4)}`;
  const color = typeof rec.color === "string" && /^#[0-9a-fA-F]{6}$/.test(rec.color)
    ? rec.color
    : colorFromPeer(peerId);

  return {
    peerId,
    name,
    color,
    x,
    y,
  };
}

function asFiniteNumber(value: unknown): number | null {
  if (typeof value !== "number") return null;
  if (!Number.isFinite(value)) return null;
  return value;
}

function parseEntryNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function parseEntryName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const name = value.trim().slice(0, 24);
  return name.length > 0 ? name : null;
}

function parseEntryColor(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return /^#[0-9a-fA-F]{6}$/.test(value) ? value : null;
}

function sanitizePeerId(raw: string | null): string | null {
  if (!raw) return null;
  const cleaned = raw.replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 32);
  return cleaned.length > 0 ? cleaned : null;
}

function colorFromPeer(peerId: string): string {
  let hash = 0;
  for (let i = 0; i < peerId.length; i++) {
    hash = (hash * 31 + peerId.charCodeAt(i)) | 0;
  }
  const hue = Math.abs(hash) % 360;
  const [r, g, b] = hslToRgb(hue / 360, 0.72, 0.56);
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  if (s === 0) {
    const v = Math.round(l * 255);
    return [v, v, v];
  }

  const hue2rgb = (p: number, q: number, t: number): number => {
    let tt = t;
    if (tt < 0) tt += 1;
    if (tt > 1) tt -= 1;
    if (tt < 1 / 6) return p + (q - p) * 6 * tt;
    if (tt < 1 / 2) return q;
    if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
    return p;
  };

  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const r = Math.round(hue2rgb(p, q, h + 1 / 3) * 255);
  const g = Math.round(hue2rgb(p, q, h) * 255);
  const b = Math.round(hue2rgb(p, q, h - 1 / 3) * 255);
  return [r, g, b];
}

function toHex(v: number): string {
  return Math.max(0, Math.min(255, v)).toString(16).padStart(2, "0");
}

function isTruthy(value: string | null): boolean {
  if (!value) return false;
  const normalized = value.toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes" || normalized === "on";
}

function emptyDebugInfo(): TickDebugInfo {
  return {
    activePeers: 0,
    livingPlayers: 0,
    averageLevel: 1,
    enemiesBefore: 0,
    enemiesAfter: 0,
    spawnedEnemies: 0,
    spawnBudgetStart: 0,
    spawnBudgetLeft: 0,
    auraCandidates: 0,
    auraHits: 0,
    touchHits: 0,
    spatialCells: 0,
    tickComputeMs: 0,
  };
}

function corsHeaders(): HeadersInit {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type",
  };
}

function jsonOk(data: unknown): Response {
  return new Response(JSON.stringify(data), {
    headers: {
      "content-type": "application/json",
      ...corsHeaders(),
    },
  });
}

function jsonError(message: string, status = 400): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: {
      "content-type": "application/json",
      ...corsHeaders(),
    },
  });
}
