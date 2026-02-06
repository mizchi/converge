///|
struct SimpleDB {
  rows : Map[String, Map[String, @types.Value]]
}

///|
fn SimpleDB::new() -> SimpleDB {
  { rows: Map::new() }
}

///|
fn SimpleDB::apply_ops(self : SimpleDB, ops : Array[@merge.MergeOp]) -> Unit {
  for op in ops {
    match op {
      @merge.MergeOp::InsertRow(tbl~, row_id~, values~) => {
        let key = tbl + "\u0000" + row_id
        let row : Map[String, @types.Value] = Map::new()
        for pair in values {
          row[pair.0] = pair.1
        }
        self.rows[key] = row
      }
      @merge.MergeOp::SetCell(tbl~, row_id~, col~, value~) => {
        let key = tbl + "\u0000" + row_id
        match self.rows.get(key) {
          Some(row) => row[col] = value
          None => {
            let row : Map[String, @types.Value] = Map::new()
            row[col] = value
            self.rows[key] = row
          }
        }
      }
      @merge.MergeOp::DeleteRow(tbl~, row_id~) => {
        let key = tbl + "\u0000" + row_id
        self.rows.remove(key)
      }
    }
  }
}

///|
fn SimpleDB::get(
  self : SimpleDB,
  tbl : String,
  row_id : String,
  col : String
) -> @types.Value? {
  let key = tbl + "\u0000" + row_id
  match self.rows.get(key) {
    Some(row) => row.get(col)
    None => None
  }
}

///|
fn SimpleDB::has_row(self : SimpleDB, tbl : String, row_id : String) -> Bool {
  let key = tbl + "\u0000" + row_id
  self.rows.get(key) is Some(_)
}

///|
fn sync_to_server(
  doc : @doc.CrdtDoc,
  transport : @sync.InMemoryTransport
) -> Unit raise Error {
  let (frontier, versions) = doc.sync_state()
  let pending = doc.get_pending(transport.peer_versions)
  if not(pending.is_empty()) {
    transport.push({ peer_id: doc.peer_id, events: pending, frontier })
  }
  ignore(versions)
}

///|
fn sync_from_server(
  doc : @doc.CrdtDoc,
  db : SimpleDB,
  transport : @sync.InMemoryTransport
) -> Unit raise Error {
  let (_, versions) = doc.sync_state()
  let response = transport.pull(
    { peer_id: doc.peer_id, known_peers: versions },
  )
  if not(response.events.is_empty()) {
    let ops = doc.merge_remote(response.events)
    db.apply_ops(ops)
  }
}

///|
fn full_sync(
  doc : @doc.CrdtDoc,
  db : SimpleDB,
  transport : @sync.InMemoryTransport
) -> Unit raise Error {
  sync_to_server(doc, transport)
  sync_from_server(doc, db, transport)
}

///|
test "e2e: collaborative todo app" {
  let server = @sync.InMemoryTransport::new()

  let alice_doc = @doc.CrdtDoc::new(peer_id="alice")
  let alice_db = SimpleDB::new()
  let bob_doc = @doc.CrdtDoc::new(peer_id="bob")
  let bob_db = SimpleDB::new()
  let charlie_doc = @doc.CrdtDoc::new(peer_id="charlie")
  let charlie_db = SimpleDB::new()

  // Alice: insert a todo
  ignore(
    alice_doc.insert(
      tbl="todos",
      row_id="t1",
      values=[
        ("text", @types.Value::Str("Buy milk")),
        ("done", @types.Value::Bool(false)),
      ],
    ),
  )
  alice_db.apply_ops(
    [
      @merge.MergeOp::InsertRow(
        tbl="todos",
        row_id="t1",
        values=[
          ("text", @types.Value::Str("Buy milk")),
          ("done", @types.Value::Bool(false)),
        ],
      ),
    ],
  )

  // Alice pushes to server
  full_sync(alice_doc, alice_db, server)

  // Bob pulls from server
  full_sync(bob_doc, bob_db, server)
  assert_eq(
    bob_db.get("todos", "t1", "text"),
    Some(@types.Value::Str("Buy milk")),
  )
  assert_eq(
    bob_db.get("todos", "t1", "done"),
    Some(@types.Value::Bool(false)),
  )

  // Bob: mark done=true, push
  ignore(
    bob_doc.update(
      tbl="todos",
      row_id="t1",
      col="done",
      value=@types.Value::Bool(true),
    ),
  )
  bob_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="todos",
        row_id="t1",
        col="done",
        value=@types.Value::Bool(true),
      ),
    ],
  )
  full_sync(bob_doc, bob_db, server)

  // Charlie pulls, updates text, pushes
  full_sync(charlie_doc, charlie_db, server)
  assert_eq(
    charlie_db.get("todos", "t1", "done"),
    Some(@types.Value::Bool(true)),
  )
  ignore(
    charlie_doc.update(
      tbl="todos",
      row_id="t1",
      col="text",
      value=@types.Value::Str("Buy eggs"),
    ),
  )
  charlie_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="todos",
        row_id="t1",
        col="text",
        value=@types.Value::Str("Buy eggs"),
      ),
    ],
  )
  full_sync(charlie_doc, charlie_db, server)

  // Everyone pulls final state
  full_sync(alice_doc, alice_db, server)
  full_sync(bob_doc, bob_db, server)
  full_sync(charlie_doc, charlie_db, server)

  // All 3 should converge to the same state
  let expected_text = @types.Value::Str("Buy eggs")
  let expected_done = @types.Value::Bool(true)
  assert_eq(alice_db.get("todos", "t1", "text"), Some(expected_text))
  assert_eq(alice_db.get("todos", "t1", "done"), Some(expected_done))
  assert_eq(bob_db.get("todos", "t1", "text"), Some(expected_text))
  assert_eq(bob_db.get("todos", "t1", "done"), Some(expected_done))
  assert_eq(charlie_db.get("todos", "t1", "text"), Some(expected_text))
  assert_eq(charlie_db.get("todos", "t1", "done"), Some(expected_done))
}

