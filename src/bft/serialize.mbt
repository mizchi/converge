///|
/// Canonical, length-prefixed serialization of an event for hash computation.
/// Collections whose order is not semantically relevant are sorted first.
pub fn serialize_for_hash(
  session_id : String,
  event : @types.Event,
  dep_hashes : Array[Digest],
) -> String {
  let buf = StringBuilder::new()
  write_text(buf, "event-v2")
  write_text(buf, session_id)
  write_event_id(buf, event.id)
  write_int(buf, event.lamport)
  write_dependencies(buf, event.deps, dep_hashes)
  serialize_op(buf, event.op)
  buf.to_string()
}

///|
fn write_text(buf : StringBuilder, value : String) -> Unit {
  buf.write_string(value.length().to_string())
  buf.write_char(':')
  buf.write_string(value)
}

///|
fn write_int(buf : StringBuilder, value : Int) -> Unit {
  write_text(buf, value.to_string())
}

///|
fn write_event_id(buf : StringBuilder, id : @types.EventId) -> Unit {
  write_text(buf, id.peer.0)
  write_int(buf, id.counter)
}

///|
fn compare_event_id(a : @types.EventId, b : @types.EventId) -> Int {
  let peer_order = a.peer.0.compare(b.peer.0)
  if peer_order == 0 {
    a.counter.compare(b.counter)
  } else {
    peer_order
  }
}

///|
fn write_dependencies(
  buf : StringBuilder,
  event_dependencies : Array[@types.EventId],
  digest_dependencies : Array[Digest],
) -> Unit {
  buf.write_char('D')
  write_int(buf, event_dependencies.length())
  write_int(buf, digest_dependencies.length())
  if event_dependencies.length() == digest_dependencies.length() {
    let pairs : Array[(@types.EventId, Digest)] = []
    for i, dependency in event_dependencies {
      pairs.push((dependency, digest_dependencies[i]))
    }
    if pairs.length() > 1 {
      pairs.sort_by(fn(a, b) {
        let id_order = compare_event_id(a.0, b.0)
        if id_order == 0 {
          a.1.0.compare(b.1.0)
        } else {
          id_order
        }
      })
    }
    for pair in pairs {
      write_event_id(buf, pair.0)
      write_text(buf, pair.1.0)
    }
  } else {
    // Preserve malformed inputs in the digest; delivery rejects the count mismatch.
    let sorted_events = event_dependencies.copy()
    sorted_events.sort_by(compare_event_id)
    for dependency in sorted_events {
      write_event_id(buf, dependency)
    }
    let sorted_digests = digest_dependencies.copy()
    sorted_digests.sort_by(fn(a, b) { a.0.compare(b.0) })
    for dependency in sorted_digests {
      write_text(buf, dependency.0)
    }
  }
}

///|
fn serialize_op(buf : StringBuilder, op : @types.RowOp) -> Unit {
  match op {
    Insert(tbl~, row_id~, values~) => {
      buf.write_char('I')
      write_text(buf, tbl)
      write_text(buf, row_id)
      write_int(buf, values.length())
      let sorted_values = values.copy()
      if sorted_values.length() > 1 {
        sorted_values.sort_by(fn(a, b) { a.0.compare(b.0) })
      }
      for pair in sorted_values {
        write_text(buf, pair.0)
        serialize_value(buf, pair.1)
      }
    }
    Update(tbl~, row_id~, col~, value~) => {
      buf.write_char('U')
      write_text(buf, tbl)
      write_text(buf, row_id)
      write_text(buf, col)
      serialize_value(buf, value)
    }
    Delete(tbl~, row_id~) => {
      buf.write_char('D')
      write_text(buf, tbl)
      write_text(buf, row_id)
    }
  }
}

///|
fn serialize_value(buf : StringBuilder, value : @types.Value) -> Unit {
  match value {
    Null => buf.write_char('N')
    Bool(b) => {
      buf.write_char('B')
      buf.write_char(if b { '1' } else { '0' })
    }
    Int(n) => {
      buf.write_char('I')
      write_int(buf, n)
    }
    Float(f) => {
      buf.write_char('F')
      write_text(buf, f.to_string())
    }
    Str(s) => {
      buf.write_char('S')
      write_text(buf, s)
    }
  }
}
