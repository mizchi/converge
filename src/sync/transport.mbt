///|
/// Backend transport trait for sync
pub(open) trait SyncTransport {
  push(Self, PushRequest) -> Unit raise
  pull(Self, PullRequest) -> PullResponse raise
}

///|
/// In-memory transport for testing
pub(all) struct InMemoryTransport {
  events : Array[@types.Event]
  frontier : Array[@types.EventId]
  peer_versions : Map[@types.PeerId, Int]
}

///|
pub fn InMemoryTransport::new() -> InMemoryTransport {
  { events: [], frontier: [], peer_versions: Map::new() }
}

///|
pub impl SyncTransport for InMemoryTransport with push(self, req : PushRequest) -> Unit raise {
  let expanded = @oplog.expand(req.events)
  for e in expanded {
    // Check if already stored
    let known = self.peer_versions.get(e.id.peer).unwrap_or(-1)
    if e.id.counter > known {
      self.events.push(e)
      self.peer_versions[e.id.peer] = e.id.counter
    }
  }
  // Update server frontier
  self.frontier.clear()
  self.frontier.append(req.frontier)
}

///|
pub impl SyncTransport for InMemoryTransport with pull(self, req : PullRequest) -> PullResponse raise {
  let result : Array[@types.Event] = []
  for e in self.events {
    let known = req.known_peers.get(e.id.peer).unwrap_or(-1)
    if e.id.counter > known {
      result.push(e)
    }
  }
  // Sort by lamport for deterministic order
  result.sort_by(fn(a, b) { a.lamport.compare(b.lamport) })
  let runs = @oplog.compress(result)
  { events: runs, server_frontier: self.frontier.copy(), has_more: false }
}
