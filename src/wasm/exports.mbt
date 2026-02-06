///|
/// Document handle storage
let docs : Array[@doc.CrdtDoc] = []

///|
/// Ephemeral store handle storage (parallel to docs)
let ephemeral_stores : Array[@ephemeral.EphemeralStore] = []

///|
/// Create a new CRDT document and return its handle.
/// Also creates a paired EphemeralStore at the same index.
pub fn create_doc(peer_id : String) -> Int {
  let doc = @doc.CrdtDoc::new(peer_id~)
  docs.push(doc)
  ephemeral_stores.push(@ephemeral.EphemeralStore::new())
  docs.length() - 1
}

///|
/// Insert a row. values_json: [["col", value], ...]
pub fn doc_insert(
  handle : Int,
  tbl : String,
  row_id : String,
  values_json : String,
) -> String {
  let values = parse_values(values_json)
  let event = docs[handle].insert(tbl~, row_id~, values~)
  event_to_json(event).stringify()
}

///|
/// Update a cell
pub fn doc_update(
  handle : Int,
  tbl : String,
  row_id : String,
  col : String,
  value_json : String,
) -> String {
  let value = parse_value(value_json)
  let event = docs[handle].update(tbl~, row_id~, col~, value~)
  event_to_json(event).stringify()
}

///|
/// Delete a row
pub fn doc_delete(handle : Int, tbl : String, row_id : String) -> String {
  let event = docs[handle].delete(tbl~, row_id~)
  event_to_json(event).stringify()
}

///|
/// Merge remote events, returns merge operations as JSON
pub fn doc_merge_remote(handle : Int, events_json : String) -> String {
  let runs = parse_event_runs(events_json)
  let ops = docs[handle].merge_remote(runs)
  ops_to_json(ops).stringify()
}

///|
/// Get pending events for sync
pub fn doc_get_pending(handle : Int, known_json : String) -> String {
  let known = parse_known_peers(known_json)
  let runs = docs[handle].get_pending(known)
  runs_to_json(runs).stringify()
}

///|
/// Get current sync state
pub fn doc_sync_state(handle : Int) -> String {
  let (frontier, versions) = docs[handle].sync_state()
  sync_state_to_json(frontier, versions).stringify()
}

// --- JSON serialization helpers ---

///|
fn value_to_json(v : @types.Value) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Int(i) => Json::number(i.to_double())
    Float(f) => Json::number(f)
    Str(s) => Json::string(s)
  }
}

///|
fn parse_value(s : String) -> @types.Value {
  let json = try! @json.parse(s)
  json_to_value(json)
}

///|
fn json_to_value(json : Json) -> @types.Value {
  match json {
    Null => @types.Value::Null
    True => @types.Value::Bool(true)
    False => @types.Value::Bool(false)
    Number(n, ..) => {
      let i = n.to_int()
      if i.to_double() == n {
        @types.Value::Int(i)
      } else {
        @types.Value::Float(n)
      }
    }
    String(s) => @types.Value::Str(s)
    _ => @types.Value::Null
  }
}

///|
fn parse_values(s : String) -> Array[(String, @types.Value)] {
  let json = try! @json.parse(s)
  let result : Array[(String, @types.Value)] = []
  guard json is Array(arr) else { return result }
  for item in arr {
    guard item is Array(pair) && pair.length() >= 2 else { continue }
    guard pair[0] is String(key) else { continue }
    result.push((key, json_to_value(pair[1])))
  }
  result
}

///|
fn event_id_to_json(id : @types.EventId) -> Json {
  let @types.PeerId(peer_str) = id.peer
  Json::array([Json::string(peer_str), Json::number(id.counter.to_double())])
}

///|
fn event_to_json(e : @types.Event) -> Json {
  let deps_json = Json::array(e.deps.map(event_id_to_json))
  Json::object({
    "id": event_id_to_json(e.id),
    "deps": deps_json,
    "lamport": Json::number(e.lamport.to_double()),
    "op": row_op_to_json(e.op),
  })
}

///|
fn row_op_to_json(op : @types.RowOp) -> Json {
  match op {
    Insert(tbl~, row_id~, values~) => {
      let vals = Json::array(
        values.map(fn(pair) {
          Json::array([Json::string(pair.0), value_to_json(pair.1)])
        }),
      )
      Json::object({
        "type": Json::string("insert"),
        "tbl": Json::string(tbl),
        "row_id": Json::string(row_id),
        "values": vals,
      })
    }
    Update(tbl~, row_id~, col~, value~) =>
      Json::object({
        "type": Json::string("update"),
        "tbl": Json::string(tbl),
        "row_id": Json::string(row_id),
        "col": Json::string(col),
        "value": value_to_json(value),
      })
    Delete(tbl~, row_id~) =>
      Json::object({
        "type": Json::string("delete"),
        "tbl": Json::string(tbl),
        "row_id": Json::string(row_id),
      })
  }
}

