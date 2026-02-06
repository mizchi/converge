///|
fn make_event_id(peer : @types.PeerId, counter : Int) -> @types.EventId {
  { peer, counter }
}

///|
test "InMemoryTransport: push and pull" {
  let transport = @sync.InMemoryTransport::new()
  let peer = @types.PeerId("alice")
  let events : Array[@types.EventRun] = [
    {
      peer,
      counter_start: 0,
      lamport_start: 1,
      deps: [],
      ops: [
        @types.RowOp::Insert(tbl="t", row_id="r1", values=[
          ("x", @types.Value::Int(1)),
        ]),
        @types.RowOp::Update(
          tbl="t",
          row_id="r1",
          col="x",
          value=@types.Value::Int(2),
        ),
      ],
    },
  ]
  let frontier = [make_event_id(peer, 1)]
  transport.push({ peer_id: peer, events, frontier })
  assert_eq(transport.events.length(), 2)

  // Pull from empty known state
  let response = transport.pull({
    peer_id: @types.PeerId("bob"),
    known_peers: Map::new(),
  })
  let expanded = @oplog.expand(response.events)
  assert_eq(expanded.length(), 2)

  // Pull with known state (already seen counter 0)
  let known : Map[@types.PeerId, Int] = Map::new()
  known[peer] = 0
  let response2 = transport.pull({
    peer_id: @types.PeerId("bob"),
    known_peers: known,
  })
  let expanded2 = @oplog.expand(response2.events)
  assert_eq(expanded2.length(), 1)
  assert_eq(expanded2[0].id.counter, 1)
}

///|
test "InMemoryTransport: push deduplicates" {
  let transport = @sync.InMemoryTransport::new()
  let peer = @types.PeerId("alice")
  let events : Array[@types.EventRun] = [
    {
      peer,
      counter_start: 0,
      lamport_start: 1,
      deps: [],
      ops: [
        @types.RowOp::Insert(tbl="t", row_id="r1", values=[
          ("x", @types.Value::Int(1)),
        ]),
      ],
    },
  ]
  let frontier = [make_event_id(peer, 0)]
  // Push same data twice
  transport.push({
    peer_id: peer,
    events: events.copy(),
    frontier: frontier.copy(),
  })
  transport.push({
    peer_id: peer,
    events: events.copy(),
    frontier: frontier.copy(),
  })
  assert_eq(transport.events.length(), 1)
}

///|
test "InMemoryTransport: multi-peer scenario" {
  let transport = @sync.InMemoryTransport::new()
  let alice = @types.PeerId("alice")
  let bob = @types.PeerId("bob")
  // Alice pushes
  transport.push({
    peer_id: alice,
    events: [
      {
        peer: alice,
        counter_start: 0,
        lamport_start: 1,
        deps: [],
        ops: [
          @types.RowOp::Insert(tbl="t", row_id="r1", values=[
            ("x", @types.Value::Int(1)),
          ]),
        ],
      },
    ],
    frontier: [make_event_id(alice, 0)],
  })
  // Bob pushes
  transport.push({
    peer_id: bob,
    events: [
      {
        peer: bob,
        counter_start: 0,
        lamport_start: 1,
        deps: [],
        ops: [
          @types.RowOp::Insert(tbl="t", row_id="r2", values=[
            ("y", @types.Value::Int(2)),
          ]),
        ],
      },
    ],
    frontier: [make_event_id(bob, 0)],
  })
  assert_eq(transport.events.length(), 2)

  // Third peer pulls everything
  let response = transport.pull({
    peer_id: @types.PeerId("charlie"),
    known_peers: Map::new(),
  })
  let expanded = @oplog.expand(response.events)
  assert_eq(expanded.length(), 2)
}
