/**
 * ARAM P2P game simulation over WebSocket
 *
 * Usage:
 *   1. pnpm install && pnpm dev   (start wrangler dev server)
 *   2. pnpm sim                   (run simulation in another terminal)
 *
 * Connects 10 players (5v5) via WebSocket to the relay DO.
 * Each player runs local ARAM game logic with artificial latency.
 * Measures and reports state inconsistency per latency class.
 */

const SERVER_URL = process.env.SERVER_URL ?? "ws://localhost:8787/ws";
const TICK_MS = 16; // 60fps
const NUM_TICKS = 300;
const WARMUP_TICKS = 20;
const LANE_LEN = 1000;
const MAX_HP = 100;
const ATTACK_DAMAGE = 20;
const ATTACK_RANGE = 50;
const MOVE_SPEED = 15;
const MONSTER_HP = 60;
const MONSTER_KILL_GOLD = 25;
const PLAYER_KILL_GOLD = 50;
const RESPAWN_TICKS = 5;

// --- Types ---

interface EphemeralEntry {
  key: string;
  value: unknown;
  timestamp: number;
  peer: string;
}

type NsEntries = Record<string, Record<string, EphemeralEntry>>;

interface PendingMessage {
  processAt: number; // Date.now() when this becomes visible
  data: NsEntries;
}

// --- PRNG (same xorshift32 as MoonBit version) ---

class Rng {
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

// --- Per-latency-class stats ---

interface LatencyStats {
  label: string;
  pingMs: number;
  playerCount: number;
  posMismatches: number;
  hpMismatches: number;
  aliveMismatches: number;
  totalPosError: number;
  samples: number;
}

function newStats(label: string, pingMs: number, count: number): LatencyStats {
  return {
    label,
    pingMs,
    playerCount: count,
    posMismatches: 0,
    hpMismatches: 0,
    aliveMismatches: 0,
    totalPosError: 0,
    samples: 0,
  };
}

// --- Monster ---

interface Monster {
  id: string;
  x: number;
  hp: number;
  alive: boolean;
}

// --- Game Player ---

class GamePlayer {
  peerId: string;
  team: number;
  pingMs: number;
  pingClass: number;
  x: number;
  hp = MAX_HP;
  gold = 0;
  alive = true;
  deadTimer = 0;

  ws: WebSocket | null = null;
  connected = false;

  // Network delay buffers
  private sendQueue: Array<{ sendAt: number; data: string }> = [];
  private recvQueue: PendingMessage[] = [];
  private oneWayMs: number;

  // Local view of other players (from received diffs)
  remoteState: NsEntries = {};

  constructor(peerId: string, team: number, pingMs: number, pingClass: number) {
    this.peerId = peerId;
    this.team = team;
    this.pingMs = pingMs;
    this.pingClass = pingClass;
    this.oneWayMs = Math.max(pingMs / 2, pingMs > 0 ? TICK_MS : 0);
    this.x = team === 0 ? 0 : LANE_LEN;
  }

  respawn() {
    this.x = this.team === 0 ? 0 : LANE_LEN;
    this.hp = MAX_HP;
    this.alive = true;
    this.deadTimer = 0;
  }

  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const url = `${SERVER_URL}?peer_id=${this.peerId}&team=${this.team}`;
      this.ws = new WebSocket(url);

      this.ws.addEventListener("open", () => {
        this.connected = true;
        resolve();
      });