///|
test "e2e: offline editing and reconnect" {
  let server = @sync.InMemoryTransport::new()

  let alice_doc = @doc.CrdtDoc::new(peer_id="alice")
  let alice_db = SimpleDB::new()
  let bob_doc = @doc.CrdtDoc::new(peer_id="bob")
  let bob_db = SimpleDB::new()

  // Initial: Alice inserts, syncs to server, Bob pulls
  ignore(
    alice_doc.insert(
      tbl="notes",
      row_id="n1",
      values=[
        ("text", @types.Value::Str("hello")),
        ("done", @types.Value::Bool(false)),
      ],
    ),
  )
  alice_db.apply_ops(
    [
      @merge.MergeOp::InsertRow(
        tbl="notes",
        row_id="n1",
        values=[
          ("text", @types.Value::Str("hello")),
          ("done", @types.Value::Bool(false)),
        ],
      ),
    ],
  )
  full_sync(alice_doc, alice_db, server)
  full_sync(bob_doc, bob_db, server)

  // --- Both go offline ---

  // Alice: 3 consecutive updates to text
  ignore(
    alice_doc.update(
      tbl="notes",
      row_id="n1",
      col="text",
      value=@types.Value::Str("v1"),
    ),
  )
  ignore(
    alice_doc.update(
      tbl="notes",
      row_id="n1",
      col="text",
      value=@types.Value::Str("v2"),
    ),
  )
  ignore(
    alice_doc.update(
      tbl="notes",
      row_id="n1",
      col="text",
      value=@types.Value::Str("v3"),
    ),
  )
  alice_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="notes",
        row_id="n1",
        col="text",
        value=@types.Value::Str("v3"),
      ),
    ],
  )

  // Bob: update done (different column)
  ignore(
    bob_doc.update(
      tbl="notes",
      row_id="n1",
      col="done",
      value=@types.Value::Bool(true),
    ),
  )
  bob_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="notes",
        row_id="n1",
        col="done",
        value=@types.Value::Bool(true),
      ),
    ],
  )

  // --- Reconnect: both push, then both pull ---
  sync_to_server(alice_doc, server)
  sync_to_server(bob_doc, server)
  sync_from_server(alice_doc, alice_db, server)
  sync_from_server(bob_doc, bob_db, server)

  // Both changes should be reflected (different columns, no conflict)
  assert_eq(
    alice_db.get("notes", "n1", "text"),
    Some(@types.Value::Str("v3")),
  )
  assert_eq(
    alice_db.get("notes", "n1", "done"),
    Some(@types.Value::Bool(true)),
  )
  assert_eq(
    bob_db.get("notes", "n1", "text"),
    Some(@types.Value::Str("v3")),
  )
  assert_eq(
    bob_db.get("notes", "n1", "done"),
    Some(@types.Value::Bool(true)),
  )
}

