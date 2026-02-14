///|
/// Document handle storage
let docs : Array[@doc.CrdtDoc] = []

///|
/// Ephemeral store handle storage (parallel to docs)
let stores : Array[@ephemeral.EphemeralStore] = []

// -- Value conversion --

///|
fn wit_to_value(v : Value) -> @types.Value {
  match v {
    ValNull => @types.Value::Null
    ValBool(b) => @types.Value::Bool(b)
    ValInt(i) => @types.Value::Int(i)
    ValFloat(f) => @types.Value::Float(f)
    ValStr(s) => @types.Value::Str(s)
  }
}

///|
fn value_to_wit(v : @types.Value) -> Value {
  match v {
    Null => ValNull
    Bool(b) => ValBool(b)
    Int(i) => ValInt(i)
    Float(f) => ValFloat(f)
    Str(s) => ValStr(s)
  }
}

// -- KeyValue conversion --

///|
fn wit_to_kv(kv : KeyValue) -> (String, @types.Value) {
  (kv.key, wit_to_value(kv.val))
}

///|
fn kv_to_wit(pair : (String, @types.Value)) -> KeyValue {
  { key: pair.0, val: value_to_wit(pair.1) }
}

// -- EventId conversion --

///|
fn wit_to_event_id(eid : EventId) -> @types.EventId {
  { peer: @types.PeerId(eid.peer), counter: eid.counter }
}

///|
fn event_id_to_wit(eid : @types.EventId) -> EventId {
  let @types.PeerId(peer_str) = eid.peer
  { peer: peer_str, counter: eid.counter }
}

// -- RowOp conversion --

///|
fn wit_to_row_op(op : RowOp) -> @types.RowOp {
  match op {
    Insert(r) =>
      @types.RowOp::Insert(
        tbl=r.tbl,
        row_id=r.row_id,
        values=r.values.map(wit_to_kv),
      )
    Update(r) =>
      @types.RowOp::Update(
        tbl=r.tbl,
        row_id=r.row_id,
        col=r.col,
        value=wit_to_value(r.val),
      )
    Delete(r) => @types.RowOp::Delete(tbl=r.tbl, row_id=r.row_id)
  }
}

///|
fn row_op_to_wit(op : @types.RowOp) -> RowOp {
  match op {
    Insert(tbl~, row_id~, values~) =>
      RowOp::Insert({
        tbl,
        row_id,
        values: values.map(kv_to_wit),
      })
    Update(tbl~, row_id~, col~, value~) =>
      RowOp::Update({ tbl, row_id, col, val: value_to_wit(value) })
    Delete(tbl~, row_id~) => RowOp::Delete({ tbl, row_id })
  }
}

// -- Event conversion --

///|
fn event_to_wit(e : @types.Event) -> Event {
  {
    id: event_id_to_wit(e.id),
    deps: e.deps.map(event_id_to_wit),
    lamport: e.lamport,
    op: row_op_to_wit(e.op),
  }
}

// -- EventRun conversion --

///|
fn wit_to_event_run(r : EventRun) -> @types.EventRun {
  {
    peer: @types.PeerId(r.peer),
    counter_start: r.counter_start,
    lamport_start: r.lamport_start,
    deps: r.deps.map(wit_to_event_id),
    ops: r.ops.map(wit_to_row_op),
  }
}

///|
fn event_run_to_wit(r : @types.EventRun) -> EventRun {
  let @types.PeerId(peer_str) = r.peer
  {
    peer: peer_str,
    counter_start: r.counter_start,
    lamport_start: r.lamport_start,
    deps: r.deps.map(event_id_to_wit),
    ops: r.ops.map(row_op_to_wit),
  }
}

// -- MergeOp conversion --

///|
fn merge_op_to_wit(op : @merge.MergeOp) -> MergeOp {
  match op {
    SetCell(tbl~, row_id~, col~, value~) =>
      MergeOp::SetCell({ tbl, row_id, col, val: value_to_wit(value) })
    InsertRow(tbl~, row_id~, values~) =>
      MergeOp::InsertRow({
        tbl,
        row_id,
        values: values.map(kv_to_wit),
      })
    DeleteRow(tbl~, row_id~) => MergeOp::DeleteRow({ tbl, row_id })
  }
}

// -- PeerVersion / SyncState conversion --

///|
fn wit_to_known_peers(
  versions : Array[PeerVersion],
) -> Map[@types.PeerId, Int] {
  let m : Map[@types.PeerId, Int] = Map::new()
  for pv in versions {
    m[@types.PeerId(pv.peer)] = pv.version
  }
  m
}

