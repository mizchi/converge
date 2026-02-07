// Latency-induced inconsistency measurement
//
// Models per-player network delay (30-200ms ping) as tick-based queues.
// Each tick = 16ms (60fps). One-way delay = ping_ms / 2 / 16.
// Measures how often each client's view of other players diverges
// from ground truth, broken down by latency class.

///|
let tick_ms = 16

///|
/// A packet in flight: entries + scheduled arrival tick
priv struct InFlightPacket {
  arrival_tick : Int
  entries : Array[(String, String, EphemeralEntry)] // (ns, key, entry)
}

///|
/// Per-client network pipe with configurable one-way delay
priv struct NetPipe {
  delay_ticks : Int
  queue : Array[InFlightPacket]
}

///|
fn NetPipe::new(ping_ms : Int) -> NetPipe {
  let delay = ping_ms / 2 / tick_ms
  // At least 1 tick delay for any non-zero ping
  let delay = if ping_ms > 0 && delay == 0 { 1 } else { delay }
  { delay_ticks: delay, queue: [] }
}

///|
/// Enqueue a snapshot for delivery after delay
fn NetPipe::send(
  self : NetPipe,
  current_tick : Int,
  src : EphemeralStore,
  namespaces : Array[String],
) -> Unit {
  let entries : Array[(String, String, EphemeralEntry)] = []
  for ns in namespaces {
    let ns_entries = src.get_all(ns)
    for key, entry in ns_entries {
      entries.push((ns, key, entry))
    }
  }
  self.queue.push({ arrival_tick: current_tick + self.delay_ticks, entries })
}

///|
/// Deliver all packets that have arrived by current_tick. Returns merge count.
fn NetPipe::receive(
  self : NetPipe,
  current_tick : Int,
  dst : EphemeralStore,
) -> Int {
  let mut merged = 0
  let remaining : Array[InFlightPacket] = []
  for pkt in self.queue {
    if pkt.arrival_tick <= current_tick {
      for entry in pkt.entries {
        let (ns, key, e) = entry
        if dst.merge(ns, key, e) {
          merged += 1
        }
      }
    } else {
      remaining.push(pkt)
    }
  }
  // Replace queue with remaining
  self.queue.clear()
  for p in remaining {
    self.queue.push(p)
  }
  merged
}

///|
/// Per-latency-class stats
priv struct LatencyStats {
  label : String
  ping_ms : Int
  player_count : Int
  mut pos_mismatches : Int // ticks where position differs from truth
  mut hp_mismatches : Int
  mut alive_mismatches : Int
  mut total_pos_error : Int // cumulative |true_x - view_x|
  mut samples : Int // total (client, other_player, tick) comparisons
}

///|
fn LatencyStats::new(
  label : String,
  ping_ms : Int,
  player_count : Int,
) -> LatencyStats {
  {
    label,
    ping_ms,
    player_count,
    pos_mismatches: 0,
    hp_mismatches: 0,
    alive_mismatches: 0,
    total_pos_error: 0,
    samples: 0,
  }
}

