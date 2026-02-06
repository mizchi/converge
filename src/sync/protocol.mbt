///|
/// Push request: client sends events to server
pub(all) struct PushRequest {
  peer_id : @types.PeerId
  events : Array[@types.EventRun]
  frontier : Array[@types.EventId]
} derive(Show)

///|
/// Pull request: client asks for events after known state
pub(all) struct PullRequest {
  peer_id : @types.PeerId
  known_peers : Map[@types.PeerId, Int]
} derive(Show)

///|
/// Pull response: server returns events and its frontier
pub(all) struct PullResponse {
  events : Array[@types.EventRun]
  server_frontier : Array[@types.EventId]
  has_more : Bool
} derive(Show)
