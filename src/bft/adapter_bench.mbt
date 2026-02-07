///|
/// Sign 1000 events with FnvHasher + MockSigner.
test "bench: BFTAdapter sign 1000 events" (b : @bench.T) {
  let events : Array[@types.Event] = []
  for i in 0..<1000 {
    events.push({
      id: { peer: @types.PeerId("alice"), counter: i },
      deps: [],
      lamport: i + 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r" + i.to_string(), values=[
        ("x", @types.Value::Int(i)),
      ]),
    })
  }
  b.bench(fn() {
    let adapter = BFTAdapter::new(FnvHasher::new(), MockVerifier::new())
    let signer = MockSigner::new("alice")
    for i in 0..<1000 {
      let signed = adapter.sign(signer, events[i], [])
      b.keep(signed)
    }
  })
}

///|
/// Deliver 1000 signed events in a linear dependency chain.
test "bench: BFTAdapter deliver 1000 events (linear)" (b : @bench.T) {
  let src_adapter = BFTAdapter::new(FnvHasher::new(), MockVerifier::new())
  let signer = MockSigner::new("alice")
  let signed_events : Array[SignedEvent] = []
  for i in 0..<1000 {
    let deps : Array[@types.EventId] = if i == 0 {
      []
    } else {
      [{ peer: @types.PeerId("alice"), counter: i - 1 }]
    }
    let dep_hashes : Array[Digest] = if i == 0 {
      []
    } else {
      [signed_events[i - 1].digest]
    }
    let event : @types.Event = {
      id: { peer: @types.PeerId("alice"), counter: i },
      deps,
      lamport: i + 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r" + i.to_string(), values=[
        ("x", @types.Value::Int(i)),
      ]),
    }
    let signed = src_adapter.sign(signer, event, dep_hashes)
    signed_events.push(signed)
  }
  b.bench(fn() {
    let adapter = BFTAdapter::new(FnvHasher::new(), MockVerifier::new())
    for i in 0..<1000 {
      let result = adapter.deliver(signed_events[i])
      b.keep(result)
    }
  })
}

///|
/// Deliver 1000 independent signed events (no dependencies).
test "bench: BFTAdapter deliver 1000 events (no deps)" (b : @bench.T) {
  let src_adapter = BFTAdapter::new(FnvHasher::new(), MockVerifier::new())
  let signer = MockSigner::new("alice")
  let signed_events : Array[SignedEvent] = []
  for i in 0..<1000 {
    let event : @types.Event = {
      id: { peer: @types.PeerId("alice"), counter: i },
      deps: [],
      lamport: i + 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r" + i.to_string(), values=[
        ("x", @types.Value::Int(i)),
      ]),
    }
    let signed = src_adapter.sign(signer, event, [])
    signed_events.push(signed)
  }
  b.bench(fn() {
    let adapter = BFTAdapter::new(FnvHasher::new(), MockVerifier::new())
    for i in 0..<1000 {
      let result = adapter.deliver(signed_events[i])
      b.keep(result)
    }
  })
}

///|
/// Deliver 100 events in reverse order (all buffered), then deliver root to flush.
test "bench: BFTAdapter causal flush 100 buffered" (b : @bench.T) {
  let src_adapter = BFTAdapter::new(FnvHasher::new(), MockVerifier::new())
  let signer = MockSigner::new("alice")
  let signed_events : Array[SignedEvent] = []
  for i in 0..<101 {
    let deps : Array[@types.EventId] = if i == 0 {
      []
    } else {
      [{ peer: @types.PeerId("alice"), counter: i - 1 }]
    }
    let dep_hashes : Array[Digest] = if i == 0 {
      []
    } else {
      [signed_events[i - 1].digest]
    }
    let event : @types.Event = {
      id: { peer: @types.PeerId("alice"), counter: i },
      deps,
      lamport: i + 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r" + i.to_string(), values=[
        ("x", @types.Value::Int(i)),
      ]),
    }
    let signed = src_adapter.sign(signer, event, dep_hashes)
    signed_events.push(signed)
  }
  b.bench(fn() {
    let adapter = BFTAdapter::new(FnvHasher::new(), MockVerifier::new())
    // Deliver events 1..100 in reverse order — all will be buffered
    for j in 0..<100 {
      let idx = 100 - j
      ignore(adapter.deliver(signed_events[idx]))
    }
    // Deliver root event (index 0) — triggers flush of all 100 buffered events
    let result = adapter.deliver(signed_events[0])
    b.keep(result)
    b.keep(adapter.take_flushed())
  })
}
