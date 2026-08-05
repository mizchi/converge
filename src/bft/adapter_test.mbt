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
  BFTAdapter::new(hasher, verifier, session_id="test-session")
}

///|
fn register_signer(
  adapter : BFTAdapter,
  peer : String,
  signer : MockSigner,
) -> Unit raise Error {
  assert_true(adapter.register_peer(@types.PeerId(peer), signer.public_key()))
}

///|
test "happy path: sign and deliver" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  register_signer(adapter, "alice", signer_a)
  let event = make_event("alice", 0, 1, [])
  let signed = sign_event(adapter, signer_a, event, [])
  let result = adapter.deliver(signed)
  match result {
    Accepted(authenticated) => {
      assert_eq(authenticated.event().id.counter, 0)
      assert_eq(authenticated.digest(), signed.digest)
      assert_eq(authenticated.session_id(), "test-session")
    }
    _ => panic()
  }
}

///|
test "hash tamper: modified event content" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  register_signer(adapter, "alice", signer_a)
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
    session_id: signed.session_id,
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
  register_signer(adapter, "alice", signer_a)
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
  register_signer(adapter, "alice", signer_a)
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
    Accepted(e) => assert_eq(e.event().id.counter, 0)
    _ => panic()
  }
  // Check that the flushed events contain event1
  let flushed = adapter.take_flushed()
  assert_eq(flushed.length(), 1)
  assert_eq(flushed[0].event().id.counter, 1)
  assert_eq(flushed[0].session_id(), "test-session")
}

///|
test "invalid signature: signature bytes do not verify" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  register_signer(adapter, "alice", signer_a)
  let event = make_event("alice", 0, 1, [])
  let signed = sign_event(adapter, signer_a, event, [])
  // Keep the roster-bound author key, but replace the signature bytes.
  let forged : SignedEvent = {
    session_id: signed.session_id,
    digest: signed.digest,
    signature: Signature("invalid"),
    author_key: signed.author_key,
    dep_hashes: signed.dep_hashes,
    event: signed.event,
  }
  let result = adapter.deliver(forged)
  match result {
    Rejected(alert) => assert_eq(alert.kind, InvalidSignature)
    _ => panic()
  }
}

///|
test "identity binding: unregistered peer is rejected" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  let event = make_event("alice", 0, 1, [])
  let signed = sign_event(adapter, signer_a, event, [])
  match adapter.deliver(signed) {
    Rejected(alert) => assert_eq(alert.kind, UnknownPeer)
    _ => panic()
  }
}

///|
test "identity binding: another key cannot claim a registered peer" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  let signer_mallory = MockSigner::new("mallory")
  assert_true(
    adapter.register_peer(@types.PeerId("alice"), signer_a.public_key()),
  )
  let event = make_event("alice", 0, 1, [])
  let forged = sign_event(adapter, signer_mallory, event, [])
  match adapter.deliver(forged) {
    Rejected(alert) => assert_eq(alert.kind, AuthorKeyMismatch)
    _ => panic()
  }
}

///|
test "identity binding: a registered peer key cannot be rebound" {
  let adapter = make_adapter()
  assert_true(adapter.register_peer(@types.PeerId("alice"), PublicKey("alice")))
  assert_false(
    adapter.register_peer(@types.PeerId("alice"), PublicKey("mallory")),
  )
}

///|
test "hash tamper: event dependency ids are authenticated" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  register_signer(adapter, "alice", signer_a)
  let event = make_event("alice", 0, 1, [])
  let signed = sign_event(adapter, signer_a, event, [])
  let tampered_event : @types.Event = {
    id: event.id,
    deps: [{ peer: @types.PeerId("mallory"), counter: 99 }],
    lamport: event.lamport,
    op: event.op,
  }
  let tampered : SignedEvent = {
    session_id: signed.session_id,
    digest: signed.digest,
    signature: signed.signature,
    author_key: signed.author_key,
    dep_hashes: signed.dep_hashes,
    event: tampered_event,
  }
  match adapter.deliver(tampered) {
    Rejected(alert) => assert_eq(alert.kind, HashMismatch)
    _ => panic()
  }
}

///|
test "canonical serialization separates string field boundaries" {
  let left : @types.Event = {
    id: { peer: @types.PeerId("alice"), counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="a:b", row_id="c", values=[]),
  }
  let right : @types.Event = {
    id: { peer: @types.PeerId("alice"), counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="a", row_id="b:c", values=[]),
  }
  assert_not_eq(
    serialize_for_hash("test-session", left, []),
    serialize_for_hash("test-session", right, []),
  )
}

