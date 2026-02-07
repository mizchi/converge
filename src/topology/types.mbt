// Topology simulation types

///|
let tick_ms = 16

///|
pub(all) struct PingConfig {
  ping_ms : Int
  count : Int
}

///|
pub(all) struct SimConfig {
  num_peers : Int
  ticks : Int
  ping_config : Array[PingConfig]
  write_interval : Int // write every N ticks (1 = every tick)
  namespaces : Array[String]
}

///|
pub(all) struct GossipConfig {
  base : SimConfig
  fanout : Int
  max_hops : Int
}

///|
pub(all) struct FilteredStarConfig {
  base : SimConfig
  subscriptions : Map[Int, Array[String]]
}

///|
pub(all) struct PartitionConfig {
  base : SimConfig
  partition_at_tick : Int
  reconnect_at_tick : Int
  partitioned_peers : Array[Int]
}

///|
pub(all) struct TickMetrics {
  tick : Int
  total_messages_sent : Int
  inconsistent_pairs : Int
  total_entries : Int
} derive(Show)

///|
pub(all) struct SimResult {
  topology_name : String
  convergence_tick : Int // first tick where all peers agree (-1 if never)
  total_messages : Int
  per_tick : Array[TickMetrics]
} derive(Show)

///|
pub(all) struct SimNode {
  id : String
  peer_id : @types.PeerId
  store : @ephemeral.EphemeralStore
}

///|
pub fn SimNode::new(id : String) -> SimNode {
  {
    id,
    peer_id: @types.PeerId(id),
    store: @ephemeral.EphemeralStore::new(),
  }
}

// Xorshift32 PRNG (re-implemented to avoid priv access to ephemeral's Rng)

///|
pub(all) struct Rng {
  mut state : Int
}

///|
pub fn Rng::new(seed : Int) -> Rng {
  { state: if seed == 0 { 1 } else { seed } }
}

///|
pub fn Rng::next(self : Rng) -> Int {
  let mut x = self.state
  x = x.lxor(x << 13)
  x = x.lxor(x >> 17)
  x = x.lxor(x << 5)
  self.state = x
  if x < 0 { -x } else { x }
}

///|
pub fn Rng::next_bound(self : Rng, bound : Int) -> Int {
  self.next() % bound
}

// One-way network pipe with configurable delay

///|
struct InFlightPacket {
  arrival_tick : Int
  entries : Array[(String, String, @ephemeral.EphemeralEntry)]
}

///|
pub(all) struct NetPipe {
  delay_ticks : Int
  queue : Array[InFlightPacket]
}

///|
pub fn NetPipe::new(ping_ms : Int) -> NetPipe {
  let delay = ping_ms / 2 / tick_ms
  let delay = if ping_ms > 0 && delay == 0 { 1 } else { delay }
  { delay_ticks: delay, queue: [] }
}

///|
/// Enqueue specific entries for delivery after delay
pub fn NetPipe::send_entries(
  self : NetPipe,
  current_tick : Int,
  entries : Array[(String, String, @ephemeral.EphemeralEntry)]
) -> Unit {
  if entries.length() > 0 {
    self.queue.push({
      arrival_tick: current_tick + self.delay_ticks,
      entries,
    })
  }
}

///|
/// Enqueue a full snapshot of specified namespaces
pub fn NetPipe::send_snapshot(
  self : NetPipe,
  current_tick : Int,
  src : @ephemeral.EphemeralStore,
  namespaces : Array[String]
) -> Unit {
  let entries : Array[(String, String, @ephemeral.EphemeralEntry)] = []
  for ns in namespaces {
    let ns_entries = src.get_all(ns)
    for key, entry in ns_entries {
      entries.push((ns, key, entry))
    }
  }
  self.send_entries(current_tick, entries)
}

///|
/// Deliver all arrived packets. Returns number of merges applied.
pub fn NetPipe::receive(
  self : NetPipe,
  current_tick : Int,
  dst : @ephemeral.EphemeralStore
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
  self.queue.clear()
  for p in remaining {
    self.queue.push(p)
  }
  merged
}