///|
fn ops_to_json(ops : Array[@merge.MergeOp]) -> Json {
  Json::array(
    ops.map(fn(op) {
      match op {
        SetCell(tbl~, row_id~, col~, value~) =>
          Json::object({
            "type": Json::string("set_cell"),
            "tbl": Json::string(tbl),
            "row_id": Json::string(row_id),
            "col": Json::string(col),
            "value": value_to_json(value),
          })
        InsertRow(tbl~, row_id~, values~) => {
          let vals = Json::array(
            values.map(fn(pair) {
              Json::array([Json::string(pair.0), value_to_json(pair.1)])
            }),
          )
          Json::object({
            "type": Json::string("insert_row"),
            "tbl": Json::string(tbl),
            "row_id": Json::string(row_id),
            "values": vals,
          })
        }
        DeleteRow(tbl~, row_id~) =>
          Json::object({
            "type": Json::string("delete_row"),
            "tbl": Json::string(tbl),
            "row_id": Json::string(row_id),
          })
      }
    }),
  )
}

///|
fn runs_to_json(runs : Array[@types.EventRun]) -> Json {
  Json::array(
    runs.map(fn(run) {
      let @types.PeerId(peer_str) = run.peer
      let deps_json = Json::array(run.deps.map(event_id_to_json))
      let ops_json = Json::array(run.ops.map(row_op_to_json))
      Json::object({
        "peer": Json::string(peer_str),
        "counter_start": Json::number(run.counter_start.to_double()),
        "lamport_start": Json::number(run.lamport_start.to_double()),
        "deps": deps_json,
        "ops": ops_json,
      })
    }),
  )
}

///|
fn sync_state_to_json(
  frontier : Array[@types.EventId],
  versions : Map[@types.PeerId, Int],
) -> Json {
  let frontier_json = Json::array(frontier.map(event_id_to_json))
  let versions_json : Map[String, Json] = Map::new()
  for peer, counter in versions {
    let @types.PeerId(peer_str) = peer
    versions_json[peer_str] = Json::number(counter.to_double())
  }
  Json::object({
    "frontier": frontier_json,
    "versions": Json::object(versions_json),
  })
}

///|
fn parse_event_runs(s : String) -> Array[@types.EventRun] {
  let json = try! @json.parse(s)
  let result : Array[@types.EventRun] = []
  guard json is Array(arr) else { return result }
  for item in arr {
    guard item is Object(obj) else { continue }
    guard obj["peer"] is String(peer_str) else { continue }
    let peer = @types.PeerId(peer_str)
    guard obj["counter_start"] is Number(cs, ..) else { continue }
    guard obj["lamport_start"] is Number(ls, ..) else { continue }
    let deps = parse_event_ids(obj.get("deps").unwrap_or(Json::array([])))
    let ops = parse_row_ops(obj.get("ops").unwrap_or(Json::array([])))
    result.push({
      peer,
      counter_start: cs.to_int(),
      lamport_start: ls.to_int(),
      deps,
      ops,
    })
  }
  result
}

///|
fn parse_event_ids(json : Json) -> Array[@types.EventId] {
  let result : Array[@types.EventId] = []
  guard json is Array(arr) else { return result }
  for item in arr {
    guard item is Array(pair) &&
      pair.length() >= 2 &&
      pair[0] is String(peer_str) &&
      pair[1] is Number(counter, ..) else {
      continue
    }
    result.push({ peer: @types.PeerId(peer_str), counter: counter.to_int() })
  }
  result
}

