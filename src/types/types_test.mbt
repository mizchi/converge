///|
test "PeerId equality and hash" {
  let a : @types.PeerId = @types.PeerId("alice")
  let b : @types.PeerId = @types.PeerId("alice")
  let c : @types.PeerId = @types.PeerId("bob")
  assert_eq(a, b)
  assert_not_eq(a, c)
}

///|
test "EventId equality" {
  let id1 : @types.EventId = { peer: @types.PeerId("alice"), counter: 0 }
  let id2 : @types.EventId = { peer: @types.PeerId("alice"), counter: 0 }
  let id3 : @types.EventId = { peer: @types.PeerId("alice"), counter: 1 }
  assert_eq(id1, id2)
  assert_not_eq(id1, id3)
}

///|
test "Value variants" {
  let v1 : @types.Value = @types.Value::Null
  let v2 : @types.Value = @types.Value::Bool(true)
  let v3 : @types.Value = @types.Value::Int(42)
  let v4 : @types.Value = @types.Value::Float(3.14)
  let v5 : @types.Value = @types.Value::Str("hello")
  assert_eq(v1, @types.Value::Null)
  assert_eq(v2, @types.Value::Bool(true))
  assert_eq(v3, @types.Value::Int(42))
  assert_eq(v4, @types.Value::Float(3.14))
  assert_eq(v5, @types.Value::Str("hello"))
}

///|
test "RowOp Insert" {
  let op : @types.RowOp = @types.RowOp::Insert(tbl="users", row_id="u1", values=[
    ("name", @types.Value::Str("Alice")),
    ("age", @types.Value::Int(30)),
  ])
  inspect(
    op,
    content="Insert(tbl=\"users\", row_id=\"u1\", values=[(\"name\", Str(\"Alice\")), (\"age\", Int(30))])",
  )
}

///|
test "Event construction" {
  let event : @types.Event = {
    id: { peer: @types.PeerId("alice"), counter: 0 },
    deps: [],
    lamport: 1,
    op: @types.RowOp::Insert(tbl="todos", row_id="t1", values=[
      ("text", @types.Value::Str("Buy milk")),
    ]),
  }
  assert_eq(event.id.counter, 0)
  assert_eq(event.lamport, 1)
}

///|
test "EventRun construction" {
  let run : @types.EventRun = {
    peer: @types.PeerId("alice"),
    counter_start: 0,
    lamport_start: 1,
    deps: [],
    ops: [
      @types.RowOp::Insert(tbl="todos", row_id="t1", values=[
        ("text", @types.Value::Str("Buy milk")),
      ]),
      @types.RowOp::Update(
        tbl="todos",
        row_id="t1",
        col="text",
        value=@types.Value::Str("Buy eggs"),
      ),
    ],
  }
  assert_eq(run.ops.length(), 2)
  assert_eq(run.counter_start, 0)
}
