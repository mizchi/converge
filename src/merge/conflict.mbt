///|
/// Conflict grouping key: (tbl, row_id, col)
struct ConflictKey {
  tbl : String
  row_id : String
  col : String
} derive(Eq, Hash)

///|
/// Column-level LWW conflict resolution.
/// Given two concurrent events targeting the same (tbl, row_id, col),
/// the event with higher lamport wins. If lamport is equal, peer_id
/// lexicographic order breaks the tie.
pub fn resolve_lww(a : @types.Event, b : @types.Event) -> @types.Event {
  if a.lamport > b.lamport {
    a
  } else if b.lamport > a.lamport {
    b
    // Same lamport: compare peer_id lexicographically
  } else if a.id.peer.compare(b.id.peer) >= 0 {
    a
  } else {
    b
  }
}

///|
/// Extract the conflict key (tbl, row_id, col) from a RowOp.
/// For Insert, col is "" (represents all columns).
/// For Delete, col is "" (represents the whole row).
pub fn op_key(op : @types.RowOp) -> (String, String, String) {
  match op {
    Insert(tbl~, row_id~, ..) => (tbl, row_id, "")
    Update(tbl~, row_id~, col~, ..) => (tbl, row_id, col)
    Delete(tbl~, row_id~) => (tbl, row_id, "")
  }
}
