export const TICK_MS = 50;
export const WORLD_WIDTH = 2200;
export const WORLD_HEIGHT = 1320;
export const RESPAWN_TICKS = 60;

const PLAYER_RADIUS = 12;
const ENEMY_TOUCH_RANGE = 18;
const MAX_ENEMIES = 300;
const SPATIAL_CELL_SIZE = 96;
const MAX_SPAWN_PER_TICK = 14;

export interface PlayerInput {
  peerId: string;
  name: string;
  color: string;
  x: number;
  y: number;
}

export interface PlayerState {
  peerId: string;
  name: string;
  color: string;
  x: number;
  y: number;
  hp: number;
  maxHp: number;
  alive: boolean;
  respawnAtTick: number;
  invulnerableTicks: number;
  level: number;
  xp: number;
  xpToNext: number;
  score: number;
  auraRadius: number;
  auraDps: number;
}

export type EnemyKind = "grunt" | "runner" | "tank";

export interface EnemyState {
  id: string;
  kind: EnemyKind;
  x: number;
  y: number;
  hp: number;
  maxHp: number;
  speed: number;
  touchDamage: number;
  xpValue: number;
}

export interface WorldState {
  tick: number;
  elapsedMs: number;
  seed: number;
  nextEnemyId: number;
  players: Record<string, PlayerState>;
  enemies: Record<string, EnemyState>;
}

export interface TickDebugInfo {
  activePeers: number;
  livingPlayers: number;
  averageLevel: number;
  enemiesBefore: number;
  enemiesAfter: number;
  spawnedEnemies: number;
  spawnBudgetStart: number;
  spawnBudgetLeft: number;
  auraCandidates: number;
  auraHits: number;
  touchHits: number;
  spatialCells: number;
  tickComputeMs: number;
}

export interface PublicWorldState {
  tick: number;
  elapsedMs: number;
  players: Record<string, PlayerState>;
  enemies: EnemyState[];
  online: number;
  debug: TickDebugInfo;
}

export interface StepResult {
  world: WorldState;
  debug: TickDebugInfo;
}

interface EnemyArchetype {
  kind: EnemyKind;
  cost: number;
  hp: number;
  speed: number;
  touchDamage: number;
  xpValue: number;
}

interface SpawnResult {
  seed: number;
  spawned: number;
  budgetStart: number;
  budgetLeft: number;
}

interface EnemySpatialIndex {
  cellSize: number;
  cells: Map<string, EnemyState[]>;
  cellCount: number;
}

export function createInitialWorld(seed = 1): WorldState {
  return {
    tick: 0,
    elapsedMs: 0,
    seed: seed === 0 ? 1 : seed,
    nextEnemyId: 0,
    players: {},
    enemies: {},
  };
}

export function stepWorld(
  world: WorldState,
  inputs: Record<string, PlayerInput>,
  activePeers: ReadonlySet<string>,
): WorldState {
  return stepWorldWithDebug(world, inputs, activePeers).world;
}