///|
fn sync_state_to_wit(
  frontier : Array[@types.EventId],
  versions : Map[@types.PeerId, Int],
) -> SyncState {
  let pvs : Array[PeerVersion] = []
  for peer, ver in versions {
    let @types.PeerId(peer_str) = peer
    pvs.push({ peer: peer_str, version: ver })
  }
  { frontier: frontier.map(event_id_to_wit), versions: pvs }
}

// -- EphemeralEntry conversion --

///|
fn ephemeral_entry_to_wit(
  key : String,
  entry : @ephemeral.EphemeralEntry,
) -> EphemeralEntry {
  let @types.PeerId(peer_str) = entry.peer
  { key, val: value_to_wit(entry.value), timestamp: entry.timestamp, peer: peer_str }
}

// ========== API implementations ==========

///|
fn create_doc(peer_id : String) -> UInt {
  let doc = @doc.CrdtDoc::new(peer_id~)
  docs.push(doc)
  stores.push(@ephemeral.EphemeralStore::new())
  (docs.length() - 1).reinterpret_as_uint()
}

///|
fn doc_insert(
  handle : UInt,
  tbl : String,
  row_id : String,
  values : Array[KeyValue],
) -> Event {
  let h = handle.reinterpret_as_int()
  let event = docs[h].insert(
    tbl~,
    row_id~,
    values=values.map(wit_to_kv),
  )
  event_to_wit(event)
}

///|
fn doc_update(
  handle : UInt,
  tbl : String,
  row_id : String,
  col : String,
  val : Value,
) -> Event {
  let h = handle.reinterpret_as_int()
  let event = docs[h].update(tbl~, row_id~, col~, value=wit_to_value(val))
  event_to_wit(event)
}

///|
fn doc_delete(handle : UInt, tbl : String, row_id : String) -> Event {
  let h = handle.reinterpret_as_int()
  let event = docs[h].delete(tbl~, row_id~)
  event_to_wit(event)
}

///|
fn doc_merge_remote(
  handle : UInt,
  events : Array[EventRun],
) -> Array[MergeOp] {
  let h = handle.reinterpret_as_int()
  let runs = events.map(wit_to_event_run)
  let ops = docs[h].merge_remote(runs)
  ops.map(merge_op_to_wit)
}

///|
fn doc_get_pending(
  handle : UInt,
  known : Array[PeerVersion],
) -> Array[EventRun] {
  let h = handle.reinterpret_as_int()
  let runs = docs[h].get_pending(wit_to_known_peers(known))
  runs.map(event_run_to_wit)
}

///|
fn doc_sync_state(handle : UInt) -> SyncState {
  let h = handle.reinterpret_as_int()
  let (frontier, versions) = docs[h].sync_state()
  sync_state_to_wit(frontier, versions)
}

///|
fn ephemeral_set(
  handle : UInt,
  ns : String,
  key : String,
  val : Value,
  timestamp : Double,
) -> EphemeralEntry {
  let h = handle.reinterpret_as_int()
  let store = stores[h]
  let @types.PeerId(peer_str) = docs[h].peer_id
  let peer = @types.PeerId(peer_str)
  store.set(ns, key, wit_to_value(val), timestamp, peer)
  ephemeral_entry_to_wit(key, { value: wit_to_value(val), timestamp, peer })
}

///|
fn ephemeral_get(
  handle : UInt,
  ns : String,
  key : String,
) -> EphemeralEntry? {
  let h = handle.reinterpret_as_int()
  match stores[h].get(ns, key) {
    Some(entry) => Some(ephemeral_entry_to_wit(key, entry))
    None => None
  }
}

///|
fn ephemeral_get_all(handle : UInt, ns : String) -> Array[EphemeralEntry] {
  let h = handle.reinterpret_as_int()
  let entries = stores[h].get_all(ns)
  let result : Array[EphemeralEntry] = []
  for k, entry in entries {
    result.push(ephemeral_entry_to_wit(k, entry))
  }
  result
}

///|
fn ephemeral_merge(
  handle : UInt,
  entries : Array[EphemeralRemoteEntry],
) -> Array[EphemeralRemoteEntry] {
  let h = handle.reinterpret_as_int()
  let store = stores[h]
  let changed : Array[EphemeralRemoteEntry] = []
  for e in entries {
    let entry : @ephemeral.EphemeralEntry = {
      value: wit_to_value(e.val),
      timestamp: e.timestamp,
      peer: @types.PeerId(e.peer),
    }
    if store.merge(e.ns, e.key, entry) {
      changed.push(e)
    }
  }
  changed
}
