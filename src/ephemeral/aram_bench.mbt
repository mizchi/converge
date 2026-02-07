// ARAM-style game simulation benchmark
// 1D lane (0..1000), Team A spawns at 0, Team B at 1000
// 5v5 players + neutral monsters, using EphemeralStore for state sync

///|
priv struct Rng {
  mut state : Int
}

///|
fn Rng::new(seed : Int) -> Rng {
  { state: if seed == 0 { 1 } else { seed } }
}

///|
fn Rng::next(self : Rng) -> Int {
  let mut x = self.state
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  self.state = x
  if x < 0 {
    -x
  } else {
    x
  }
}

///|
fn Rng::next_bound(self : Rng, bound : Int) -> Int {
  self.next() % bound
}

///|
let team_size = 5

///|
let lane_len = 1000

///|
let max_hp = 100

///|
let attack_damage = 20

///|
let attack_range = 50

///|
let move_speed = 15

///|
let monster_hp = 60

///|
let monster_kill_gold = 25

///|
let player_kill_gold = 50

///|
let respawn_ticks = 5

///|
priv struct PlayerState {
  id : String
  team : Int // 0=A, 1=B
  mut x : Int
  mut hp : Int
  mut gold : Int
  mut alive : Bool
  mut dead_timer : Int
}

///|
fn PlayerState::new(id : String, team : Int) -> PlayerState {
  let spawn_x = if team == 0 { 0 } else { lane_len }
  { id, team, x: spawn_x, hp: max_hp, gold: 0, alive: true, dead_timer: 0 }
}

///|
fn PlayerState::respawn(self : PlayerState) -> Unit {
  self.x = if self.team == 0 { 0 } else { lane_len }
  self.hp = max_hp
  self.alive = true
  self.dead_timer = 0
}

///|
priv struct Monster {
  id : String
  x : Int
  mut hp : Int
  mut alive : Bool
}

///|
fn write_player(
  store : EphemeralStore,
  p : PlayerState,
  tick : Int,
  peer : @types.PeerId,
) -> Unit {
  let ts = tick.to_double()
  let pid = p.id
  store.set("pos", pid, @types.Value::Int(p.x), ts, peer)
  store.set("hp", pid, @types.Value::Int(p.hp), ts, peer)
  store.set("gold", pid, @types.Value::Int(p.gold), ts, peer)
  store.set("alive", pid, @types.Value::Bool(p.alive), ts, peer)
}

///|
fn write_monster(
  store : EphemeralStore,
  m : Monster,
  tick : Int,
  peer : @types.PeerId,
) -> Unit {
  let ts = tick.to_double()
  store.set("monster_pos", m.id, @types.Value::Int(m.x), ts, peer)
  store.set("monster_hp", m.id, @types.Value::Int(m.hp), ts, peer)
  store.set("monster_alive", m.id, @types.Value::Bool(m.alive), ts, peer)
}

///|
fn sync_stores(
  src : EphemeralStore,
  dst : EphemeralStore,
  namespaces : Array[String],
) -> Int {
  let mut merged = 0
  for ns in namespaces {
    let entries = src.get_all(ns)
    for key, entry in entries {
      if dst.merge(ns, key, entry) {
        merged += 1
      }
    }
  }
  merged
}

///|
fn int_abs(x : Int) -> Int {
  if x < 0 {
    -x
  } else {
    x
  }
}

