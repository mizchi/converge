import test from "node:test";
import assert from "node:assert/strict";

import {
  RESPAWN_TICKS,
  createInitialWorld,
  stepWorld,
  stepWorldWithDebug,
  type EnemyState,
  type PlayerInput,
  type PlayerState,
} from "./game";

const BASE_INPUT: PlayerInput = {
  peerId: "p1",
  name: "Player One",
  color: "#80ffea",
  x: 640,
  y: 360,
};

function singleInput(input: PlayerInput): Record<string, PlayerInput> {
  return { [input.peerId]: input };
}

function withPlayer(world: ReturnType<typeof createInitialWorld>, player: PlayerState) {
  return {
    ...world,
    players: {
      ...world.players,
      [player.peerId]: player,
    },
  };
}

function withEnemy(world: ReturnType<typeof createInitialWorld>, enemy: EnemyState) {
  return {
    ...world,
    enemies: {
      ...world.enemies,
      [enemy.id]: enemy,
    },
    nextEnemyId: Math.max(world.nextEnemyId, Number.parseInt(enemy.id.replace("e", ""), 10) + 1),
  };
}

test("stepWorld: 新規プレイヤーが初期化される", () => {
  const world = createInitialWorld(42);
  const next = stepWorld(world, singleInput(BASE_INPUT), new Set([BASE_INPUT.peerId]));

  const p = next.players[BASE_INPUT.peerId];
  assert.ok(p, "player must exist");
  assert.equal(p.level, 1);
  assert.equal(p.alive, true);
  assert.equal(p.maxHp, 100);
});

test("stepWorld: オーラ攻撃で敵を倒すとXPとスコアが増える", () => {
  const baseWorld = createInitialWorld(1);
  const player: PlayerState = {
    peerId: BASE_INPUT.peerId,
    name: BASE_INPUT.name,
    color: BASE_INPUT.color,
    x: BASE_INPUT.x,
    y: BASE_INPUT.y,
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
    auraDps: 10,
  };
  const enemy: EnemyState = {
    id: "e0",
    kind: "grunt",
    x: BASE_INPUT.x + 20,
    y: BASE_INPUT.y,
    hp: 6,
    maxHp: 6,
    speed: 0,
    touchDamage: 0,
    xpValue: 2,
  };

  const world = withEnemy(withPlayer(baseWorld, player), enemy);
  const next = stepWorld(world, singleInput(BASE_INPUT), new Set([BASE_INPUT.peerId]));

  assert.equal(next.enemies[enemy.id], undefined);
  assert.equal(next.players[BASE_INPUT.peerId].xp, 2);
  assert.equal(next.players[BASE_INPUT.peerId].score, 1);
});

test("stepWorld: XPが閾値を超えるとレベルアップする", () => {
  const baseWorld = createInitialWorld(1);
  const player: PlayerState = {
    peerId: BASE_INPUT.peerId,
    name: BASE_INPUT.name,
    color: BASE_INPUT.color,
    x: BASE_INPUT.x,
    y: BASE_INPUT.y,
    hp: 80,
    maxHp: 100,
    alive: true,
    respawnAtTick: -1,
    invulnerableTicks: 0,
    level: 1,
    xp: 4,
    xpToNext: 5,
    score: 0,
    auraRadius: 90,
    auraDps: 10,
  };
  const enemy: EnemyState = {
    id: "e0",
    kind: "grunt",
    x: BASE_INPUT.x + 10,
    y: BASE_INPUT.y,
    hp: 5,
    maxHp: 5,
    speed: 0,
    touchDamage: 0,
    xpValue: 2,
  };

  const world = withEnemy(withPlayer(baseWorld, player), enemy);
  const next = stepWorld(world, singleInput(BASE_INPUT), new Set([BASE_INPUT.peerId]));
  const p = next.players[BASE_INPUT.peerId];

  assert.equal(p.level, 2);
  assert.equal(p.xp, 1);
  assert.ok(p.maxHp > 100);
  assert.ok(p.auraDps > 10);
});

