///|
/// Single peer: 1000 sequential inserts
test "bench: CrdtDoc 1000 inserts" (b : @bench.T) {
  b.bench(fn() {
    let doc = CrdtDoc::new(peer_id="alice")
    for i in 0..<1000 {
      ignore(
        doc.insert(tbl="t", row_id="r\{i}", values=[("x", @types.Value::Int(i))]),
      )
    }
    b.keep(doc)
  })
}

///|
/// Single peer: 1000 sequential updates on same row
test "bench: CrdtDoc 1000 updates same row" (b : @bench.T) {
  b.bench(fn() {
    let doc = CrdtDoc::new(peer_id="alice")
    ignore(
      doc.insert(tbl="t", row_id="r1", values=[("x", @types.Value::Int(0))]),
    )
    for i in 1..<1000 {
      ignore(
        doc.update(tbl="t", row_id="r1", col="x", value=@types.Value::Int(i)),
      )
    }
    b.keep(doc)
  })
}

///|
/// Two-peer sync: alice generates 500 events, bob merges them
test "bench: two-peer merge 500" (b : @bench.T) {
  let alice = CrdtDoc::new(peer_id="alice")
  ignore(
    alice.insert(tbl="t", row_id="r1", values=[("x", @types.Value::Int(0))]),
  )
  for i in 1..<500 {
    ignore(
      alice.update(tbl="t", row_id="r1", col="x", value=@types.Value::Int(i)),
    )
  }
  let known : Map[@types.PeerId, Int] = Map::new()
  let alice_runs = alice.get_pending(known)
  b.bench(fn() {
    let bob = CrdtDoc::new(peer_id="bob")
    let ops = bob.merge_remote(alice_runs)
    b.keep(ops)
  })
}

///|
/// Two-peer concurrent edits on different columns, then merge
test "bench: concurrent column edits merge 100" (b : @bench.T) {
  let alice = CrdtDoc::new(peer_id="alice")
  ignore(
    alice.insert(tbl="t", row_id="r1", values=[
      ("a", @types.Value::Int(0)),
      ("b", @types.Value::Int(0)),
    ]),
  )
  let empty : Map[@types.PeerId, Int] = Map::new()
  let initial_runs = alice.get_pending(empty)
  for i in 1..<=100 {
    ignore(
      alice.update(tbl="t", row_id="r1", col="a", value=@types.Value::Int(i)),
    )
  }
  let known_alice : Map[@types.PeerId, Int] = Map::new()
  known_alice[@types.PeerId("alice")] = 0
  let alice_after = alice.get_pending(known_alice)
  b.bench(fn() {
    let bob = CrdtDoc::new(peer_id="bob")
    ignore(bob.merge_remote(initial_runs))
    for i in 1..<=100 {
      ignore(
        bob.update(tbl="t", row_id="r1", col="b", value=@types.Value::Int(i)),
      )
    }
    let ops = bob.merge_remote(alice_after)
    b.keep(ops)
  })
}

///|
/// get_pending with partial knowledge
test "bench: get_pending partial sync" (b : @bench.T) {
  let doc = CrdtDoc::new(peer_id="alice")
  for i in 0..<1000 {
    ignore(
      doc.insert(tbl="t", row_id="r\{i}", values=[("x", @types.Value::Int(i))]),
    )
  }
  let known : Map[@types.PeerId, Int] = Map::new()
  known[@types.PeerId("alice")] = 500
  b.bench(fn() { b.keep(doc.get_pending(known)) })
}
