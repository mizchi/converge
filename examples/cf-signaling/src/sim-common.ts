/**
 * Common types and utilities for Star/Gossip simulations.
 */

export const SERVER_URL = process.env.SERVER_URL ?? "ws://localhost:8787/ws";
export const TICK_MS = 16;
export const NUM_TICKS = 200;
export const WARMUP_TICKS = 20;
export const NUM_PEERS = 8;

// --- Types ---

export interface EphemeralEntry {
  key: string;
  value: unknown;
  timestamp: number;
  peer: string;
}

export type NsEntries = Record<string, Record<string, EphemeralEntry>>;

interface PendingMessage {
  processAt: number;
  data: NsEntries;
}

// --- PRNG (xorshift32) ---

export class Rng {
  private state: number;
  constructor(seed: number) {
    this.state = seed || 1;
  }
  next(): number {
    let x = this.state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    this.state = x;
    return x < 0 ? -x : x;
  }
  nextBound(bound: number): number {
    return this.next() % bound;
  }
}

// --- Stats ---

export interface ConvergenceStats {
  tick: number;
  inconsistentPairs: number;
  totalEntries: number;
  messagesSent: number;
}

// --- GamePlayer (base for both topologies) ---

export class GamePlayer {
  peerId: string;
  team: number;
  pingMs: number;
  ws: WebSocket | null = null;
  connected = false;

  // Local ephemeral state
  localValue = 0;
  remoteState: NsEntries = {};

  // Network delay buffers
  sendQueue: Array<{ sendAt: number; data: string }> = [];
  private recvQueue: PendingMessage[] = [];
  private oneWayMs: number;

  // Gossip-specific: re-gossip handler
  onGossipDiff: ((entries: NsEntries, msgId: string) => void) | null = null;

  constructor(peerId: string, team: number, pingMs: number) {
    this.peerId = peerId;
    this.team = team;
    this.pingMs = pingMs;
    this.oneWayMs = Math.max(pingMs / 2, pingMs > 0 ? TICK_MS : 0);
  }

  async connect(mode: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const url = `${SERVER_URL}?peer_id=${this.peerId}&team=${this.team}&mode=${mode}&ns=state`;
      this.ws = new WebSocket(url);

      this.ws.addEventListener("open", () => {
        this.connected = true;
        resolve();
      });

      this.ws.addEventListener("message", (event) => {
        try {
          const msg = JSON.parse(String(event.data));
          if (msg.type === "snapshot" || msg.type === "diff") {
            this.recvQueue.push({
              processAt: Date.now() + this.oneWayMs,
              data: msg.entries as NsEntries,
            });
          } else if (msg.type === "gossip_diff") {
            // For gossip: receive diff and schedule re-gossip
            this.recvQueue.push({
              processAt: Date.now() + this.oneWayMs,
              data: msg.entries as NsEntries,
            });
            // Re-gossip back to server
            if (this.onGossipDiff) {
              this.onGossipDiff(msg.entries as NsEntries, msg.msgId as string);
            }
          }
        } catch { /* ignore parse errors */ }
      });

      this.ws.addEventListener("error", (e) => {
        if (!this.connected) reject(e);
      });

      this.ws.addEventListener("close", () => {
        this.connected = false;
      });
    });
  }

  close() {
    this.ws?.close();
  }

  buildState(tick: number): NsEntries {
    const ts = tick;
    const p = this.peerId;
    return {
      state: {
        [p]: { key: p, value: this.localValue, timestamp: ts, peer: p },
      },
    };
  }

  queueSend(tick: number, type = "state", extraFields: Record<string, unknown> = {}) {
    const data = JSON.stringify({
      type,
      entries: this.buildState(tick),
      ...extraFields,
    });
    this.sendQueue.push({ sendAt: Date.now() + this.oneWayMs, data });
  }

  processPending() {
    const now = Date.now();

    // Flush sends
    const ready = this.sendQueue.filter((m) => m.sendAt <= now);
    this.sendQueue = this.sendQueue.filter((m) => m.sendAt > now);
    for (const msg of ready) {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(msg.data);
      }
    }

    // Process receives
    const arrived = this.recvQueue.filter((m) => m.processAt <= now);
    this.recvQueue = this.recvQueue.filter((m) => m.processAt > now);
    for (const msg of arrived) {
      this.mergeRemote(msg.data);
    }
  }

  private mergeRemote(entries: NsEntries) {
    for (const [ns, keyMap] of Object.entries(entries)) {
      if (!this.remoteState[ns]) this.remoteState[ns] = {};
      for (const [key, entry] of Object.entries(keyMap)) {
        const existing = this.remoteState[ns][key];
        if (!existing || entry.timestamp > existing.timestamp ||
          (entry.timestamp === existing.timestamp && entry.peer > existing.peer)) {
          this.remoteState[ns][key] = entry;
        }
      }
    }
  }

  getRemoteValue(peerId: string): unknown | null {
    return this.remoteState["state"]?.[peerId]?.value ?? null;
  }
}

// --- Reporting ---

export function printReport(
  mode: string,
  players: GamePlayer[],
  stats: ConvergenceStats[],
  elapsed: number
) {
  console.log(`\n=== ${mode.toUpperCase()} Simulation (${NUM_TICKS} ticks, ${elapsed}ms) ===`);
  console.log(`Peers: ${players.length}`);
  console.log(`Latency: ${[...new Set(players.map((p) => `${p.pingMs}ms`))].join(", ")}`);

  // Count total messages
  const totalMessages = stats.reduce((sum, s) => sum + s.messagesSent, 0);
  console.log(`Total messages: ${totalMessages}`);

  // Find convergence point (after warmup)
  const drainStart = Math.floor(NUM_TICKS / 2);
  const convergedAt = stats.find(
    (s) => s.tick >= drainStart && s.inconsistentPairs === 0
  );
  if (convergedAt) {
    console.log(`Converged at tick: ${convergedAt.tick}`);
  } else {
    console.log(`Did NOT converge`);
  }

  // Last 10 ticks
  console.log(`\ntick | inconsistent | entries | messages`);
  console.log(`-----|-------------|---------|--------`);
  const tail = stats.slice(-10);
  for (const s of tail) {
    console.log(
      `${String(s.tick).padStart(4)} | ${String(s.inconsistentPairs).padStart(11)} | ${String(s.totalEntries).padStart(7)} | ${s.messagesSent}`
    );
  }
}

// --- Helpers ---

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function countInconsistentPairs(players: GamePlayer[]): number {
  let inconsistent = 0;
  for (let i = 0; i < players.length; i++) {
    for (let j = i + 1; j < players.length; j++) {
      const stateI = players[i].remoteState["state"] ?? {};
      const stateJ = players[j].remoteState["state"] ?? {};
      // Include own state
      const allKeys = new Set([
        ...Object.keys(stateI),
        ...Object.keys(stateJ),
        players[i].peerId,
        players[j].peerId,
      ]);
      let differ = false;
      for (const key of allKeys) {
        const vi = key === players[i].peerId
          ? players[i].localValue
          : (stateI[key]?.value ?? null);
        const vj = key === players[j].peerId
          ? players[j].localValue
          : (stateJ[key]?.value ?? null);
        if (vi !== vj) {
          differ = true;
          break;
        }
      }
      if (differ) inconsistent++;
    }
  }
  return inconsistent;
}
