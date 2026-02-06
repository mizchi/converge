///|
test "compress: single event" {
  let events : Array[@types.Event] = [
    {
      id: { peer: @types.PeerId("a"), counter: 0 },
      deps: [],
      lamport: 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
        ("x", @types.Value::Int(1)),
      ]),
    },
  ]
  let runs = @oplog.compress(events)
  assert_eq(runs.length(), 1)
  assert_eq(runs[0].ops.length(), 1)
  assert_eq(runs[0].counter_start, 0)
}

///|
test "compress: consecutive events merge into one run" {
  let peer = @types.PeerId("a")
  let events : Array[@types.Event] = [
    {
      id: { peer, counter: 0 },
      deps: [],
      lamport: 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
        ("x", @types.Value::Int(1)),
      ]),
    },
    {
      id: { peer, counter: 1 },
      deps: [{ peer, counter: 0 }],
      lamport: 2,
      op: @types.RowOp::Update(
        tbl="t",
        row_id="r1",
        col="x",
        value=@types.Value::Int(2),
      ),
    },
    {
      id: { peer, counter: 2 },
      deps: [{ peer, counter: 1 }],
      lamport: 3,
      op: @types.RowOp::Update(
        tbl="t",
        row_id="r1",
        col="x",
        value=@types.Value::Int(3),
      ),
    },
  ]
  let runs = @oplog.compress(events)
  assert_eq(runs.length(), 1)
  assert_eq(runs[0].ops.length(), 3)
}

///|
test "compress: different peers create separate runs" {
  let events : Array[@types.Event] = [
    {
      id: { peer: @types.PeerId("a"), counter: 0 },
      deps: [],
      lamport: 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
        ("x", @types.Value::Int(1)),
      ]),
    },
    {
      id: { peer: @types.PeerId("b"), counter: 0 },
      deps: [],
      lamport: 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r2", values=[
        ("y", @types.Value::Int(2)),
      ]),
    },
  ]
  let runs = @oplog.compress(events)
  assert_eq(runs.length(), 2)
}

///|
test "expand roundtrip" {
  let peer = @types.PeerId("a")
  let events : Array[@types.Event] = [
    {
      id: { peer, counter: 0 },
      deps: [],
      lamport: 1,
      op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
        ("x", @types.Value::Int(1)),
      ]),
    },
    {
      id: { peer, counter: 1 },
      deps: [{ peer, counter: 0 }],
      lamport: 2,
      op: @types.RowOp::Update(
        tbl="t",
        row_id="r1",
        col="x",
        value=@types.Value::Int(2),
      ),
    },
  ]
  let runs = @oplog.compress(events)
  let expanded = @oplog.expand(runs)
  assert_eq(expanded.length(), 2)
  assert_eq(expanded[0].id.counter, 0)
  assert_eq(expanded[1].id.counter, 1)
  assert_eq(expanded[0].lamport, 1)
  assert_eq(expanded[1].lamport, 2)
}

///|
test "OpLog::append with RLE merging" {
  let log = @oplog.OpLog::new()
  let peer = @types.PeerId("a")
  log.append({
    id: { peer, counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="t", row_id="r1", values=[
      ("x", @types.Value::Int(1)),
    ]),
  })
  log.append({
    id: { peer, counter: 1 },
    deps: [{ peer, counter: 0 }],
    lamport: 2,
    op: @types.RowOp::Update(
      tbl="t",
      row_id="r1",
      col="x",
      value=@types.Value::Int(2),
    ),
  })
  assert_eq(log.runs.length(), 1)
  assert_eq(log.runs[0].ops.length(), 2)
}

///|
test "OpLog::events_after filters by known versions" {
  let log = @oplog.OpLog::new()
  let peer = @types.PeerId("a")
  for i in 0..<5 {
    log.append({
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
  let known : Map[@types.PeerId, Int] = Map::new()
  known[@types.PeerId("a")] = 2
  let after = log.events_after(known)
  let expanded = @oplog.expand(after)
  assert_eq(expanded.length(), 2)
  assert_eq(expanded[0].id.counter, 3)
  assert_eq(expanded[1].id.counter, 4)
}
