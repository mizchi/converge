///|
/// CrdtDoc — the **Durable Layer** of the two-tier architecture.
///
/// Wraps EventGraph + OpLog + LamportClock to provide a high-level API
/// for recording row operations that are durably stored in a causal event
/// graph. Every mutation is captured as an Event with explicit causal
/// dependencies, enabling deterministic conflict resolution via EG-Walker.
///
/// For high-frequency ephemeral state (cursors, presence, etc.), use
/// `EphemeralStore` instead — it bypasses the event graph entirely.
pub(all) struct CrdtDoc {
  peer_id : @types.PeerId
  clock : @clock.LamportClock
  graph : @graph.EventGraph
  oplog : @oplog.OpLog
  mut counter : Int
}

///|
pub fn CrdtDoc::new(peer_id~ : String) -> CrdtDoc {
  {
    peer_id: @types.PeerId(peer_id),
    clock: @clock.LamportClock::new(),
    graph: @graph.EventGraph::new(),
    oplog: @oplog.OpLog::new(),
    counter: 0,
  }
}

///|
/// Create a new event with the given operation, update clock/counter/graph/oplog
fn CrdtDoc::create_event(self : CrdtDoc, op : @types.RowOp) -> @types.Event {
  let lamport = self.clock.tick()
  let counter = self.counter
  self.counter += 1
  let event : @types.Event = {
    id: { peer: self.peer_id, counter },
    deps: self.graph.frontier.copy(),
    lamport,
    op,
  }
  self.graph.add_event(event)
  self.oplog.append(event)
  event
}

///|
/// Record a local insert operation
pub fn CrdtDoc::insert(
  self : CrdtDoc,
  tbl~ : String,
  row_id~ : String,
  values~ : Array[(String, @types.Value)],
) -> @types.Event {
  self.create_event(@types.RowOp::Insert(tbl~, row_id~, values~))
}

///|
/// Record a local update operation
pub fn CrdtDoc::update(
  self : CrdtDoc,
  tbl~ : String,
  row_id~ : String,
  col~ : String,
  value~ : @types.Value,
) -> @types.Event {
  self.create_event(@types.RowOp::Update(tbl~, row_id~, col~, value~))
}

///|
/// Record a local delete operation
pub fn CrdtDoc::delete(
  self : CrdtDoc,
  tbl~ : String,
  row_id~ : String,
) -> @types.Event {
  self.create_event(@types.RowOp::Delete(tbl~, row_id~))
}

///|
/// Merge remote events and return operations to apply to local state
pub fn CrdtDoc::merge_remote(
  self : CrdtDoc,
  remote_runs : Array[@types.EventRun],
) -> Array[@merge.MergeOp] {
  let remote_events = @oplog.expand(remote_runs)
  if remote_events.is_empty() {
    return []
  }
  let local_frontier = self.graph.frontier.copy()
  // Update clock with remote lamport values
  for e in remote_events {
    self.clock.merge(e.lamport)
  }
  let ops = @merge.merge(self.graph, local_frontier, remote_events)
  // Add remote events to oplog
  for e in remote_events {
    self.oplog.append(e)
  }
  ops
}

///|
/// Get pending events for sync (events after known peer versions)
pub fn CrdtDoc::get_pending(
  self : CrdtDoc,
  known : Map[@types.PeerId, Int],
) -> Array[@types.EventRun] {
  self.oplog.events_after(known)
}

///|
/// Get current sync state: (frontier, peer_versions)
pub fn CrdtDoc::sync_state(
  self : CrdtDoc,
) -> (Array[@types.EventId], Map[@types.PeerId, Int]) {
  (self.graph.frontier.copy(), self.oplog.peer_versions)
}