///|
fn parse_row_ops(json : Json) -> Array[@types.RowOp] {
  let result : Array[@types.RowOp] = []
  guard json is Array(arr) else { return result }
  for item in arr {
    guard item is Object(obj) else { continue }
    guard obj["type"] is String(op_type) else { continue }
    match op_type {
      "insert" => {
        guard obj["tbl"] is String(tbl) && obj["row_id"] is String(row_id) else {
          continue
        }
        let values = parse_values_from_json(
          obj.get("values").unwrap_or(Json::array([])),
        )
        result.push(@types.RowOp::Insert(tbl~, row_id~, values~))
      }
      "update" => {
        guard obj["tbl"] is String(tbl) &&
          obj["row_id"] is String(row_id) &&
          obj["col"] is String(col) else {
          continue
        }
        let value = json_to_value(obj.get("value").unwrap_or(Json::null()))
        result.push(@types.RowOp::Update(tbl~, row_id~, col~, value~))
      }
      "delete" => {
        guard obj["tbl"] is String(tbl) && obj["row_id"] is String(row_id) else {
          continue
        }
        result.push(@types.RowOp::Delete(tbl~, row_id~))
      }
      _ => continue
    }
  }
  result
}

///|
fn parse_values_from_json(json : Json) -> Array[(String, @types.Value)] {
  let result : Array[(String, @types.Value)] = []
  guard json is Array(arr) else { return result }
  for item in arr {
    guard item is Array(pair) && pair.length() >= 2 && pair[0] is String(key) else {
      continue
    }
    result.push((key, json_to_value(pair[1])))
  }
  result
}

///|
fn parse_known_peers(s : String) -> Map[@types.PeerId, Int] {
  let result : Map[@types.PeerId, Int] = Map::new()
  let json = try! @json.parse(s)
  guard json is Object(obj) else { return result }
  for key, val in obj {
    guard val is Number(n, ..) else { continue }
    result[@types.PeerId(key)] = n.to_int()
  }
  result
}

// --- Ephemeral Layer API ---

///|
/// Set an ephemeral value. Returns the entry as JSON.
pub fn ephemeral_set(
  handle : Int,
  ns : String,
  key : String,
  value_json : String,
  timestamp : Double,
) -> String {
  let store = ephemeral_stores[handle]
  let @types.PeerId(peer_str) = docs[handle].peer_id
  let peer = @types.PeerId(peer_str)
  let value = parse_value(value_json)
  store.set(ns, key, value, timestamp, peer)
  ephemeral_entry_to_json(
    key,
    { value, timestamp, peer },
  ).stringify()
}

///|
/// Get a single ephemeral entry. Returns JSON or "null".
pub fn ephemeral_get(handle : Int, ns : String, key : String) -> String {
  let store = ephemeral_stores[handle]
  match store.get(ns, key) {
    Some(entry) => ephemeral_entry_to_json(key, entry).stringify()
    None => "null"
  }
}

///|
/// Get all entries in a namespace. Returns JSON object.
pub fn ephemeral_get_all(handle : Int, ns : String) -> String {
  let store = ephemeral_stores[handle]
  let entries = store.get_all(ns)
  let result : Map[String, Json] = Map::new()
  for k, entry in entries {
    result[k] = ephemeral_entry_to_json(k, entry)
  }
  Json::object(result).stringify()
}

///|
/// Merge remote ephemeral entries. entries_json: {"ns": {"key": {value, timestamp, peer}, ...}, ...}
/// Returns JSON with changed entries only.
pub fn ephemeral_merge(handle : Int, entries_json : String) -> String {
  let store = ephemeral_stores[handle]
  let json = try! @json.parse(entries_json)
  let changed : Map[String, Json] = Map::new()
  guard json is Object(ns_map) else { return "{}".to_string() }
  for ns, ns_val in ns_map {
    guard ns_val is Object(key_map) else { continue }
    let ns_changed : Map[String, Json] = Map::new()
    for key, entry_json in key_map {
      guard entry_json is Object(obj) else { continue }
      let value = json_to_value(obj.get("value").unwrap_or(Json::null()))
      guard obj["timestamp"] is Number(ts, ..) else { continue }
      guard obj["peer"] is String(peer_str) else { continue }
      let entry : @ephemeral.EphemeralEntry = {
        value,
        timestamp: ts,
        peer: @types.PeerId(peer_str),
      }
      if store.merge(ns, key, entry) {
        ns_changed[key] = ephemeral_entry_to_json(key, entry)
      }
    }
    if ns_changed.length() > 0 {
      changed[ns] = Json::object(ns_changed)
    }
  }
  Json::object(changed).stringify()
}

///|
fn ephemeral_entry_to_json(
  key : String,
  entry : @ephemeral.EphemeralEntry,
) -> Json {
  let @types.PeerId(peer_str) = entry.peer
  Json::object({
    "key": Json::string(key),
    "value": value_to_json(entry.value),
    "timestamp": Json::number(entry.timestamp),
    "peer": Json::string(peer_str),
  })
}
