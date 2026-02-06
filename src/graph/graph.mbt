///|
/// EventGraph: DAG of causal events with frontier tracking
pub(all) struct EventGraph {
  events : Map[@types.EventId, @types.Event]
  frontier : Array[@types.EventId]
  frontier_set : Map[@types.EventId, Unit]
}

///|
pub fn EventGraph::new() -> EventGraph {
  { events: Map::new(), frontier: [], frontier_set: Map::new() }
}

///|
/// Add an event to the graph and update the frontier
pub fn EventGraph::add_event(self : EventGraph, event : @types.Event) -> Unit {
  self.events[event.id] = event
  self.update_frontier(event)
}

///|
/// Update frontier after adding an event.
/// Remove deps from frontier, add the new event's id.
fn EventGraph::update_frontier(self : EventGraph, event : @types.Event) -> Unit {
  for dep in event.deps {
    if not(self.frontier_set.get(dep) is None) {
      self.frontier_set.remove(dep)
      let idx = frontier_index_of(self.frontier, dep)
      if idx >= 0 {
        ignore(self.frontier.remove(idx))
      }
    }
  }
  if self.frontier_set.get(event.id) is None {
    self.frontier.push(event.id)
    self.frontier_set[event.id] = ()
  }
}

///|
fn frontier_index_of(
  frontier : Array[@types.EventId],
  id : @types.EventId,
) -> Int {
  for i, f in frontier {
    if f == id {
      return i
    }
  }
  -1
}
