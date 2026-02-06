///|
/// Merge result: operations to apply to local state
pub(all) enum MergeOp {
  SetCell(tbl~ : String, row_id~ : String, col~ : String, value~ : @types.Value)
  InsertRow(
    tbl~ : String,
    row_id~ : String,
    values~ : Array[(String, @types.Value)]
  )
  DeleteRow(tbl~ : String, row_id~ : String)
} derive(Show, Eq)

///|
/// EG-Walker style merge.
/// 1. Add remote events to graph
/// 2. Find LCA between local frontier and remote events' frontier
/// 3. Collect all events since LCA, sort by lamport
/// 4. Detect concurrent ops on same (tbl, row_id, col)
/// 5. Resolve with LWW
/// 6. Return MergeOp list
pub fn merge(
  graph : @graph.EventGraph,
  local_frontier : Array[@types.EventId],
  remote_events : Array[@types.Event],
) -> Array[MergeOp] {
  if remote_events.is_empty() {
    return []
  }
  // Build remote frontier: collect all deps, then events not depended on are frontier
  let remote_ids : Map[@types.EventId, Bool] = Map::new()
  let all_deps : Map[@types.EventId, Unit] = Map::new()
  for e in remote_events {
    remote_ids[e.id] = true
    for dep in e.deps {
      all_deps[dep] = ()
    }
  }
  for e in remote_events {
    graph.add_event(e)
  }
  let remote_frontier : Array[@types.EventId] = []
  for e in remote_events {
    if all_deps.get(e.id) is None {
      remote_frontier.push(e.id)
    }
  }
  // Find LCA
  let lca = graph.find_lca(local_frontier, remote_frontier)
  // Collect events since LCA (sorted by lamport)
  let since_events = if lca.is_empty() {
    // No common ancestor: all events in graph
    graph.events_since([])
  } else {
    graph.events_since(lca)
  }
  // Build a set of local event IDs (not from remote)
  let local_event_ids : Map[@types.EventId, Bool] = Map::new()
  for e in since_events {
    if not(remote_ids.get(e.id).unwrap_or(false)) {
      local_event_ids[e.id] = true
    }
  }
  // Detect conflicts: group by (tbl, row_id, col)
  let winners : Map[ConflictKey, @types.Event] = Map::new()
  for e in since_events {
    let (tbl, row_id, col) = op_key(e.op)
    let key : ConflictKey = { tbl, row_id, col }
    match winners.get(key) {
      Some(existing) => {
        let winner = resolve_lww(existing, e)
        winners[key] = winner
      }
      None => winners[key] = e
    }
  }
  // Generate MergeOps from winner events that are remote
  // (local events are already applied, so only produce ops for remote winners)
  let ops : Array[MergeOp] = []
  for _key, winner in winners {
    // Only emit ops for events that came from remote
    if remote_ids.get(winner.id).unwrap_or(false) {
      match winner.op {
        Insert(tbl~, row_id~, values~) =>
          ops.push(InsertRow(tbl~, row_id~, values~))
        Update(tbl~, row_id~, col~, value~) =>
          ops.push(SetCell(tbl~, row_id~, col~, value~))
        Delete(tbl~, row_id~) => ops.push(DeleteRow(tbl~, row_id~))
      }
    }
  }
  ops
}
