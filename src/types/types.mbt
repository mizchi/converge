///|
/// Unique identifier for a peer (node) in the distributed system.
/// Used in both the Durable Layer (event authorship) and the Ephemeral Layer
/// (LWW tiebreaking).
pub(all) struct PeerId(String) derive(Eq, Compare, Hash, Show)

///|
/// Globally unique event identifier: (peer, counter) pair.
/// Each peer maintains a monotonically increasing counter.
pub(all) struct EventId {
  peer : PeerId
  counter : Int
} derive(Eq, Compare, Hash, Show)

///|
/// Lightweight JSON-like value for DB cell contents.
/// Kept intentionally flat (no nested objects/arrays) to simplify
/// conflict resolution at the column level.
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int)
  Float(Double)
  Str(String)
} derive(Eq, Show)

///|
/// Row-level operation in the Durable Layer.
/// Insert creates a row with initial column values,
/// Update modifies a single column, Delete removes the entire row.
pub(all) enum RowOp {
  Insert(tbl~ : String, row_id~ : String, values~ : Array[(String, Value)])
  Update(tbl~ : String, row_id~ : String, col~ : String, value~ : Value)
  Delete(tbl~ : String, row_id~ : String)
} derive(Show, Eq)

///|
/// A single event in the causal event graph (Durable Layer).
/// Carries its causal dependencies (deps) and a Lamport timestamp
/// for total ordering during conflict resolution.
pub(all) struct Event {
  id : EventId
  deps : Array[EventId]
  lamport : Int
  op : RowOp
} derive(Show, Eq)

///|
/// Run-length encoded consecutive events from the same peer.
/// Used for efficient network transfer and storage — consecutive
/// same-peer events with sequential counters/lamport are compressed
/// into a single run.
pub(all) struct EventRun {
  peer : PeerId
  counter_start : Int
  lamport_start : Int
  deps : Array[EventId]
  ops : Array[RowOp]
} derive(Show, Eq)