export function stepWorldWithDebug(
  world: WorldState,
  inputs: Record<string, PlayerInput>,
  activePeers: ReadonlySet<string>,
): StepResult {
  let seed = world.seed;

  const players: Record<string, PlayerState> = {};
  for (const peerId of activePeers) {
    const input = inputs[peerId];
    const prev = world.players[peerId];
    players[peerId] = updateOrCreatePlayer(prev, input, peerId);
  }

  const enemies: Record<string, EnemyState> = {};
  for (const [enemyId, enemy] of Object.entries(world.enemies)) {
    enemies[enemyId] = { ...enemy };
  }

  const next: WorldState = {
    tick: world.tick + 1,
    elapsedMs: world.elapsedMs + TICK_MS,
    seed,
    nextEnemyId: world.nextEnemyId,
    players,
    enemies,
  };

  const debug: TickDebugInfo = {
    activePeers: activePeers.size,
    livingPlayers: 0,
    averageLevel: 1,
    enemiesBefore: Object.keys(next.enemies).length,
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

  // Countdown shield and respawn before combat.
  for (const player of Object.values(next.players)) {
    if (player.invulnerableTicks > 0) {
      player.invulnerableTicks = player.invulnerableTicks - 1;
    }

    if (!player.alive && player.respawnAtTick >= 0 && next.tick >= player.respawnAtTick) {
      player.alive = true;
      player.hp = player.maxHp;
      player.respawnAtTick = -1;
      player.invulnerableTicks = 20;
    }
  }

  const alivePlayers = Object.values(next.players).filter((p) => p.alive);
  debug.livingPlayers = alivePlayers.length;
  debug.averageLevel = averageLevel(alivePlayers);

  const spawn = spawnEnemies(next, seed, debug.livingPlayers, debug.averageLevel);
  seed = spawn.seed;
  debug.spawnedEnemies = spawn.spawned;
  debug.spawnBudgetStart = spawn.budgetStart;
  debug.spawnBudgetLeft = spawn.budgetLeft;

  // Move enemies and apply touch damage.
  for (const enemy of Object.values(next.enemies)) {
    const target = nearestAlivePlayer(next.players, enemy.x, enemy.y);
    if (!target) continue;

    const dx = target.x - enemy.x;
    const dy = target.y - enemy.y;
    const dist = Math.hypot(dx, dy);

    if (dist > 0.0001) {
      const scale = enemy.speed / dist;
      enemy.x = clamp(enemy.x + dx * scale, 0, WORLD_WIDTH);
      enemy.y = clamp(enemy.y + dy * scale, 0, WORLD_HEIGHT);
    }

    const touchDist = Math.hypot(target.x - enemy.x, target.y - enemy.y);
    if (touchDist <= ENEMY_TOUCH_RANGE && target.invulnerableTicks <= 0) {
      target.hp = Math.max(0, target.hp - enemy.touchDamage);
      debug.touchHits += 1;
    }
  }

  // Aura damage from living players (spatial hash broad phase).
  const enemyIndex = buildEnemySpatialIndex(next.enemies, SPATIAL_CELL_SIZE);
  debug.spatialCells = enemyIndex.cellCount;
  for (const player of Object.values(next.players)) {
    if (!player.alive) continue;
    const nearby = queryEnemyCandidates(enemyIndex, player.x, player.y, player.auraRadius);
    debug.auraCandidates += nearby.length;
    for (const enemy of nearby) {
      const d = Math.hypot(player.x - enemy.x, player.y - enemy.y);
      if (d <= player.auraRadius) {
        enemy.hp -= player.auraDps;
        debug.auraHits += 1;
      }
    }
  }

  // Resolve enemy deaths and XP rewards.
  for (const [enemyId, enemy] of Object.entries(next.enemies)) {
    if (enemy.hp > 0) continue;

    const winner = nearestAlivePlayer(next.players, enemy.x, enemy.y);
    if (winner) {
      winner.xp += enemy.xpValue;
      winner.score += 1;
    }
    delete next.enemies[enemyId];
  }

  // Player death + progression.
  for (const player of Object.values(next.players)) {
    if (player.alive && player.hp <= 0) {
      player.alive = false;
      player.respawnAtTick = next.tick + RESPAWN_TICKS;
      player.invulnerableTicks = 0;
      player.hp = 0;
      continue;
    }

    if (!player.alive) continue;

    while (player.xp >= player.xpToNext) {
      player.xp -= player.xpToNext;
      player.level += 1;
      player.xpToNext = Math.max(2, Math.floor(player.xpToNext * 1.4));
      player.maxHp += 14;
      player.hp = Math.min(player.maxHp, player.hp + 22);
      player.auraRadius += 6;
      player.auraDps += 2;
    }
  }

  next.seed = seed;
  debug.enemiesAfter = Object.keys(next.enemies).length;
  return { world: next, debug };
}

export function toPublicWorldState(
  world: WorldState,
  online: number,
  debug: TickDebugInfo,
): PublicWorldState {
  return {
    tick: world.tick,
    elapsedMs: world.elapsedMs,
    players: world.players,
    enemies: Object.values(world.enemies),
    online,
    debug,
  };
}

function updateOrCreatePlayer(
  prev: PlayerState | undefined,
  input: PlayerInput | undefined,
  peerId: string,
): PlayerState {
  if (!prev) {
    return {
      peerId,
      name: input?.name ?? `Player-${peerId.slice(0, 4)}`,
      color: input?.color ?? "#8ef6ff",
      x: clamp(input?.x ?? WORLD_WIDTH / 2, PLAYER_RADIUS, WORLD_WIDTH - PLAYER_RADIUS),
      y: clamp(input?.y ?? WORLD_HEIGHT / 2, PLAYER_RADIUS, WORLD_HEIGHT - PLAYER_RADIUS),
      hp: 100,
      maxHp: 100,
      alive: true,
      respawnAtTick: -1,
      invulnerableTicks: 0,
      level: 1,
      xp: 0,
      xpToNext: 5,
      score: 0,
      auraRadius: 90,
      auraDps: 8,
    };
  }

  const next: PlayerState = {
    ...prev,
    invulnerableTicks: prev.invulnerableTicks ?? 0,
    name: input?.name ?? prev.name,
    color: input?.color ?? prev.color,
    x: prev.x,
    y: prev.y,
  };

  if (input) {
    next.x = clamp(input.x, PLAYER_RADIUS, WORLD_WIDTH - PLAYER_RADIUS);
    next.y = clamp(input.y, PLAYER_RADIUS, WORLD_HEIGHT - PLAYER_RADIUS);
  }
  return next;
}

function spawnEnemies(
  world: WorldState,
  seedInit: number,
  livingPlayers: number,
  averageLvl: number,
): SpawnResult {
  let seed = seedInit;
  if (livingPlayers === 0) {
    return { seed, spawned: 0, budgetStart: 0, budgetLeft: 0 };
  }

  const dynamicInterval = Math.max(3, 10 - Math.floor(world.elapsedMs / 75_000));
  if (world.tick % dynamicInterval !== 0) {
    return { seed, spawned: 0, budgetStart: 0, budgetLeft: 0 };
  }

  const timeFactor = 1 + world.elapsedMs / 120_000;
  const levelFactor = 1 + Math.max(0, averageLvl - 1) * 0.28;
  let budget = 0.9 * livingPlayers * timeFactor * levelFactor;
  const budgetStart = budget;

  let spawned = 0;
  while (
    budget >= 0.85 &&
    Object.keys(world.enemies).length < MAX_ENEMIES &&
    spawned < MAX_SPAWN_PER_TICK
  ) {
    const archetypeRoll = nextRandom(seed);
    seed = archetypeRoll.seed;
    const archetype = pickArchetype(archetypeRoll.value);

    if (budget < archetype.cost && spawned > 0) {
      break;
    }
    budget -= archetype.cost;

    const pos = randomEdgePosition(seed);
    seed = pos.seed;
    const varianceRoll = nextRandom(seed);
    seed = varianceRoll.seed;

    const difficultyScale = 1 + world.elapsedMs / 180_000 + Math.max(0, averageLvl - 1) * 0.08;
    const variance = 0.85 + varianceRoll.value * 0.3;

    const id = `e${world.nextEnemyId}`;
    world.nextEnemyId += 1;

    const maxHp = Math.max(5, Math.round(archetype.hp * difficultyScale * variance));
    world.enemies[id] = {
      id,
      kind: archetype.kind,
      x: pos.x,
      y: pos.y,
      hp: maxHp,
      maxHp,
      speed: archetype.speed * (0.92 + varianceRoll.value * 0.2),
      touchDamage: Math.max(1, Math.round(archetype.touchDamage * (0.94 + varianceRoll.value * 0.18))),
      xpValue: archetype.xpValue,
    };
    spawned += 1;
  }

  return { seed, spawned, budgetStart, budgetLeft: Math.max(0, budget) };
}

function pickArchetype(v: number): EnemyArchetype {
  if (v < 0.62) {
    return {
      kind: "grunt",
      cost: 1.0,
      hp: 16,
      speed: 1.45,
      touchDamage: 3,
      xpValue: 1,
    };
  }
  if (v < 0.88) {
    return {
      kind: "runner",
      cost: 1.3,
      hp: 11,
      speed: 2.25,
      touchDamage: 2,
      xpValue: 1,
    };
  }
  return {
    kind: "tank",
    cost: 2.1,
    hp: 26,
    speed: 0.96,
    touchDamage: 5,
    xpValue: 2,
  };
}

function randomEdgePosition(seedInit: number): { seed: number; x: number; y: number } {
  let seed = seedInit;
  const sideRoll = nextRandom(seed);
  seed = sideRoll.seed;
  const spanRoll = nextRandom(seed);
  seed = spanRoll.seed;

  const edge = Math.floor(sideRoll.value * 4);
  const span = spanRoll.value;

  if (edge === 0) {
    return { seed, x: 0, y: span * WORLD_HEIGHT };
  }
  if (edge === 1) {
    return { seed, x: WORLD_WIDTH, y: span * WORLD_HEIGHT };
  }
  if (edge === 2) {
    return { seed, x: span * WORLD_WIDTH, y: 0 };
  }
  return { seed, x: span * WORLD_WIDTH, y: WORLD_HEIGHT };
}

function averageLevel(players: PlayerState[]): number {
  if (players.length === 0) return 1;
  let total = 0;
  for (const player of players) {
    total += player.level;
  }
  return total / players.length;
}

function nearestAlivePlayer(
  players: Record<string, PlayerState>,
  x: number,
  y: number,
): PlayerState | null {
  let best: PlayerState | null = null;
  let bestDist = Number.POSITIVE_INFINITY;
  for (const player of Object.values(players)) {
    if (!player.alive) continue;
    const d = Math.hypot(player.x - x, player.y - y);
    if (d < bestDist) {
      best = player;
      bestDist = d;
    }
  }
  return best;
}

function buildEnemySpatialIndex(
  enemies: Record<string, EnemyState>,
  cellSize: number,
): EnemySpatialIndex {
  const cells = new Map<string, EnemyState[]>();
  for (const enemy of Object.values(enemies)) {
    const cx = Math.floor(enemy.x / cellSize);
    const cy = Math.floor(enemy.y / cellSize);
    const key = `${cx}:${cy}`;
    const list = cells.get(key);
    if (list) {
      list.push(enemy);
    } else {
      cells.set(key, [enemy]);
    }
  }
  return {
    cellSize,
    cellCount: cells.size,
    cells,
  };
}

function queryEnemyCandidates(
  index: EnemySpatialIndex,
  x: number,
  y: number,
  radius: number,
): EnemyState[] {
  const minX = Math.floor((x - radius) / index.cellSize);
  const maxX = Math.floor((x + radius) / index.cellSize);
  const minY = Math.floor((y - radius) / index.cellSize);
  const maxY = Math.floor((y + radius) / index.cellSize);

  const result: EnemyState[] = [];
  const seen = new Set<string>();

  for (let cx = minX; cx <= maxX; cx++) {
    for (let cy = minY; cy <= maxY; cy++) {
      const key = `${cx}:${cy}`;
      const bucket = index.cells.get(key);
      if (!bucket) continue;
      for (const enemy of bucket) {
        if (seen.has(enemy.id)) continue;
        seen.add(enemy.id);
        result.push(enemy);
      }
    }
  }
  return result;
}

function nextRandom(seedIn: number): { seed: number; value: number } {
  let seed = seedIn | 0;
  seed = (Math.imul(1664525, seed) + 1013904223) | 0;
  const value = (seed >>> 0) / 0xffffffff;
  return { seed, value };
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}