///|
/// Run ARAM with per-player latency, return stats per latency class.
///
/// ping_config: Array of (ping_ms, count) — e.g. [(30, 3), (100, 4), (200, 3)]
/// Assigns players to teams round-robin.
fn run_aram_with_latency(
  ticks : Int,
  rng : Rng,
  ping_config : Array[(Int, Int)],
) -> Array[LatencyStats] {
  let all_ns = [
    "pos", "hp", "gold", "alive", "monster_pos", "monster_hp", "monster_alive",
  ]
  // Build players with assigned pings
  let players : Array[PlayerState] = []
  let pings : Array[Int] = []
  let ping_class : Array[Int] = [] // index into ping_config
  let mut player_idx = 0
  for class_idx, config in ping_config {
    let (ping_ms, count) = config
    for _i in 0..<count {
      let team = player_idx % 2
      let pid = "p\{player_idx}"
      players.push(PlayerState::new(pid, team))
      pings.push(ping_ms)
      ping_class.push(class_idx)
      player_idx += 1
    }
  }
  let num_players = players.length()
  // Create stores and net pipes
  let server = EphemeralStore::new()
  let client_stores : Array[EphemeralStore] = []
  let client_peers : Array[@types.PeerId] = []
  // client -> server pipes (upload)
  let upload_pipes : Array[NetPipe] = []
  // server -> client pipes (download)
  let download_pipes : Array[NetPipe] = []
  for i in 0..<num_players {
    client_stores.push(EphemeralStore::new())
    client_peers.push(@types.PeerId("p\{i}"))
    upload_pipes.push(NetPipe::new(pings[i]))
    download_pipes.push(NetPipe::new(pings[i]))
  }
  // Stats per latency class
  let stats : Array[LatencyStats] = []
  for class_idx, config in ping_config {
    let (ping_ms, count) = config
    ignore(class_idx)
    stats.push(LatencyStats::new("\{ping_ms}ms", ping_ms, count))
  }
  // Monsters
  let monsters : Array[Monster] = []
  let mut monster_id_counter = 0
  for tick in 0..<ticks {
    // --- Game logic (same as aram_bench) ---
    // 1. Spawn monsters
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
    // 2. Respawns
    for p in players {
      if not(p.alive) {
        p.dead_timer += 1
        if p.dead_timer >= respawn_ticks {
          p.respawn()
        }
      }
    }
    // 3. Movement
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
    // 4. PvP combat
    for i in 0..<num_players {
      let pi = players[i]
      guard pi.alive else { continue }
      for j = i + 1; j < num_players; j = j + 1 {
        let pj = players[j]
        guard pj.alive && pi.team != pj.team else { continue }
        if int_abs(pi.x - pj.x) <= attack_range {
          pj.hp -= attack_damage
          pi.hp -= attack_damage
        }
      }
    }
    // 5. PvE combat
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
    // 6. Death check
    for i in 0..<num_players {
      let p = players[i]
      if p.alive && p.hp <= 0 {
        p.alive = false
        p.dead_timer = 0
        let mut nearest_dist = lane_len + 1
        let mut nearest_idx = -1
        for j in 0..<num_players {
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
    // --- Network simulation ---
    // 7. Each client writes their own state locally
    for i in 0..<num_players {
      write_player(client_stores[i], players[i], tick, client_peers[i])
    }
    // Host (player 0) writes monster state
    for m in monsters {
      write_monster(client_stores[0], m, tick, client_peers[0])
    }
    // 8. Each client enqueues upload to server (delayed)
    for i in 0..<num_players {
      upload_pipes[i].send(tick, client_stores[i], all_ns)
    }
    // 9. Deliver arrived uploads to server
    for i in 0..<num_players {
      ignore(upload_pipes[i].receive(tick, server))
    }
    // 10. Server enqueues download to each client (delayed)
    for i in 0..<num_players {
      download_pipes[i].send(tick, server, all_ns)
    }
    // 11. Deliver arrived downloads to each client
    for i in 0..<num_players {
      ignore(download_pipes[i].receive(tick, client_stores[i]))
    }
    // --- Measure inconsistency ---
    // Compare each client's view of every OTHER player against ground truth
    for observer_idx in 0..<num_players {
      let cs = client_stores[observer_idx]
      let cls = ping_class[observer_idx]
      let st = stats[cls]
      for target_idx in 0..<num_players {
        if target_idx == observer_idx {
          continue // skip self
        }
        let p = players[target_idx]
        let pid = p.id
        st.samples += 1
        // Position check
        match cs.get("pos", pid) {
          Some(entry) =>
            match entry.value {
              Int(view_x) =>
                if view_x != p.x {
                  st.pos_mismatches += 1
                  st.total_pos_error += int_abs(view_x - p.x)
                }
              _ => st.pos_mismatches += 1
            }
          None => st.pos_mismatches += 1 // no data yet
        }
        // HP check
        match cs.get("hp", pid) {
          Some(entry) =>
            match entry.value {
              Int(view_hp) => if view_hp != p.hp { st.hp_mismatches += 1 }
              _ => st.hp_mismatches += 1
            }
          None => st.hp_mismatches += 1
        }
        // Alive check
        match cs.get("alive", pid) {
          Some(entry) =>
            match entry.value {
              Bool(view_alive) =>
                if view_alive != p.alive {
                  st.alive_mismatches += 1
                }
              _ => st.alive_mismatches += 1
            }
          None => st.alive_mismatches += 1
        }
      }
    }
  }
  stats
}

///|
fn format_pct(num : Int, denom : Int) -> String {
  if denom == 0 {
    return "0.0"
  }
  let pct = num * 1000 / denom // 1 decimal place
  let whole = pct / 10
  let frac = pct % 10
  "\{whole}.\{frac}"
}

///|
fn format_avg(total : Int, count : Int) -> String {
  if count == 0 {
    return "0.0"
  }
  let avg10 = total * 10 / count
  let whole = avg10 / 10
  let frac = avg10 % 10
  "\{whole}.\{frac}"
}

///|
/// 500 ticks, mixed latency: 30ms x3, 80ms x4, 200ms x3
test "latency: inconsistency by ping class (500 ticks)" {
  let rng = Rng::new(42)
  let results = run_aram_with_latency(500, rng, [(30, 3), (80, 4), (200, 3)])
  let buf = StringBuilder::new()
  buf.write_string(
    "=== Latency Inconsistency Report (500 ticks, 10 players) ===\n",
  )
  buf.write_string(
    "ping   | players | pos_err% | avg_pos_err | hp_err%  | alive_err% | samples\n",
  )
  buf.write_string(
    "-------|---------|----------|-------------|----------|------------|--------\n",
  )
  for st in results {
    let pos_pct = format_pct(st.pos_mismatches, st.samples)
    let avg_err = format_avg(st.total_pos_error, st.pos_mismatches)
    let hp_pct = format_pct(st.hp_mismatches, st.samples)
    let alive_pct = format_pct(st.alive_mismatches, st.samples)
    buf.write_string(
      "\{st.label}  | \{st.player_count}       | \{pos_pct}%   | \{avg_err} units  | \{hp_pct}%  | \{alive_pct}%     | \{st.samples}\n",
    )
  }
  // Also add totals
  let mut t_pos = 0
  let mut t_hp = 0
  let mut t_alive = 0
  let mut t_samples = 0
  let mut t_pos_err = 0
  let mut t_pos_mismatch = 0
  for st in results {
    t_pos += st.pos_mismatches
    t_hp += st.hp_mismatches
    t_alive += st.alive_mismatches
    t_samples += st.samples
    t_pos_err += st.total_pos_error
    t_pos_mismatch += st.pos_mismatches
  }
  buf.write_string(
    "-------|---------|----------|-------------|----------|------------|--------\n",
  )
  buf.write_string(
    "total  | 10      | \{format_pct(t_pos, t_samples)}%   | \{format_avg(t_pos_err, t_pos_mismatch)} units  | \{format_pct(t_hp, t_samples)}%  | \{format_pct(t_alive, t_samples)}%     | \{t_samples}\n",
  )
  println(buf.to_string())
  // Sanity: higher ping should have more inconsistencies
  inspect(
    results[0].pos_mismatches <= results[2].pos_mismatches,
    content="true",
  )
}

///|
/// 200 ticks, uniform low latency (all 30ms) as baseline
test "latency: all 30ms baseline (200 ticks)" {
  let rng = Rng::new(123)
  let results = run_aram_with_latency(200, rng, [(30, 10)])
  let st = results[0]
  let pos_pct = format_pct(st.pos_mismatches, st.samples)
  let avg_err = format_avg(st.total_pos_error, st.pos_mismatches)
  println(
    "Baseline 30ms x10: pos_err=\{pos_pct}% avg_err=\{avg_err} units hp_err=\{format_pct(st.hp_mismatches, st.samples)}% samples=\{st.samples}",
  )
  inspect(st.samples > 0, content="true")
}

///|
/// 200 ticks, uniform high latency (all 200ms) as worst case
test "latency: all 200ms worst case (200 ticks)" {
  let rng = Rng::new(123)
  let results = run_aram_with_latency(200, rng, [(200, 10)])
  let st = results[0]
  let pos_pct = format_pct(st.pos_mismatches, st.samples)
  let avg_err = format_avg(st.total_pos_error, st.pos_mismatches)
  println(
    "Worst 200ms x10: pos_err=\{pos_pct}% avg_err=\{avg_err} units hp_err=\{format_pct(st.hp_mismatches, st.samples)}% samples=\{st.samples}",
  )
  inspect(st.samples > 0, content="true")
}
