///|
/// OpLog: event accumulator with RLE compression
pub(all) struct OpLog {
  runs : Array[@types.EventRun]
  peer_versions : Map[@types.PeerId, Int]
}

///|
pub fn OpLog::new() -> OpLog {
  { runs: [], peer_versions: {} }
}

///|
/// Append an event, merging into the last run if possible
pub fn OpLog::append(self : OpLog, event : @types.Event) -> Unit {
  let peer = event.id.peer
  self.peer_versions[peer] = event.id.counter
  if self.runs.is_empty() {
    self.runs.push({
      peer: event.id.peer,
      counter_start: event.id.counter,
      lamport_start: event.lamport,
      deps: event.deps.copy(),
      ops: [event.op],
    })
    return
  }
  let last = self.runs[self.runs.length() - 1]
  let expected_counter = last.counter_start + last.ops.length()
  let expected_lamport = last.lamport_start + last.ops.length()
  if last.peer == event.id.peer &&
    event.id.counter == expected_counter &&
    event.lamport == expected_lamport {
    last.ops.push(event.op)
  } else {
    self.runs.push({
      peer: event.id.peer,
      counter_start: event.id.counter,
      lamport_start: event.lamport,
      deps: event.deps.copy(),
      ops: [event.op],
    })
  }
}

///|
/// Get events after known peer versions (for sync)
pub fn OpLog::events_after(
  self : OpLog,
  known : Map[@types.PeerId, Int],
) -> Array[@types.EventRun] {
  let result : Array[@types.EventRun] = []
  for run in self.runs {
    let peer = run.peer
    let known_counter = known.get(peer).unwrap_or(-1)
    let run_end = run.counter_start + run.ops.length() - 1
    if run_end <= known_counter {
      continue
    }
    if run.counter_start > known_counter {
      result.push(run)
    } else {
      let skip = known_counter - run.counter_start + 1
      let new_ops = run.ops[skip:].to_array()
      let new_deps : Array[@types.EventId] = [
        { peer: run.peer, counter: known_counter },
      ]
      result.push({
        peer: run.peer,
        counter_start: run.counter_start + skip,
        lamport_start: run.lamport_start + skip,
        deps: new_deps,
        ops: new_ops,
      })
    }
  }
  result
}
