/**
 * Star topology simulation over WebSocket.
 *
 * Usage:
 *   1. pnpm dev   (start wrangler dev server)
 *   2. pnpm sim:star
 */

import {
  GamePlayer,
  Rng,
  NUM_TICKS,
  NUM_PEERS,
  TICK_MS,
  printReport,
  sleep,
  countInconsistentPairs,
  type ConvergenceStats,
} from "./sim-common";

async function runStarSimulation() {
  const rng = new Rng(42);

  // Create players with mixed latency
  const pingConfig: [number, number][] = [
    [30, 3],
    [80, 3],
    [200, 2],
  ];

  const players: GamePlayer[] = [];
  let idx = 0;
  for (const [pingMs, count] of pingConfig) {
    for (let i = 0; i < count; i++) {
      players.push(new GamePlayer(`p${idx}`, idx % 2, pingMs));
      idx++;
    }
  }

  // Connect all players in star mode
  console.log(`Connecting ${players.length} players in STAR mode...`);
  await Promise.all(players.map((p) => p.connect("star")));
  console.log("All connected. Starting simulation...\n");

  const stats: ConvergenceStats[] = [];
  const startTime = Date.now();
  const writeTicks = Math.floor(NUM_TICKS / 2);

  for (let tick = 0; tick < NUM_TICKS; tick++) {
    // Process network
    for (const p of players) p.processPending();

    // Write phase: each peer writes a random value
    if (tick < writeTicks) {
      for (const p of players) {
        p.localValue = rng.nextBound(1000);
        p.queueSend(tick);
      }
    }

    // Measure
    const inconsistent = countInconsistentPairs(players);
    const totalEntries = Object.values(players[0].remoteState["state"] ?? {}).length;
    stats.push({
      tick,
      inconsistentPairs: inconsistent,
      totalEntries,
      messagesSent: players.length, // star: each sends 1 message per tick
    });

    await sleep(TICK_MS);
  }

  const elapsed = Date.now() - startTime;

  // Disconnect
  for (const p of players) p.close();
  await sleep(100);

  printReport("star", players, stats, elapsed);
}

runStarSimulation().catch((e) => {
  console.error("Star simulation failed:", e);
  process.exit(1);
});
