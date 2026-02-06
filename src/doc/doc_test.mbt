///|
test "CrdtDoc: basic insert" {
  let doc = @doc.CrdtDoc::new(peer_id="alice")
  let event = doc.insert(tbl="todos", row_id="t1", values=[
    ("text", @types.Value::Str("Buy milk")),
  ])
  assert_eq(event.id.peer, @types.PeerId("alice"))
  assert_eq(event.id.counter, 0)
  assert_eq(event.lamport, 1)
  assert_eq(doc.graph.frontier.length(), 1)
  assert_eq(doc.graph.frontier[0], event.id)
}

///|
test "CrdtDoc: sequential operations" {
  let doc = @doc.CrdtDoc::new(peer_id="alice")
  ignore(
    doc.insert(tbl="todos", row_id="t1", values=[
      ("text", @types.Value::Str("Buy milk")),
    ]),
  )
  let e2 = doc.update(
    tbl="todos",
    row_id="t1",
    col="text",
    value=@types.Value::Str("Buy eggs"),
  )
  assert_eq(e2.id.counter, 1)
  assert_eq(e2.lamport, 2)
  assert_eq(doc.graph.frontier.length(), 1)
  assert_eq(doc.graph.frontier[0], e2.id)
  assert_eq(doc.oplog.runs.length(), 1) // RLE merged
  assert_eq(doc.oplog.runs[0].ops.length(), 2)
}

///|
test "CrdtDoc: two-peer sync scenario" {
  // Alice creates a doc and inserts a row
  let alice = @doc.CrdtDoc::new(peer_id="alice")
  ignore(
    alice.insert(tbl="todos", row_id="t1", values=[
      ("text", @types.Value::Str("Buy milk")),
      ("done", @types.Value::Bool(false)),
    ]),
  )

  // Bob creates his own doc
  let bob = @doc.CrdtDoc::new(peer_id="bob")

  // Alice sends her events to Bob
  let alice_pending = alice.get_pending(Map::new())
  let bob_ops = bob.merge_remote(alice_pending)
  // Bob should get an InsertRow operation
  assert_eq(bob_ops.length(), 1)
  guard bob_ops[0] is @merge.MergeOp::InsertRow(..) else {
    fail("expected InsertRow")
  }

  // Now both make concurrent edits
  // Alice updates "text"
  ignore(
    alice.update(
      tbl="todos",
      row_id="t1",
      col="text",
      value=@types.Value::Str("Buy eggs"),
    ),
  )
  // Bob updates "done"
  ignore(
    bob.update(
      tbl="todos",
      row_id="t1",
      col="done",
      value=@types.Value::Bool(true),
    ),
  )

  // Sync: Alice -> Bob
  let (_, alice_versions) = alice.sync_state()
  let (_, bob_versions) = bob.sync_state()
  let alice_new = alice.get_pending(bob_versions)
  let bob_new = bob.get_pending(alice_versions)
  let bob_merge_ops = bob.merge_remote(alice_new)
  let alice_merge_ops = alice.merge_remote(bob_new)

  // Bob should see Alice's text update
  let bob_has_text = bob_merge_ops
    .iter()
    .any(fn(op) {
      op ==
      @merge.MergeOp::SetCell(
        tbl="todos",
        row_id="t1",
        col="text",
        value=@types.Value::Str("Buy eggs"),
      )
    })
  assert_true(bob_has_text)

  // Alice should see Bob's done update
  let alice_has_done = alice_merge_ops
    .iter()
    .any(fn(op) {
      op ==
      @merge.MergeOp::SetCell(
        tbl="todos",
        row_id="t1",
        col="done",
        value=@types.Value::Bool(true),
      )
    })
  assert_true(alice_has_done)
}