///|
test "e2e: concurrent same-cell conflict (LWW)" {
  let server = @sync.InMemoryTransport::new()

  let alice_doc = @doc.CrdtDoc::new(peer_id="alice")
  let alice_db = SimpleDB::new()
  let bob_doc = @doc.CrdtDoc::new(peer_id="bob")
  let bob_db = SimpleDB::new()
  let charlie_doc = @doc.CrdtDoc::new(peer_id="charlie")
  let charlie_db = SimpleDB::new()

  // Alice creates initial row, syncs to all
  ignore(
    alice_doc.insert(
      tbl="scores",
      row_id="s1",
      values=[("score", @types.Value::Int(0))],
    ),
  )
  alice_db.apply_ops(
    [
      @merge.MergeOp::InsertRow(
        tbl="scores",
        row_id="s1",
        values=[("score", @types.Value::Int(0))],
      ),
    ],
  )
  full_sync(alice_doc, alice_db, server)
  full_sync(bob_doc, bob_db, server)
  full_sync(charlie_doc, charlie_db, server)

  // All go offline, each updates the same cell
  // Alice: score=10 (lamport lowest, only 1 op)
  ignore(
    alice_doc.update(
      tbl="scores",
      row_id="s1",
      col="score",
      value=@types.Value::Int(10),
    ),
  )
  alice_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="scores",
        row_id="s1",
        col="score",
        value=@types.Value::Int(10),
      ),
    ],
  )

  // Bob: 2 ops to bump lamport, final score=20
  ignore(
    bob_doc.update(
      tbl="scores",
      row_id="s1",
      col="score",
      value=@types.Value::Int(15),
    ),
  )
  ignore(
    bob_doc.update(
      tbl="scores",
      row_id="s1",
      col="score",
      value=@types.Value::Int(20),
    ),
  )
  bob_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="scores",
        row_id="s1",
        col="score",
        value=@types.Value::Int(20),
      ),
    ],
  )

  // Charlie: 3 ops to get highest lamport, final score=30
  ignore(
    charlie_doc.update(
      tbl="scores",
      row_id="s1",
      col="score",
      value=@types.Value::Int(5),
    ),
  )
  ignore(
    charlie_doc.update(
      tbl="scores",
      row_id="s1",
      col="score",
      value=@types.Value::Int(15),
    ),
  )
  ignore(
    charlie_doc.update(
      tbl="scores",
      row_id="s1",
      col="score",
      value=@types.Value::Int(30),
    ),
  )
  charlie_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="scores",
        row_id="s1",
        col="score",
        value=@types.Value::Int(30),
      ),
    ],
  )

  // Sync all: push, then pull
  sync_to_server(alice_doc, server)
  sync_to_server(bob_doc, server)
  sync_to_server(charlie_doc, server)
  sync_from_server(alice_doc, alice_db, server)
  sync_from_server(bob_doc, bob_db, server)
  sync_from_server(charlie_doc, charlie_db, server)

  // Charlie has highest lamport -> score=30 wins
  let expected = @types.Value::Int(30)
  assert_eq(alice_db.get("scores", "s1", "score"), Some(expected))
  assert_eq(bob_db.get("scores", "s1", "score"), Some(expected))
  assert_eq(charlie_db.get("scores", "s1", "score"), Some(expected))
}