      this.ws.addEventListener("message", (event) => {
        try {
          const msg = JSON.parse(String(event.data));
          if (msg.type === "snapshot" || msg.type === "diff") {
            const entries: NsEntries = msg.entries;
            // Add to receive buffer with artificial delay
            this.recvQueue.push({
              processAt: Date.now() + this.oneWayMs,
              data: entries,
            });
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

  /** Build own state as NsEntries */
  buildState(tick: number): NsEntries {
    const ts = tick;
    const p = this.peerId;
    const entry = (ns: string, val: unknown): [string, Record<string, EphemeralEntry>] => [
      ns,
      { [p]: { key: p, value: val, timestamp: ts, peer: p } },
    ];
    return Object.fromEntries([
      entry("pos", this.x),
      entry("hp", this.hp),
      entry("gold", this.gold),
      entry("alive", this.alive),
    ]);
  }

  /** Queue state send with artificial delay */
  queueSend(tick: number) {
    const data = JSON.stringify({ type: "state", entries: this.buildState(tick) });
    this.sendQueue.push({ sendAt: Date.now() + this.oneWayMs, data });
  }

  /** Flush delayed sends and process delayed receives */
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

  /** Read another player's position from local view */
  getRemotePos(peerId: string): number | null {
    const entry = this.remoteState["pos"]?.[peerId];
    return entry ? (entry.value as number) : null;
  }

  getRemoteAlive(peerId: string): boolean | null {
    const entry = this.remoteState["alive"]?.[peerId];
    return entry != null ? (entry.value as boolean) : null;
  }
}

// --- Simulation ---

async function runSimulation() {
  const rng = new Rng(42);

  // Latency classes: (pingMs, count)
  const pingConfig: [number, number][] = [
    [30, 3],
    [80, 4],
    [200, 3],
  ];

  const players: GamePlayer[] = [];
  let idx = 0;
  for (let cls = 0; cls < pingConfig.length; cls++) {
    const [pingMs, count] = pingConfig[cls];
    for (let i = 0; i < count; i++) {
      const team = idx % 2;
      players.push(new GamePlayer(`p${idx}`, team, pingMs, cls));
      idx++;
    }
  }

  const stats: LatencyStats[] = pingConfig.map(([ping, count]) =>
    newStats(`${ping}ms`, ping, count)
  );

  // Connect all players
  console.log(`Connecting ${players.length} players...`);
  await Promise.all(players.map((p) => p.connect()));
  console.log("All connected. Starting simulation...\n");

  // Monster state (managed by player 0 as host)
  const monsters: Monster[] = [];
  let monsterIdCounter = 0;

  const startTime = Date.now();

  for (let tick = 0; tick < NUM_TICKS; tick++) {
    // 1. Process pending network messages
    for (const p of players) p.processPending();

    // 2. Spawn monsters (10% chance, max 5)
    const aliveMonsters = monsters.filter((m) => m.alive).length;
    if (aliveMonsters < 5 && rng.nextBound(10) === 0) {
      const mx = 200 + rng.nextBound(600);
      monsters.push({ id: `m${monsterIdCounter++}`, x: mx, hp: MONSTER_HP, alive: true });
    }

    // 3. Respawns
    for (const p of players) {
      if (!p.alive) {
        p.deadTimer++;
        if (p.deadTimer >= RESPAWN_TICKS) p.respawn();
      }
    }

    // 4. Movement
    for (const p of players) {
      if (!p.alive) continue;
      const targetX = p.team === 0 ? LANE_LEN : 0;
      const dir = targetX > p.x ? 1 : -1;
      const roll = rng.nextBound(10);
      let dx: number;
      if (roll < 7) dx = dir * MOVE_SPEED;
      else if (roll < 9) dx = 0;
      else dx = -dir * Math.floor(MOVE_SPEED / 2);
      p.x = Math.max(0, Math.min(LANE_LEN, p.x + dx));
    }

    // 5. PvP combat (each player takes damage based on local view)
    for (const p of players) {
      if (!p.alive) continue;
      for (const other of players) {
        if (other === p || other.team === p.team) continue;
        // Use local view of enemy position
        const enemyX = p.getRemotePos(other.peerId);
        const enemyAlive = p.getRemoteAlive(other.peerId);
        if (enemyX == null || enemyAlive == null) continue;
        if (enemyAlive && Math.abs(p.x - enemyX) <= ATTACK_RANGE) {
          p.hp -= ATTACK_DAMAGE;
        }
      }
    }

    // 6. PvE combat (host player manages monster HP)
    for (const p of players) {
      if (!p.alive) continue;
      for (const m of monsters) {
        if (!m.alive) continue;
        if (Math.abs(p.x - m.x) <= ATTACK_RANGE) {
          m.hp -= ATTACK_DAMAGE;
          if (m.hp <= 0) {
            m.alive = false;
            p.gold += MONSTER_KILL_GOLD;
          }
        }
      }
    }

    // 7. Death check
    for (let i = 0; i < players.length; i++) {
      const p = players[i];
      if (p.alive && p.hp <= 0) {
        p.alive = false;
        p.deadTimer = 0;
        // Credit nearest enemy
        let nearest = -1;
        let nearestDist = LANE_LEN + 1;
        for (let j = 0; j < players.length; j++) {
          if (players[j].alive && players[j].team !== p.team) {
            const d = Math.abs(players[j].x - p.x);
            if (d < nearestDist) {
              nearestDist = d;
              nearest = j;
            }
          }
        }
        if (nearest >= 0) players[nearest].gold += PLAYER_KILL_GOLD;
      }
    }

    // 8. Send own state to relay (with artificial delay)
    for (const p of players) p.queueSend(tick);

    // Also send monster state from host
    if (monsters.length > 0) {
      const host = players[0];
      const monsterEntries: NsEntries = { monster_pos: {}, monster_hp: {}, monster_alive: {} };
      for (const m of monsters) {
        const ts = tick;
        const peer = host.peerId;
        monsterEntries.monster_pos[m.id] = { key: m.id, value: m.x, timestamp: ts, peer };
        monsterEntries.monster_hp[m.id] = { key: m.id, value: m.hp, timestamp: ts, peer };
        monsterEntries.monster_alive[m.id] = { key: m.id, value: m.alive, timestamp: ts, peer };
      }
      const data = JSON.stringify({ type: "state", entries: monsterEntries });
      host.sendQueue.push({ sendAt: Date.now() + host["oneWayMs"], data });
    }

    // 9. Measure inconsistency (skip warmup)
    if (tick >= WARMUP_TICKS) {
      for (const observer of players) {
        const st = stats[observer.pingClass];
        for (const target of players) {
          if (target === observer) continue;
          st.samples++;

          // Position
          const viewX = observer.getRemotePos(target.peerId);
          if (viewX == null || viewX !== target.x) {
            st.posMismatches++;
            if (viewX != null) st.totalPosError += Math.abs(viewX - target.x);
            else st.totalPosError += LANE_LEN; // no data = max error
          }

          // HP
          const viewHp = observer.remoteState["hp"]?.[target.peerId]?.value as number | undefined;
          if (viewHp == null || viewHp !== target.hp) st.hpMismatches++;

          // Alive
          const viewAlive = observer.getRemoteAlive(target.peerId);
          if (viewAlive == null || viewAlive !== target.alive) st.aliveMismatches++;
        }
      }
    }

    // Sleep to allow event loop to process WebSocket messages
    await sleep(TICK_MS);
  }

  const elapsed = Date.now() - startTime;

  // Disconnect
  for (const p of players) p.close();
  await sleep(100);

  // Report
  console.log(`=== P2P WebSocket ARAM Simulation (${NUM_TICKS} ticks, ${elapsed}ms) ===`);
  console.log(`Players: ${players.length} (5v5), Tick: ${TICK_MS}ms`);
  console.log(`Latency classes: ${pingConfig.map(([p, c]) => `${p}ms×${c}`).join(", ")}`);
  console.log();
  console.log(
    "ping   | players | pos_err% | avg_pos_err | hp_err%  | alive_err% | samples"
  );
  console.log(
    "-------|---------|----------|-------------|----------|------------|--------"
  );

  let tPos = 0, tHp = 0, tAlive = 0, tSamples = 0, tPosErr = 0, tPosMis = 0;

  for (const st of stats) {
    const pctPos = pct(st.posMismatches, st.samples);
    const avgErr = st.posMismatches > 0
      ? (st.totalPosError / st.posMismatches).toFixed(1)
      : "0.0";
    const pctHp = pct(st.hpMismatches, st.samples);
    const pctAlive = pct(st.aliveMismatches, st.samples);
    console.log(
      `${st.label.padEnd(6)} | ${String(st.playerCount).padEnd(7)} | ${pctPos.padStart(6)}%  | ${avgErr.padStart(7)} units | ${pctHp.padStart(6)}%  | ${pctAlive.padStart(8)}%  | ${st.samples}`
    );
    tPos += st.posMismatches;
    tHp += st.hpMismatches;
    tAlive += st.aliveMismatches;
    tSamples += st.samples;
    tPosErr += st.totalPosError;
    tPosMis += st.posMismatches;
  }

  console.log(
    "-------|---------|----------|-------------|----------|------------|--------"
  );
  const tAvg = tPosMis > 0 ? (tPosErr / tPosMis).toFixed(1) : "0.0";
  console.log(
    `total  | ${String(players.length).padEnd(7)} | ${pct(tPos, tSamples).padStart(6)}%  | ${tAvg.padStart(7)} units | ${pct(tHp, tSamples).padStart(6)}%  | ${pct(tAlive, tSamples).padStart(8)}%  | ${tSamples}`
  );
}

function pct(num: number, denom: number): string {
  if (denom === 0) return "0.0";
  return ((num / denom) * 100).toFixed(1);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// --- Entry point ---

runSimulation().catch((e) => {
  console.error("Simulation failed:", e);
  process.exit(1);
});
