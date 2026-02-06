///|
/// Compress a sequence of events into run-length encoded EventRuns.
/// Consecutive events from the same peer with sequential counters
/// and lamport values are merged into a single EventRun.
pub fn compress(events : Array[@types.Event]) -> Array[@types.EventRun] {
  if events.is_empty() {
    return []
  }
  let runs : Array[@types.EventRun] = []
  let first = events[0]
  let mut current_peer = first.id.peer
  let mut current_counter_start = first.id.counter
  let mut current_lamport_start = first.lamport
  let current_deps : Array[@types.EventId] = first.deps.copy()
  let current_ops : Array[@types.RowOp] = [first.op]
  for i in 1..<events.length() {
    let e = events[i]
    let expected_counter = current_counter_start + current_ops.length()
    let expected_lamport = current_lamport_start + current_ops.length()
    if e.id.peer == current_peer &&
      e.id.counter == expected_counter &&
      e.lamport == expected_lamport {
      current_ops.push(e.op)
    } else {
      runs.push({
        peer: current_peer,
        counter_start: current_counter_start,
        lamport_start: current_lamport_start,
        deps: current_deps.copy(),
        ops: current_ops.copy(),
      })
      current_peer = e.id.peer
      current_counter_start = e.id.counter
      current_lamport_start = e.lamport
      current_deps.clear()
      current_deps.append(e.deps)
      current_ops.clear()
      current_ops.push(e.op)
    }
  }
  runs.push({
    peer: current_peer,
    counter_start: current_counter_start,
    lamport_start: current_lamport_start,
    deps: current_deps.copy(),
    ops: current_ops.copy(),
  })
  runs
}

///|
/// Expand EventRuns back into individual Events
pub fn expand(runs : Array[@types.EventRun]) -> Array[@types.Event] {
  let events : Array[@types.Event] = []
  for run in runs {
    for i, op in run.ops {
      let deps : Array[@types.EventId] = if i == 0 {
        run.deps.copy()
      } else {
        [{ peer: run.peer, counter: run.counter_start + i - 1 }]
      }
      events.push({
        id: { peer: run.peer, counter: run.counter_start + i },
        deps,
        lamport: run.lamport_start + i,
        op,
      })
    }
  }
  events
}
