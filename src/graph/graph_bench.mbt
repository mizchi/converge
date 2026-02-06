///|
/// Add 1000 linear events to EventGraph
test "bench: EventGraph add 1000 linear events" (b : @bench.T) {
  let peer = @types.PeerId("a")
  let events : Array[@types.Event] = []
  for i in 0..<1000 {
    events.push({
      id: { peer, counter: i },
      deps: if i == 0 {
        []
      } else {
        [{ peer, counter: i - 1 }]
      },
      lamport: i + 1,
      op: @types.RowOp::Update(
        tbl="t",
        row_id="r1",
        col="x",
        value=@types.Value::Int(i),
      ),
    })
  }
  b.bench(fn() {
    let g = EventGraph::new()
    for e in events {
      g.add_event(e)
    }
    b.keep(g)
  })
}

///|
/// find_lca with diverged history (100 events each branch)
test "bench: find_lca 100+100 diverged" (b : @bench.T) {
  let g = EventGraph::new()
  let peer_a = @types.PeerId("a")
  let peer_b = @types.PeerId("b")
  // Common root
  let root : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(0)),
    ]),
  }
  g.add_event(root)
  // Branch A: 100 events
  for i in 1..<=100 {
    g.add_event({
      id: { peer: peer_a, counter: i },
      deps: [{ peer: peer_a, counter: i - 1 }],
      lamport: i + 1,
      op: @types.RowOp::Update(
        tbl="t",
        row_id="r1",
        col="x",
        value=@types.Value::Int(i),
      ),
    })
  }
  // Branch B: 100 events
  for i in 0..<100 {
    g.add_event({
      id: { peer: peer_b, counter: i },
      deps: if i == 0 {
        [root.id]
      } else {
        [{ peer: peer_b, counter: i - 1 }]
      },
      lamport: i + 2,
      op: @types.RowOp::Update(
        tbl="t",
        row_id="r1",
        col="y",
        value=@types.Value::Int(i),
      ),
    })
  }
  let frontier_a : Array[@types.EventId] = [{ peer: peer_a, counter: 100 }]
  let frontier_b : Array[@types.EventId] = [{ peer: peer_b, counter: 99 }]
  b.bench(fn() { b.keep(g.find_lca(frontier_a, frontier_b)) })
}

///|
/// events_since from root with 500 events
test "bench: events_since 500 events" (b : @bench.T) {
  let g = EventGraph::new()
  let peer = @types.PeerId("a")
  for i in 0..<500 {
    g.add_event({
      id: { peer, counter: i },
      deps: if i == 0 {
        []
      } else {
        [{ peer, counter: i - 1 }]
      },
      lamport: i + 1,
      op: @types.RowOp::Update(
        tbl="t",
        row_id="r1",
        col="x",
        value=@types.Value::Int(i),
      ),
    })
  }
  let since : Array[@types.EventId] = [{ peer, counter: 0 }]
  b.bench(fn() { b.keep(g.events_since(since)) })
}
