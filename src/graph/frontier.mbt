///|
/// Find the Lowest Common Ancestors of two frontier sets.
/// Walk backwards from both frontiers using BFS until we find shared ancestors.
pub fn EventGraph::find_lca(
  self : EventGraph,
  a : Array[@types.EventId],
  b : Array[@types.EventId],
) -> Array[@types.EventId] {
  if a.is_empty() || b.is_empty() {
    return []
  }
  let seen_a : Map[@types.EventId, Bool] = Map::new()
  let seen_b : Map[@types.EventId, Bool] = Map::new()
  let queue_a : Array[@types.EventId] = a.copy()
  let queue_b : Array[@types.EventId] = b.copy()
  let mut head_a = 0
  let mut head_b = 0
  for id in a {
    seen_a[id] = true
  }
  for id in b {
    seen_b[id] = true
  }
  let result : Array[@types.EventId] = []
  let found : Map[@types.EventId, Bool] = Map::new()
  // BFS both sides alternately
  while head_a < queue_a.length() || head_b < queue_b.length() {
    // Process queue_a
    if head_a < queue_a.length() {
      let id = queue_a[head_a]
      head_a += 1
      if seen_b.get(id).unwrap_or(false) && not(found.get(id).unwrap_or(false)) {
        found[id] = true
        result.push(id)
      } else {
        match self.events.get(id) {
          Some(event) =>
            for dep in event.deps {
              if not(seen_a.get(dep).unwrap_or(false)) {
                seen_a[dep] = true
                queue_a.push(dep)
              }
            }
          None => ()
        }
      }
    }
    // Process queue_b
    if head_b < queue_b.length() {
      let id = queue_b[head_b]
      head_b += 1
      if seen_a.get(id).unwrap_or(false) && not(found.get(id).unwrap_or(false)) {
        found[id] = true
        result.push(id)
      } else {
        match self.events.get(id) {
          Some(event) =>
            for dep in event.deps {
              if not(seen_b.get(dep).unwrap_or(false)) {
                seen_b[dep] = true
                queue_b.push(dep)
              }
            }
          None => ()
        }
      }
    }
  }
  result
}

///|
/// Collect all events since a given set of ancestors, sorted by lamport time.
pub fn EventGraph::events_since(
  self : EventGraph,
  since : Array[@types.EventId],
) -> Array[@types.Event] {
  let since_set : Map[@types.EventId, Bool] = Map::new()
  for id in since {
    since_set[id] = true
  }
  let result : Array[@types.Event] = []
  let visited : Map[@types.EventId, Bool] = Map::new()
  // Collect all events reachable from frontier that are after `since`
  let queue : Array[@types.EventId] = self.frontier.copy()
  let mut head = 0
  while head < queue.length() {
    let id = queue[head]
    head += 1
    if visited.get(id).unwrap_or(false) {
      continue
    }
    visited[id] = true
    if since_set.get(id).unwrap_or(false) {
      continue
    }
    match self.events.get(id) {
      Some(event) => {
        result.push(event)
        for dep in event.deps {
          if not(visited.get(dep).unwrap_or(false)) {
            queue.push(dep)
          }
        }
      }
      None => ()
    }
  }
  // Sort by lamport ascending, then peer_id for stability
  result.sort_by(fn(a, b) {
    if a.lamport != b.lamport {
      a.lamport.compare(b.lamport)
    } else {
      a.id.peer.compare(b.id.peer)
    }
  })
  result
}
