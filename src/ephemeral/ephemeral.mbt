///|
/// An entry in the ephemeral store, representing a single LWW register.
/// Uses timestamp + peer_id for conflict resolution (higher timestamp wins,
/// ties broken by lexicographic peer_id comparison).
pub(all) struct EphemeralEntry {
  value : @types.Value
  timestamp : Double
  peer : @types.PeerId
} derive(Show, Eq)

///|
/// Ephemeral state store using Last-Writer-Wins (LWW) registers.
/// Organized as a two-level map: namespace -> key -> entry.
///
/// Unlike the durable CrdtDoc layer which records every operation in a causal
/// event graph, EphemeralStore is designed for high-frequency, short-lived state
/// (e.g. cursor positions, player coordinates) where only the latest value matters.
/// No history is kept — older values are silently discarded on merge.
pub(all) struct EphemeralStore {
  data : Map[String, Map[String, EphemeralEntry]]
}

///|
/// Create a new empty EphemeralStore.
pub fn EphemeralStore::new() -> EphemeralStore {
  { data: Map::new() }
}

///|
fn EphemeralStore::get_or_create_ns(
  self : EphemeralStore,
  ns : String,
) -> Map[String, EphemeralEntry] {
  match self.data.get(ns) {
    Some(m) => m
    None => {
      let m : Map[String, EphemeralEntry] = Map::new()
      self.data[ns] = m
      m
    }
  }
}

///|
/// Set a value in the store. Creates the namespace if it doesn't exist.
pub fn EphemeralStore::set(
  self : EphemeralStore,
  ns : String,
  key : String,
  value : @types.Value,
  timestamp : Double,
  peer : @types.PeerId,
) -> Unit {
  let ns_map = self.get_or_create_ns(ns)
  ns_map[key] = { value, timestamp, peer }
}

///|
/// Get a single entry by namespace and key.
pub fn EphemeralStore::get(
  self : EphemeralStore,
  ns : String,
  key : String,
) -> EphemeralEntry? {
  match self.data.get(ns) {
    Some(ns_map) => ns_map.get(key)
    None => None
  }
}

///|
/// Get all entries in a namespace. Returns an empty map if the namespace
/// doesn't exist.
pub fn EphemeralStore::get_all(
  self : EphemeralStore,
  ns : String,
) -> Map[String, EphemeralEntry] {
  match self.data.get(ns) {
    Some(ns_map) => ns_map
    None => Map::new()
  }
}

///|
/// Merge a remote entry using LWW semantics.
/// Returns true if the local state was updated (remote wins).
///
/// Resolution rules:
/// 1. Higher timestamp wins
/// 2. On equal timestamps, higher (lexicographic) peer_id wins
pub fn EphemeralStore::merge(
  self : EphemeralStore,
  ns : String,
  key : String,
  remote : EphemeralEntry,
) -> Bool {
  let ns_map = self.get_or_create_ns(ns)
  match ns_map.get(key) {
    None => {
      ns_map[key] = remote
      true
    }
    Some(current) =>
      if remote.timestamp > current.timestamp {
        ns_map[key] = remote
        true
      } else if remote.timestamp == current.timestamp &&
        remote.peer > current.peer {
        ns_map[key] = remote
        true
      } else {
        false
      }
  }
}

///|
/// Remove an entry from the store (e.g. when a player disconnects).
pub fn EphemeralStore::remove(
  self : EphemeralStore,
  ns : String,
  key : String,
) -> Unit {
  match self.data.get(ns) {
    Some(ns_map) => ns_map.remove(key)
    None => ()
  }
}