///|
test "CrdtDoc: conflict resolution with LWW" {
  let alice = @doc.CrdtDoc::new(peer_id="alice")
  let bob = @doc.CrdtDoc::new(peer_id="bob")

  // Initial state: Alice inserts, sends to Bob
  ignore(
    alice.insert(tbl="t", row_id="r1", values=[("x", @types.Value::Int(0))]),
  )
  let initial = alice.get_pending(Map::new())
  ignore(bob.merge_remote(initial))

  // Both update "x" concurrently
  // Alice does 2 updates (higher lamport)
  ignore(
    alice.update(tbl="t", row_id="r1", col="x", value=@types.Value::Int(10)),
  )
  ignore(
    alice.update(tbl="t", row_id="r1", col="x", value=@types.Value::Int(20)),
  )
  // Bob does 1 update (lower lamport)
  ignore(bob.update(tbl="t", row_id="r1", col="x", value=@types.Value::Int(99)))

  // Sync Bob -> Alice
  let (_, alice_versions) = alice.sync_state()
  let bob_new = bob.get_pending(alice_versions)
  let alice_ops = alice.merge_remote(bob_new)
  // Alice's lamport is higher (3), Bob's is 2, so Alice should win
  // No remote ops should be applied (Alice's value takes precedence)
  assert_eq(alice_ops.length(), 0)
}

///|
test "CrdtDoc: delete operation" {
  let doc = @doc.CrdtDoc::new(peer_id="alice")
  ignore(
    doc.insert(tbl="todos", row_id="t1", values=[
      ("text", @types.Value::Str("test")),
    ]),
  )
  let del = doc.delete(tbl="todos", row_id="t1")
  assert_eq(del.lamport, 2)
  assert_eq(doc.graph.frontier.length(), 1)
  assert_eq(doc.graph.frontier[0], del.id)
}

///|
test "CrdtDoc: counter stays correct after remote merge" {
  let alice = @doc.CrdtDoc::new(peer_id="alice")
  let bob = @doc.CrdtDoc::new(peer_id="bob")
  // Alice inserts (counter=0, lamport=1)
  let e1 = alice.insert(tbl="t", row_id="r1", values=[
    ("x", @types.Value::Int(1)),
  ])
  assert_eq(e1.id.counter, 0)
  assert_eq(e1.lamport, 1)
  // Bob does some operations to advance his lamport
  ignore(bob.insert(tbl="t", row_id="r2", values=[("y", @types.Value::Int(2))]))
  ignore(bob.update(tbl="t", row_id="r2", col="y", value=@types.Value::Int(3)))
  ignore(bob.update(tbl="t", row_id="r2", col="y", value=@types.Value::Int(4)))
  // Bob's lamport is now 3, Alice merges Bob's events
  let bob_pending = bob.get_pending(Map::new())
  ignore(alice.merge_remote(bob_pending))
  // Alice's lamport should have advanced via merge, but counter should still be 1
  let e2 = alice.insert(tbl="t", row_id="r3", values=[
    ("z", @types.Value::Int(5)),
  ])
  assert_eq(e2.id.counter, 1) // counter increments independently
  assert_true(e2.lamport > e1.lamport) // lamport should be higher than before
}

///|
test "CrdtDoc: concurrent delete and insert symmetry" {
  let alice = @doc.CrdtDoc::new(peer_id="alice")
  let bob = @doc.CrdtDoc::new(peer_id="bob")
  // Both start with same row
  ignore(
    alice.insert(tbl="t", row_id="r1", values=[("x", @types.Value::Int(1))]),
  )
  let initial = alice.get_pending(Map::new())
  ignore(bob.merge_remote(initial))
  // Alice deletes, Bob inserts new row concurrently
  ignore(alice.delete(tbl="t", row_id="r1"))
  ignore(bob.insert(tbl="t", row_id="r2", values=[("y", @types.Value::Int(2))]))
  // Sync both ways
  let (_, alice_v) = alice.sync_state()
  let (_, bob_v) = bob.sync_state()
  let alice_new = alice.get_pending(bob_v)
  let bob_new = bob.get_pending(alice_v)
  let bob_ops = bob.merge_remote(alice_new)
  let alice_ops = alice.merge_remote(bob_new)
  // Bob should see Alice's delete
  let bob_has_delete = bob_ops
    .iter()
    .any(fn(op) { op == @merge.MergeOp::DeleteRow(tbl="t", row_id="r1") })
  assert_true(bob_has_delete)
  // Alice should see Bob's insert
  let alice_has_insert = alice_ops
    .iter()
    .any(fn(op) {
      guard op is @merge.MergeOp::InsertRow(tbl="t", row_id="r2", ..) else {
        false
      }
      true
    })
  assert_true(alice_has_insert)
}
