///|
test "EventGraph: add single event" {
  let g = @graph.EventGraph::new()
  let event : @types.Event = {
    id: { peer: @types.PeerId("a"), counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(1)),
    ]),
  }
  g.add_event(event)
  assert_eq(g.frontier.length(), 1)
  assert_eq(g.frontier[0], event.id)
}

///|
test "EventGraph: linear chain updates frontier" {
  let g = @graph.EventGraph::new()
  let peer = @types.PeerId("a")
  let e0 : @types.Event = {
    id: { peer, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(1)),
    ]),
  }
  let e1 : @types.Event = {
    id: { peer, counter: 1 },
    deps: [{ peer, counter: 0 }],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(2),
    ),
  }
  g.add_event(e0)
  g.add_event(e1)
  assert_eq(g.frontier.length(), 1)
  assert_eq(g.frontier[0], e1.id)
}

///|
test "EventGraph: concurrent events create multi-frontier" {
  let g = @graph.EventGraph::new()
  let root : @types.Event = {
    id: { peer: @types.PeerId("a"), counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(0)),
    ]),
  }
  g.add_event(root)
  // Two concurrent edits from different peers, both depend on root
  let e_a : @types.Event = {
    id: { peer: @types.PeerId("a"), counter: 1 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(1),
    ),
  }
  let e_b : @types.Event = {
    id: { peer: @types.PeerId("b"), counter: 0 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(2),
    ),
  }
  g.add_event(e_a)
  g.add_event(e_b)
  assert_eq(g.frontier.length(), 2)
}

///|
test "EventGraph::find_lca with common ancestor" {
  let g = @graph.EventGraph::new()
  let root : @types.Event = {
    id: { peer: @types.PeerId("a"), counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(0)),
    ]),
  }
  let e_a : @types.Event = {
    id: { peer: @types.PeerId("a"), counter: 1 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(1),
    ),
  }
  let e_b : @types.Event = {
    id: { peer: @types.PeerId("b"), counter: 0 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="y",
      value=@types.Value::Int(2),
    ),
  }
  g.add_event(root)
  g.add_event(e_a)
  g.add_event(e_b)
  let lca = g.find_lca([e_a.id], [e_b.id])
  assert_eq(lca.length(), 1)
  assert_eq(lca[0], root.id)
}

///|
test "EventGraph::events_since collects and sorts" {
  let g = @graph.EventGraph::new()
  let peer_a = @types.PeerId("a")
  let peer_b = @types.PeerId("b")
  let root : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(0)),
    ]),
  }
  let e1 : @types.Event = {
    id: { peer: peer_a, counter: 1 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(1),
    ),
  }
  let e2 : @types.Event = {
    id: { peer: peer_b, counter: 0 },
    deps: [root.id],
    lamport: 3,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="y",
      value=@types.Value::Int(2),
    ),
  }
  g.add_event(root)
  g.add_event(e1)
  g.add_event(e2)
  let since = g.events_since([root.id])
  assert_eq(since.length(), 2)
  // Should be sorted by lamport: e1 (lamport=2) before e2 (lamport=3)
  assert_eq(since[0].id, e1.id)
  assert_eq(since[1].id, e2.id)
}

///|
test "EventGraph::find_lca with multi-ancestor (3 peers)" {
  let g = @graph.EventGraph::new()
  let peer_a = @types.PeerId("a")
  let peer_b = @types.PeerId("b")
  let peer_c = @types.PeerId("c")
  // Root event
  let root : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(0)),
    ]),
  }
  g.add_event(root)
  // Three concurrent branches from root
  let e_a : @types.Event = {
    id: { peer: peer_a, counter: 1 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(1),
    ),
  }
  let e_b : @types.Event = {
    id: { peer: peer_b, counter: 0 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(2),
    ),
  }
  let e_c : @types.Event = {
    id: { peer: peer_c, counter: 0 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(3),
    ),
  }
  g.add_event(e_a)
  g.add_event(e_b)
  g.add_event(e_c)
  // LCA of [e_a, e_b] vs [e_c] should be root
  let lca = g.find_lca([e_a.id, e_b.id], [e_c.id])
  assert_eq(lca.length(), 1)
  assert_eq(lca[0], root.id)
  // Merge event from b+c, then find LCA with a
  let merge_bc : @types.Event = {
    id: { peer: peer_b, counter: 1 },
    deps: [e_b.id, e_c.id],
    lamport: 3,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(4),
    ),
  }
  g.add_event(merge_bc)
  // LCA of [e_a] vs [merge_bc] should be root
  let lca2 = g.find_lca([e_a.id], [merge_bc.id])
  assert_eq(lca2.length(), 1)
  assert_eq(lca2[0], root.id)
}