///|
fn run_aram(ticks : Int, rng : Rng) -> (Int, Int) {
  let all_ns = [
    "pos", "hp", "gold", "alive", "monster_pos", "monster_hp", "monster_alive",
  ]
  let server = EphemeralStore::new()
  let players : Array[PlayerState] = []
  let client_stores : Array[EphemeralStore] = []
  let client_peers : Array[@types.PeerId] = []
  for i in 0..<team_size {
    players.push(PlayerState::new("a\{i}", 0))
    client_stores.push(EphemeralStore::new())
    client_peers.push(@types.PeerId("a\{i}"))
  }
  for i in 0..<team_size {
    players.push(PlayerState::new("b\{i}", 1))
    client_stores.push(EphemeralStore::new())
    client_peers.push(@types.PeerId("b\{i}"))
  }
  let monsters : Array[Monster] = []
  let mut monster_id_counter = 0
  let mut total_merges = 0
  let mut total_kills = 0
  for tick in 0..<ticks {
    // 1. Spawn monsters (10% chance per tick, max 5 alive)
    let alive_monsters = monsters
      .iter()
      .filter(fn(m) { m.alive })
      .fold(init=0, fn(acc, _m) { acc + 1 })
    if alive_monsters < 5 && rng.next_bound(10) == 0 {
      let mx = 200 + rng.next_bound(600)
      let mid = "m\{monster_id_counter}"
      monster_id_counter += 1
      monsters.push({ id: mid, x: mx, hp: monster_hp, alive: true })
    }
    // 2. Handle respawns
    for p in players {
      if not(p.alive) {
        p.dead_timer += 1
        if p.dead_timer >= respawn_ticks {
          p.respawn()
        }
      }
    }
    // 3. Move alive players toward enemy base with randomness
    for p in players {
      guard p.alive else { continue }
      let target_x = if p.team == 0 { lane_len } else { 0 }
      let dir = if target_x > p.x { 1 } else { -1 }
      let roll = rng.next_bound(10)
      let dx = if roll < 7 {
        dir * move_speed
      } else if roll < 9 {
        0
      } else {
        -dir * (move_speed / 2)
      }
      p.x = p.x + dx
      if p.x < 0 {
        p.x = 0
      }
      if p.x > lane_len {
        p.x = lane_len
      }
    }
    // 4. Player vs player combat
    for i in 0..<players.length() {
      let pi = players[i]
      guard pi.alive else { continue }
      for j = i + 1; j < players.length(); j = j + 1 {
        let pj = players[j]
        guard pj.alive && pi.team != pj.team else { continue }
        if int_abs(pi.x - pj.x) <= attack_range {
          pj.hp -= attack_damage
          pi.hp -= attack_damage
        }
      }
    }
    // 5. Player vs monster combat
    for p in players {
      guard p.alive else { continue }
      for m in monsters {
        guard m.alive else { continue }
        if int_abs(p.x - m.x) <= attack_range {
          m.hp -= attack_damage
          if m.hp <= 0 {
            m.alive = false
            p.gold += monster_kill_gold
          }
        }
      }
    }
    // 6. Check player deaths
    for i in 0..<players.length() {
      let p = players[i]
      if p.alive && p.hp <= 0 {
        p.alive = false
        p.dead_timer = 0
        total_kills += 1
        // Credit kill gold to nearest enemy
        let mut nearest_dist = lane_len + 1
        let mut nearest_idx = -1
        for j in 0..<players.length() {
          let pj = players[j]
          if pj.alive && pj.team != p.team {
            let d = int_abs(pj.x - p.x)
            if d < nearest_dist {
              nearest_dist = d
              nearest_idx = j
            }
          }
        }
        if nearest_idx >= 0 {
          players[nearest_idx].gold += player_kill_gold
        }
      }
    }
    // 7. Each player writes state to their client store
    for i in 0..<players.length() {
      write_player(client_stores[i], players[i], tick, client_peers[i])
    }
    // Write monster state from host (player 0)
    for m in monsters {
      write_monster(client_stores[0], m, tick, client_peers[0])
    }
    // 8. Sync: each client -> server
    for cs in client_stores {
      total_merges += sync_stores(cs, server, all_ns)
    }
    // 9. Sync: server -> each client
    for cs in client_stores {
      total_merges += sync_stores(server, cs, all_ns)
    }
  }
  (total_merges, total_kills)
}

///|
test "aram: 100 ticks simulation" {
  let rng = Rng::new(42)
  let (merges, kills) = run_aram(100, rng)
  inspect(merges > 0, content="true")
  inspect(kills >= 0, content="true")
}

///|
test "bench: ARAM 5v5 100 ticks" (b : @bench.T) {
  b.bench(fn() {
    let rng = Rng::new(42)
    let (merges, _kills) = run_aram(100, rng)
    b.keep(merges)
  })
}

///|
test "bench: ARAM 5v5 500 ticks" (b : @bench.T) {
  b.bench(fn() {
    let rng = Rng::new(42)
    let (merges, _kills) = run_aram(500, rng)
    b.keep(merges)
  })
}
