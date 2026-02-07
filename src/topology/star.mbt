// Star Relay topology simulation
//
// Central relay node receives all updates from peers, merges, and
// broadcasts back. Each peer has upload/download pipes with latency.

///|
/// Run a Star Relay simulation.
/// write_ticks: number of ticks during which peers write.
/// drain_ticks: extra ticks with no writes to allow convergence.
/// Returns SimResult with convergence info and message counts.
pub fn run_star(config : SimConfig, seed : Int) -> SimResult {
  let rng = Rng::new(seed)
  let ns = config.namespaces
  let n = config.num_peers
  let total_ticks = config.ticks
  // Create peer nodes
  let nodes : Array[SimNode] = []
  for i in 0..<n {
    nodes.push(SimNode::new("p\{i}"))
  }
  // Central relay store
  let relay = @ephemeral.EphemeralStore::new()
  // Build upload/download pipes with per-peer latency
  let upload_pipes : Array[NetPipe] = []
  let download_pipes : Array[NetPipe] = []
  for pc in config.ping_config {
    for _j in 0..<pc.count {
      upload_pipes.push(NetPipe::new(pc.ping_ms))
      download_pipes.push(NetPipe::new(pc.ping_ms))
    }
  }
  // Ensure we have pipes for all peers
  while upload_pipes.length() < n {
    upload_pipes.push(NetPipe::new(50))
    download_pipes.push(NetPipe::new(50))
  }
  let per_tick : Array[TickMetrics] = []
  let mut total_messages = 0
  let mut convergence_tick = -1
  // Determine write phase: first half writes, second half drains
  let write_ticks = total_ticks / 2
  for tick in 0..<total_ticks {
    let mut tick_messages = 0
    // 1. Peers write local data only during write phase
    if tick < write_ticks && tick % config.write_interval == 0 {
      for i in 0..<n {
        let node = nodes[i]
        let ts = tick.to_double()
        for nsi in ns {
          let val = rng.next_bound(1000)
          node.store.set(nsi, node.id, @types.Value::Int(val), ts, node.peer_id)
        }
      }
    }
    // 2. Upload: each peer -> relay (via pipe)
    for i in 0..<n {
      upload_pipes[i].send_snapshot(tick, nodes[i].store, ns)
      tick_messages += 1
    }
    // 3. Deliver uploads to relay
    for i in 0..<n {
      ignore(upload_pipes[i].receive(tick, relay))
    }
    // 4. Download: relay -> each peer (via pipe)
    for i in 0..<n {
      download_pipes[i].send_snapshot(tick, relay, ns)
      tick_messages += 1
    }
    // 5. Deliver downloads to peers
    for i in 0..<n {
      ignore(download_pipes[i].receive(tick, nodes[i].store))
    }
    total_messages += tick_messages
    // 6. Measure inconsistency
    let inconsistent = count_inconsistent_pairs(nodes, ns)
    let entries = count_total_entries(nodes, ns)
    per_tick.push({
      tick,
      total_messages_sent: tick_messages,
      inconsistent_pairs: inconsistent,
      total_entries: entries,
    })
    // Track first convergence after write phase
    if inconsistent == 0 && convergence_tick == -1 && tick >= write_ticks {
      convergence_tick = tick
    }
  }
  { topology_name: "star", convergence_tick, total_messages, per_tick }
}
