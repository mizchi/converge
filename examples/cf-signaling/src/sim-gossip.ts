/**
 * Gossip topology simulation over WebSocket.
 *
 * Usage:
 *   1. pnpm dev   (start wrangler dev server)
 *   2. pnpm sim:gossip
 *
 * Flow:
 *   Client A sends state to server with msgId
 *   Server merges, picks k random peers, sends gossip_diff
 *   Peer B receives gossip_diff, merges locally, re-sends to server (gossip_relay)
 *   Server checks seenMessages[msgId] -> already seen -> STOP
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
  type NsEntries,
} from "./sim-common";

async function runGossipSimulation() {
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
      const player = new GamePlayer(`p${idx}`, idx % 2, pingMs);

      // Set up gossip re-relay handler
      player.onGossipDiff = (entries: NsEntries, msgId: string) => {
        // After merging locally, re-send to server for further propagation
        const data = JSON.stringify({
          type: "gossip_relay",
          entries,
          msgId,
        });
        const oneWayMs = Math.max(pingMs / 2, pingMs > 0 ? TICK_MS : 0);
        player.sendQueue.push({ sendAt: Date.now() + oneWayMs, data });
      };

      players.push(player);
      idx++;
    }
  }

  // Connect all players in gossip mode
  console.log(`Connecting ${players.length} players in GOSSIP mode...`);
  await Promise.all(players.map((p) => p.connect("gossip")));
  console.log("All connected. Starting simulation...\n");

  const stats: ConvergenceStats[] = [];
  const startTime = Date.now();
  const writeTicks = Math.floor(NUM_TICKS / 2);
  let totalMessagesSent = 0;

  for (let tick = 0; tick < NUM_TICKS; tick++) {
    // Process network
    for (const p of players) p.processPending();

    let tickMessages = 0;

    // Write phase
    if (tick < writeTicks) {
      for (const p of players) {
        p.localValue = rng.nextBound(1000);
        const msgId = `${p.peerId}:${tick}`;
        p.queueSend(tick, "state", { msgId });
        tickMessages++;
      }
    }

    totalMessagesSent += tickMessages;

    // Measure
    const inconsistent = countInconsistentPairs(players);
    const totalEntries = Object.values(players[0].remoteState["state"] ?? {}).length;
    stats.push({
      tick,
      inconsistentPairs: inconsistent,
      totalEntries,
      messagesSent: tickMessages,
    });

    await sleep(TICK_MS);
  }

  const elapsed = Date.now() - startTime;

  // Disconnect
  for (const p of players) p.close();
  await sleep(100);

  printReport("gossip", players, stats, elapsed);
}

runGossipSimulation().catch((e) => {
  console.error("Gossip simulation failed:", e);
  process.exit(1);
});
