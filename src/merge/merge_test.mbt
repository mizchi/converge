///|
test "merge: two peers update different columns - both applied" {
  let g = @graph.EventGraph::new()
  let peer_a = @types.PeerId("a")
  let peer_b = @types.PeerId("b")
  // Common ancestor: insert row
  let root : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="users", row_id="u1", values=[
      ("name", @types.Value::Str("Alice")),
      ("age", @types.Value::Int(25)),
    ]),
  }
  g.add_event(root)
  // Local: update name
  let local_e : @types.Event = {
    id: { peer: peer_a, counter: 1 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="users",
      row_id="u1",
      col="name",
      value=@types.Value::Str("Bob"),
    ),
  }
  g.add_event(local_e)
  let local_frontier = [local_e.id]
  // Remote: update age (concurrent)
  let remote_e : @types.Event = {
    id: { peer: peer_b, counter: 0 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="users",
      row_id="u1",
      col="age",
      value=@types.Value::Int(30),
    ),
  }
  let ops = @merge.merge(g, local_frontier, [remote_e])
  // Remote update on "age" should be applied (different column, no conflict)
  assert_eq(ops.length(), 1)
  assert_eq(
    ops[0],
    @merge.MergeOp::SetCell(
      tbl="users",
      row_id="u1",
      col="age",
      value=@types.Value::Int(30),
    ),
  )
}

///|
test "merge: same column conflict - higher lamport wins" {
  let g = @graph.EventGraph::new()
  let peer_a = @types.PeerId("a")
  let peer_b = @types.PeerId("b")
  let root : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="users", row_id="u1", values=[
      ("name", @types.Value::Str("Alice")),
    ]),
  }
  g.add_event(root)
  // Local: update name with lamport=2
  let local_e : @types.Event = {
    id: { peer: peer_a, counter: 1 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="users",
      row_id="u1",
      col="name",
      value=@types.Value::Str("Bob"),
    ),
  }
  g.add_event(local_e)
  let local_frontier = [local_e.id]
  // Remote: update name with lamport=3 (higher, should win)
  let remote_e : @types.Event = {
    id: { peer: peer_b, counter: 0 },
    deps: [root.id],
    lamport: 3,
    op: @types.RowOp::Update(
      tbl="users",
      row_id="u1",
      col="name",
      value=@types.Value::Str("Charlie"),
    ),
  }
  let ops = @merge.merge(g, local_frontier, [remote_e])
  assert_eq(ops.length(), 1)
  assert_eq(
    ops[0],
    @merge.MergeOp::SetCell(
      tbl="users",
      row_id="u1",
      col="name",
      value=@types.Value::Str("Charlie"),
    ),
  )
}

///|
test "merge: same column same lamport - peer_id tiebreak" {
  let g = @graph.EventGraph::new()
  let peer_a = @types.PeerId("a")
  let peer_b = @types.PeerId("b")
  let root : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="users", row_id="u1", values=[
      ("name", @types.Value::Str("Alice")),
    ]),
  }
  g.add_event(root)
  // Local (peer a): update with lamport=2
  let local_e : @types.Event = {
    id: { peer: peer_a, counter: 1 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="users",
      row_id="u1",
      col="name",
      value=@types.Value::Str("FromA"),
    ),
  }
  g.add_event(local_e)
  let local_frontier = [local_e.id]
  // Remote (peer b): update with same lamport=2
  // peer "b" > "a" lexicographically, so remote should win
  let remote_e : @types.Event = {
    id: { peer: peer_b, counter: 0 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="users",
      row_id="u1",
      col="name",
      value=@types.Value::Str("FromB"),
    ),
  }
  let ops = @merge.merge(g, local_frontier, [remote_e])
  // peer "b" > "a", so remote wins
  assert_eq(ops.length(), 1)
  assert_eq(
    ops[0],
    @merge.MergeOp::SetCell(
      tbl="users",
      row_id="u1",
      col="name",
      value=@types.Value::Str("FromB"),
    ),
  )
}

///|
test "merge: insert + concurrent delete - delete wins" {
  let g = @graph.EventGraph::new()
  let peer_a = @types.PeerId("a")
  let peer_b = @types.PeerId("b")
  let root : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="users", row_id="u1", values=[
      ("name", @types.Value::Str("Alice")),
    ]),
  }
  g.add_event(root)
  // Local: update
  let local_e : @types.Event = {
    id: { peer: peer_a, counter: 1 },
    deps: [root.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="users",
      row_id="u1",
      col="name",
      value=@types.Value::Str("Bob"),
    ),
  }
  g.add_event(local_e)
  let local_frontier = [local_e.id]
  // Remote: delete with higher lamport
  let remote_e : @types.Event = {
    id: { peer: peer_b, counter: 0 },
    deps: [root.id],
    lamport: 3,
    op: @types.RowOp::Delete(tbl="users", row_id="u1"),
  }
  let ops = @merge.merge(g, local_frontier, [remote_e])
  // Delete has higher lamport and targets same (tbl, row_id, "")
  // The update targets (tbl, row_id, "name") - different key, so both should appear
  // But semantically delete should also be there
  let has_delete = ops
    .iter()
    .any(fn(op) { op == @merge.MergeOp::DeleteRow(tbl="users", row_id="u1") })
  assert_true(has_delete)
}

///|
test "merge: no remote events returns empty" {
  let g = @graph.EventGraph::new()
  let ops = @merge.merge(g, [], [])
  assert_eq(ops.length(), 0)
}

///|
test "merge: empty remote_events with non-empty graph returns empty" {
  let g = @graph.EventGraph::new()
  let peer_a = @types.PeerId("a")
  let root : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(1)),
    ]),
  }
  g.add_event(root)
  let ops = @merge.merge(g, [root.id], [])
  assert_eq(ops.length(), 0)
}

///|
test "merge: 3-peer chain sync A->B->C" {
  let g = @graph.EventGraph::new()
  let peer_a = @types.PeerId("a")
  let peer_b = @types.PeerId("b")
  // A inserts
  let e_a : @types.Event = {
    id: { peer: peer_a, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(1)),
    ]),
  }
  g.add_event(e_a)
  // B receives from A and updates
  let e_b : @types.Event = {
    id: { peer: peer_b, counter: 0 },
    deps: [e_a.id],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(2),
    ),
  }
  // C has empty graph, receives A+B chain
  let g_c = @graph.EventGraph::new()
  let ops = @merge.merge(g_c, [], [e_a, e_b])
  // Both should be applied since C has nothing
  let has_insert = ops
    .iter()
    .any(fn(op) {
      op ==
      @merge.MergeOp::SetCell(
        tbl="t",
        row_id="r1",
        col="x",
        value=@types.Value::Int(2),
      )
    })
  let has_insert_row = ops
    .iter()
    .any(fn(op) {
      guard op is @merge.MergeOp::InsertRow(tbl="t", row_id="r1", ..) else {
        false
      }
      true
    })
  // Either InsertRow or SetCell should appear
  assert_true(has_insert || has_insert_row)
}
