///|
/// Deterministic serialization of an Event for hash computation.
/// The output is canonical: same event always produces same string.
pub fn serialize_for_hash(
  event : @types.Event,
  dep_hashes : Array[Digest],
) -> String {
  let buf = StringBuilder::new()
  // Event ID
  buf.write_string("id:")
  buf.write_string(event.id.peer.0)
  buf.write_string(":")
  buf.write_string(event.id.counter.to_string())
  buf.write_string("|")
  // Lamport
  buf.write_string("l:")
  buf.write_string(event.lamport.to_string())
  buf.write_string("|")
  // Operation
  buf.write_string("op:")
  serialize_op(buf, event.op)
  buf.write_string("|")
  // Dependency hashes (sorted for determinism; skip copy+sort for 0-1 deps)
  buf.write_string("deps:")
  if dep_hashes.length() <= 1 {
    for i, d in dep_hashes {
      if i > 0 {
        buf.write_string(",")
      }
      buf.write_string(d.0)
    }
  } else {
    let sorted_deps = dep_hashes.copy()
    sorted_deps.sort_by(fn(a, b) { a.0.compare(b.0) })
    for i, d in sorted_deps {
      if i > 0 {
        buf.write_string(",")
      }
      buf.write_string(d.0)
    }
  }
  buf.to_string()
}

///|
fn serialize_op(buf : StringBuilder, op : @types.RowOp) -> Unit {
  match op {
    Insert(tbl~, row_id~, values~) => {
      buf.write_string("I:")
      buf.write_string(tbl)
      buf.write_string(":")
      buf.write_string(row_id)
      buf.write_string(":[")
      if values.length() <= 1 {
        for i, pair in values {
          if i > 0 {
            buf.write_string(",")
          }
          buf.write_string(pair.0)
          buf.write_string("=")
          serialize_value(buf, pair.1)
        }
      } else {
        let sorted_values = values.copy()
        sorted_values.sort_by(fn(a, b) { a.0.compare(b.0) })
        for i, pair in sorted_values {
          if i > 0 {
            buf.write_string(",")
          }
          buf.write_string(pair.0)
          buf.write_string("=")
          serialize_value(buf, pair.1)
        }
      }
      buf.write_string("]")
    }
    Update(tbl~, row_id~, col~, value~) => {
      buf.write_string("U:")
      buf.write_string(tbl)
      buf.write_string(":")
      buf.write_string(row_id)
      buf.write_string(":")
      buf.write_string(col)
      buf.write_string("=")
      serialize_value(buf, value)
    }
    Delete(tbl~, row_id~) => {
      buf.write_string("D:")
      buf.write_string(tbl)
      buf.write_string(":")
      buf.write_string(row_id)
    }
  }
}

///|
fn serialize_value(buf : StringBuilder, value : @types.Value) -> Unit {
  match value {
    Null => buf.write_string("null")
    Bool(b) => buf.write_string(b.to_string())
    Int(n) => buf.write_string(n.to_string())
    Float(f) => buf.write_string(f.to_string())
    Str(s) => {
      buf.write_string("\"")
      buf.write_string(s)
      buf.write_string("\"")
    }
  }
}
