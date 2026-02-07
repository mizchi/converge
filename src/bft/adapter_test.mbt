///|
/// Helper: create a test event with given peer, counter, and lamport.
fn make_event(
  peer : String,
  counter : Int,
  lamport : Int,
  deps : Array[@types.EventId],
) -> @types.Event {
  {
    id: { peer: @types.PeerId(peer), counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(tbl="t", row_id="r" + counter.to_string(), values=[
      ("x", @types.Value::Int(counter)),
    ]),
  }
}

///|
/// Helper: create and sign an event using the BFTAdapter.
fn sign_event(
  adapter : BFTAdapter,
  signer : MockSigner,
  event : @types.Event,
  dep_hashes : Array[Digest],
) -> SignedEvent {
  adapter.sign(signer, event, dep_hashes)
}

///|
/// Helper: create a fresh adapter with default mock crypto.
fn make_adapter() -> BFTAdapter {
  let hasher = FnvHasher::new()
  let verifier = MockVerifier::new()
  BFTAdapter::new(hasher, verifier)
}

///|
test "happy path: sign and deliver" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  let event = make_event("alice", 0, 1, [])
  let signed = sign_event(adapter, signer_a, event, [])
  let result = adapter.deliver(signed)
  match result {
    Accepted(e) => assert_eq(e.id.counter, 0)
    _ => panic()
  }
}

///|
test "hash tamper: modified event content" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  let event = make_event("alice", 0, 1, [])
  let signed = sign_event(adapter, signer_a, event, [])
  // Tamper: change event op but keep same digest and signature
  let tampered_event : @types.Event = {
    id: event.id,
    deps: event.deps,
    lamport: event.lamport,
    op: @types.RowOp::Insert(tbl="t", row_id="r0", values=[
      ("x", @types.Value::Int(999)),
    ]),
  }
  let tampered : SignedEvent = {
    digest: signed.digest,
    signature: signed.signature,
    author_key: signed.author_key,
    dep_hashes: signed.dep_hashes,
    event: tampered_event,
  }
  let result = adapter.deliver(tampered)
  match result {
    Rejected(alert) => assert_eq(alert.kind, HashMismatch)
    _ => panic()
  }
}

///|
test "equivocation: same (peer, counter) different content" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  // First event
  let event1 : @types.Event = {
    id: { peer: @types.PeerId("alice"), counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(1)),
    ]),
  }
  let signed1 = sign_event(adapter, signer_a, event1, [])
  let result1 = adapter.deliver(signed1)
  match result1 {
    Accepted(_) => ()
    _ => panic()
  }
  // Second event with same (peer, counter=0) but different content
  let event2 : @types.Event = {
    id: { peer: @types.PeerId("alice"), counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r2", values=[
      ("x", @types.Value::Int(2)),
    ]),
  }
  let signed2 = sign_event(adapter, signer_a, event2, [])
  let result2 = adapter.deliver(signed2)
  match result2 {
    Rejected(alert) => assert_eq(alert.kind, Equivocation)
    _ => panic()
  }
}

///|
test "causal delivery: buffer then flush" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  // event0: no deps
  let event0 = make_event("alice", 0, 1, [])
  let signed0 = sign_event(adapter, signer_a, event0, [])
  // event1: depends on event0
  let event1 : @types.Event = {
    id: { peer: @types.PeerId("alice"), counter: 1 },
    deps: [{ peer: @types.PeerId("alice"), counter: 0 }],
    lamport: 2,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(1)),
    ]),
  }
  let signed1 = sign_event(adapter, signer_a, event1, [signed0.digest])
  // Deliver event1 first (before event0) → should be buffered
  let result1 = adapter.deliver(signed1)
  match result1 {
    Buffered => ()
    _ => panic()
  }
  // Now deliver event0 → should accept event0 and flush event1
  let result0 = adapter.deliver(signed0)
  match result0 {
    Accepted(e) => assert_eq(e.id.counter, 0)
    _ => panic()
  }
  // Check that the flushed events contain event1
  let flushed = adapter.take_flushed()
  assert_eq(flushed.length(), 1)
  assert_eq(flushed[0].id.counter, 1)
}

///|
test "invalid signature: wrong author key" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  let event = make_event("alice", 0, 1, [])
  let signed = sign_event(adapter, signer_a, event, [])
  // Replace author_key with bob's key (signature won't match)
  let forged : SignedEvent = {
    digest: signed.digest,
    signature: signed.signature,
    author_key: PublicKey("bob"),
    dep_hashes: signed.dep_hashes,
    event: signed.event,
  }
  let result = adapter.deliver(forged)
  match result {
    Rejected(alert) => assert_eq(alert.kind, InvalidSignature)
    _ => panic()
  }
}