test("stepWorld: 死亡したプレイヤーは一定tick後にリスポーンする", () => {
  const baseWorld = createInitialWorld(99);
  const player: PlayerState = {
    peerId: BASE_INPUT.peerId,
    name: BASE_INPUT.name,
    color: BASE_INPUT.color,
    x: BASE_INPUT.x,
    y: BASE_INPUT.y,
    hp: 3,
    maxHp: 100,
    alive: true,
    respawnAtTick: -1,
    invulnerableTicks: 0,
    level: 1,
    xp: 0,
    xpToNext: 5,
    score: 0,
    auraRadius: 30,
    auraDps: 0,
  };
  const enemy: EnemyState = {
    id: "e0",
    kind: "tank",
    x: BASE_INPUT.x,
    y: BASE_INPUT.y,
    hp: 999,
    maxHp: 999,
    speed: 0,
    touchDamage: 5,
    xpValue: 0,
  };

  let world = withEnemy(withPlayer(baseWorld, player), enemy);
  world = stepWorld(world, singleInput(BASE_INPUT), new Set([BASE_INPUT.peerId]));

  assert.equal(world.players[BASE_INPUT.peerId].alive, false);

  for (let i = 0; i < RESPAWN_TICKS; i++) {
    world = stepWorld(world, singleInput(BASE_INPUT), new Set([BASE_INPUT.peerId]));
  }

  assert.equal(world.players[BASE_INPUT.peerId].alive, true);
  assert.equal(world.players[BASE_INPUT.peerId].hp, world.players[BASE_INPUT.peerId].maxHp);
});

test("stepWorldWithDebug: 空間ハッシュで遠距離敵へのオーラ処理を抑制", () => {
  const baseWorld = createInitialWorld(123);
  const player: PlayerState = {
    peerId: BASE_INPUT.peerId,
    name: BASE_INPUT.name,
    color: BASE_INPUT.color,
    x: BASE_INPUT.x,
    y: BASE_INPUT.y,
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
    auraDps: 10,
  };

  const nearEnemy: EnemyState = {
    id: "e0",
    kind: "grunt",
    x: BASE_INPUT.x + 30,
    y: BASE_INPUT.y + 10,
    hp: 60,
    maxHp: 60,
    speed: 0,
    touchDamage: 0,
    xpValue: 1,
  };
  const farEnemy: EnemyState = {
    id: "e1",
    kind: "grunt",
    x: BASE_INPUT.x + 400,
    y: BASE_INPUT.y + 400,
    hp: 60,
    maxHp: 60,
    speed: 0,
    touchDamage: 0,
    xpValue: 1,
  };

  const withEnemies = withEnemy(withEnemy(withPlayer(baseWorld, player), nearEnemy), farEnemy);
  const result = stepWorldWithDebug(withEnemies, singleInput(BASE_INPUT), new Set([BASE_INPUT.peerId]));

  assert.equal(result.world.enemies[nearEnemy.id].hp, 50);
  assert.equal(result.world.enemies[farEnemy.id].hp, 60);
  assert.equal(result.debug.auraHits, 1);
  assert.ok(result.debug.auraCandidates < 2);
});

test("stepWorldWithDebug: スポーン予算はレベルで増加する", () => {
  const lowPlayer: PlayerState = {
    peerId: BASE_INPUT.peerId,
    name: BASE_INPUT.name,
    color: BASE_INPUT.color,
    x: BASE_INPUT.x,
    y: BASE_INPUT.y,
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
  const highPlayer: PlayerState = {
    ...lowPlayer,
    level: 6,
  };

  const lowWorld = withPlayer({ ...createInitialWorld(7), tick: 9 }, lowPlayer);
  const highWorld = withPlayer({ ...createInitialWorld(7), tick: 9 }, highPlayer);

  const low = stepWorldWithDebug(lowWorld, singleInput(BASE_INPUT), new Set([BASE_INPUT.peerId]));
  const high = stepWorldWithDebug(highWorld, singleInput(BASE_INPUT), new Set([BASE_INPUT.peerId]));

  assert.ok(high.debug.spawnBudgetStart > low.debug.spawnBudgetStart);
  assert.ok(high.debug.spawnedEnemies >= low.debug.spawnedEnemies);
});
