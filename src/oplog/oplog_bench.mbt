///|
/// RLE compress: 1000 consecutive events from same peer
test "bench: compress 1000 events" (b : @bench.T) {
  let peer = @types.PeerId("a")
  let events : Array[@types.Event] = []
  for i in 0..<1000 {
    events.push({
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
  b.bench(fn() { b.keep(compress(events)) })
}

///|
/// RLE expand: 1 run with 1000 ops
test "bench: expand 1 run x 1000 ops" (b : @bench.T) {
  let peer = @types.PeerId("a")
  let ops : Array[@types.RowOp] = []
  for i in 0..<1000 {
    ops.push(
      @types.RowOp::Update(
        tbl="t",
        row_id="r1",
        col="x",
        value=@types.Value::Int(i),
      ),
    )
  }
  let runs : Array[@types.EventRun] = [
    { peer, counter_start: 0, lamport_start: 1, deps: [], ops },
  ]
  b.bench(fn() { b.keep(expand(runs)) })
}

///|
/// OpLog append: 1000 sequential events
test "bench: OpLog append 1000 events" (b : @bench.T) {
  b.bench(fn() {
    let log = OpLog::new()
    let peer = @types.PeerId("a")
    for i in 0..<1000 {
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
    b.keep(log)
  })
}