///|
test "e2e: network partition and recovery" {
  // Two separate servers simulating a network partition
  let server1 = @sync.InMemoryTransport::new()
  let server2 = @sync.InMemoryTransport::new()

  let alice_doc = @doc.CrdtDoc::new(peer_id="alice")
  let alice_db = SimpleDB::new()
  let bob_doc = @doc.CrdtDoc::new(peer_id="bob")
  let bob_db = SimpleDB::new()
  let charlie_doc = @doc.CrdtDoc::new(peer_id="charlie")
  let charlie_db = SimpleDB::new()

  // Initial data: Alice inserts, syncs to both servers
  ignore(
    alice_doc.insert(
      tbl="items",
      row_id="i1",
      values=[
        ("name", @types.Value::Str("item1")),
        ("qty", @types.Value::Int(1)),
      ],
    ),
  )
  alice_db.apply_ops(
    [
      @merge.MergeOp::InsertRow(
        tbl="items",
        row_id="i1",
        values=[
          ("name", @types.Value::Str("item1")),
          ("qty", @types.Value::Int(1)),
        ],
      ),
    ],
  )
  full_sync(alice_doc, alice_db, server1)
  full_sync(alice_doc, alice_db, server2)

  // Bob and Charlie join their respective servers
  full_sync(bob_doc, bob_db, server1)
  full_sync(charlie_doc, charlie_db, server2)

  // --- Partition: Alice & Bob on server1, Charlie on server2 ---

  // Alice updates name on server1
  ignore(
    alice_doc.update(
      tbl="items",
      row_id="i1",
      col="name",
      value=@types.Value::Str("item1-updated"),
    ),
  )
  alice_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="items",
        row_id="i1",
        col="name",
        value=@types.Value::Str("item1-updated"),
      ),
    ],
  )
  full_sync(alice_doc, alice_db, server1)
  full_sync(bob_doc, bob_db, server1)

  // Charlie updates qty on server2
  ignore(
    charlie_doc.update(
      tbl="items",
      row_id="i1",
      col="qty",
      value=@types.Value::Int(10),
    ),
  )
  charlie_db.apply_ops(
    [
      @merge.MergeOp::SetCell(
        tbl="items",
        row_id="i1",
        col="qty",
        value=@types.Value::Int(10),
      ),
    ],
  )
  full_sync(charlie_doc, charlie_db, server2)

  // Verify partition state
  assert_eq(
    bob_db.get("items", "i1", "name"),
    Some(@types.Value::Str("item1-updated")),
  )
  assert_eq(bob_db.get("items", "i1", "qty"), Some(@types.Value::Int(1)))
  assert_eq(
    charlie_db.get("items", "i1", "name"),
    Some(@types.Value::Str("item1")),
  )
  assert_eq(
    charlie_db.get("items", "i1", "qty"),
    Some(@types.Value::Int(10)),
  )

  // --- Recovery: use a relay doc to bridge server1 <-> server2 ---
  let relay_doc = @doc.CrdtDoc::new(peer_id="relay")
  let relay_db = SimpleDB::new()

  // Relay pulls from server1 (gets Alice + Bob data)
  full_sync(relay_doc, relay_db, server1)
  // Relay pushes to server2 (bridges the partition)
  full_sync(relay_doc, relay_db, server2)
  // Relay pulls from server2 again (gets Charlie's data merged)
  full_sync(relay_doc, relay_db, server2)
  // Relay pushes back to server1
  full_sync(relay_doc, relay_db, server1)

  // All peers pull from their respective servers
  full_sync(alice_doc, alice_db, server1)
  full_sync(bob_doc, bob_db, server1)
  full_sync(charlie_doc, charlie_db, server2)

  // All should converge
  let expected_name = @types.Value::Str("item1-updated")
  let expected_qty = @types.Value::Int(10)
  assert_eq(alice_db.get("items", "i1", "name"), Some(expected_name))
  assert_eq(alice_db.get("items", "i1", "qty"), Some(expected_qty))
  assert_eq(bob_db.get("items", "i1", "name"), Some(expected_name))
  assert_eq(bob_db.get("items", "i1", "qty"), Some(expected_qty))
  assert_eq(charlie_db.get("items", "i1", "name"), Some(expected_name))
  assert_eq(charlie_db.get("items", "i1", "qty"), Some(expected_qty))
}

///|
test "e2e: bulk insert and sync" {
  let server = @sync.InMemoryTransport::new()

  let alice_doc = @doc.CrdtDoc::new(peer_id="alice")
  let alice_db = SimpleDB::new()
  let bob_doc = @doc.CrdtDoc::new(peer_id="bob")
  let bob_db = SimpleDB::new()

  // Alice inserts 100 rows
  let count = 100
  for i = 0; i < count; i = i + 1 {
    let row_id = "row-" + i.to_string()
    ignore(
      alice_doc.insert(
        tbl="bulk",
        row_id=row_id,
        values=[
          ("idx", @types.Value::Int(i)),
          ("label", @types.Value::Str("item-" + i.to_string())),
        ],
      ),
    )
    alice_db.apply_ops(
      [
        @merge.MergeOp::InsertRow(
          tbl="bulk",
          row_id=row_id,
          values=[
            ("idx", @types.Value::Int(i)),
            ("label", @types.Value::Str("item-" + i.to_string())),
          ],
        ),
      ],
    )
  }

  // Push to server
  full_sync(alice_doc, alice_db, server)

  // Bob pulls everything
  full_sync(bob_doc, bob_db, server)

  // Verify all 100 rows arrived
  for i = 0; i < count; i = i + 1 {
    let row_id = "row-" + i.to_string()
    assert_true(bob_db.has_row("bulk", row_id))
    assert_eq(bob_db.get("bulk", row_id, "idx"), Some(@types.Value::Int(i)))
    assert_eq(
      bob_db.get("bulk", row_id, "label"),
      Some(@types.Value::Str("item-" + i.to_string())),
    )
  }
}
