///|
/// Peer identifier
pub(all) struct PeerId(String) derive(Eq, Compare, Hash, Show)

///|
/// Event identifier: (peer, counter) pair
pub(all) struct EventId {
  peer : PeerId
  counter : Int
} derive(Eq, Compare, Hash, Show)

///|
/// Lightweight JSON-like value (DB cell value)
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int)
  Float(Double)
  Str(String)
} derive(Eq, Show)

///|
/// Row operation
pub(all) enum RowOp {
  Insert(tbl~ : String, row_id~ : String, values~ : Array[(String, Value)])
  Update(tbl~ : String, row_id~ : String, col~ : String, value~ : Value)
  Delete(tbl~ : String, row_id~ : String)
} derive(Show, Eq)

///|
/// An event in the causal graph
pub(all) struct Event {
  id : EventId
  deps : Array[EventId]
  lamport : Int
  op : RowOp
} derive(Show, Eq)

///|
/// Run-length encoded consecutive events from same peer
pub(all) struct EventRun {
  peer : PeerId
  counter_start : Int
  lamport_start : Int
  deps : Array[EventId]
  ops : Array[RowOp]
} derive(Show, Eq)