///|
test "session binding: an event signed for another session is rejected" {
  let source = BFTAdapter::new(
    FnvHasher::new(),
    MockVerifier::new(),
    session_id="session-a",
  )
  let target = BFTAdapter::new(
    FnvHasher::new(),
    MockVerifier::new(),
    session_id="session-b",
  )
  let signer = MockSigner::new("alice")
  assert_true(target.register_peer(@types.PeerId("alice"), signer.public_key()))
  let signed = source.sign(signer, make_event("alice", 0, 1, []), [])
  match target.deliver(signed) {
    Rejected(alert) => assert_eq(alert.kind, BFTAlertKind::SessionMismatch)
    _ => fail("cross-session event unexpectedly authenticated")
  }
  let relabeled : SignedEvent = { ..signed, session_id: "session-b" }
  match target.deliver(relabeled) {
    Rejected(alert) => assert_eq(alert.kind, BFTAlertKind::HashMismatch)
    _ => fail("unsigned session relabeling unexpectedly authenticated")
  }
}

///|
test "equivocation is rejected while conflicting events are buffered" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  let signer_b = MockSigner::new("bob")
  assert_true(
    adapter.register_peer(@types.PeerId("alice"), signer_a.public_key()),
  )
  assert_true(
    adapter.register_peer(@types.PeerId("bob"), signer_b.public_key()),
  )
  let root = sign_event(adapter, signer_a, make_event("alice", 0, 1, []), [])
  let first = sign_event(
    adapter,
    signer_b,
    {
      id: { peer: @types.PeerId("bob"), counter: 0 },
      deps: [{ peer: @types.PeerId("alice"), counter: 0 }],
      lamport: 2,
      op: @types.RowOp::Insert(tbl="t", row_id="first", values=[]),
    },
    [root.digest],
  )
  let conflict = sign_event(
    adapter,
    signer_b,
    {
      id: { peer: @types.PeerId("bob"), counter: 0 },
      deps: [{ peer: @types.PeerId("alice"), counter: 0 }],
      lamport: 2,
      op: @types.RowOp::Insert(tbl="t", row_id="conflict", values=[]),
    },
    [root.digest],
  )
  inspect(adapter.deliver(first) is Buffered, content="true")
  match adapter.deliver(conflict) {
    Rejected(alert) => assert_eq(alert.kind, Equivocation)
    _ => panic()
  }
  inspect(adapter.deliver(root) is Accepted(_), content="true")
  assert_eq(adapter.take_flushed().length(), 1)
}

///|
test "causal binding: dependency id must match its accepted digest" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  let signer_b = MockSigner::new("bob")
  let signer_c = MockSigner::new("charlie")
  register_signer(adapter, "alice", signer_a)
  register_signer(adapter, "bob", signer_b)
  register_signer(adapter, "charlie", signer_c)
  let alice = sign_event(adapter, signer_a, make_event("alice", 0, 1, []), [])
  let charlie = sign_event(adapter, signer_c, make_event("charlie", 0, 1, []), [])
  inspect(adapter.deliver(alice) is Accepted(_), content="true")
  inspect(adapter.deliver(charlie) is Accepted(_), content="true")
  let inconsistent = sign_event(
    adapter,
    signer_b,
    {
      id: { peer: @types.PeerId("bob"), counter: 0 },
      deps: [{ peer: @types.PeerId("alice"), counter: 0 }],
      lamport: 2,
      op: @types.RowOp::Insert(tbl="t", row_id="bad", values=[]),
    },
    [charlie.digest],
  )
  match adapter.deliver(inconsistent) {
    Rejected(alert) => assert_eq(alert.kind, DependencyMismatch)
    _ => panic()
  }
}

///|
test "causal binding: buffered mismatch is rejected when dependency arrives" {
  let adapter = make_adapter()
  let signer_a = MockSigner::new("alice")
  let signer_b = MockSigner::new("bob")
  let signer_c = MockSigner::new("charlie")
  register_signer(adapter, "alice", signer_a)
  register_signer(adapter, "bob", signer_b)
  register_signer(adapter, "charlie", signer_c)
  let charlie = sign_event(adapter, signer_c, make_event("charlie", 0, 1, []), [])
  let inconsistent = sign_event(
    adapter,
    signer_b,
    {
      id: { peer: @types.PeerId("bob"), counter: 0 },
      deps: [{ peer: @types.PeerId("alice"), counter: 0 }],
      lamport: 2,
      op: @types.RowOp::Insert(tbl="t", row_id="bad", values=[]),
    },
    [charlie.digest],
  )
  inspect(adapter.deliver(inconsistent) is Buffered, content="true")
  inspect(adapter.deliver(charlie) is Accepted(_), content="true")
  assert_eq(adapter.take_flushed().length(), 0)
  let alerts = adapter.take_flushed_alerts()
  assert_eq(alerts.length(), 1)
  assert_eq(alerts[0].kind, DependencyMismatch)
}
