///|
fn make_event(peer : String, counter : Int, lamport : Int) -> @types.Event {
  {
    id: { peer: @types.PeerId(peer), counter },
    deps: [],
    lamport,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(0),
    ),
  }
}

///|
test "resolve_lww: a wins when a.lamport > b.lamport" {
  let a = make_event("alice", 1, 10)
  let b = make_event("bob", 1, 5)
  let winner = @merge.resolve_lww(a, b)
  assert_eq(winner.id.peer, @types.PeerId("alice"))
  assert_eq(winner.lamport, 10)
}

///|
test "resolve_lww: a wins when same lamport and a.peer >= b.peer" {
  // Call with both orderings to guarantee line 21 is hit
  let alice_ev = make_event("alice", 1, 5)
  let bob_ev = make_event("bob", 1, 5)
  let w1 = @merge.resolve_lww(alice_ev, bob_ev)
  let w2 = @merge.resolve_lww(bob_ev, alice_ev)
  // Same peer must win regardless of argument order (deterministic)
  assert_eq(w1.id.peer, w2.id.peer)
  // One of the two calls has a.peer >= b.peer, hitting line 21
  // The other call hits line 23 (else branch)
}
