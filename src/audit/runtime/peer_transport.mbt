///|
/// Persisted scheduler state for one peer route. `last_attempt_order` is a
/// logical monotonic counter, so selection does not depend on array order.
/// Millisecond values are relative to the audit unit's persisted clock origin;
/// callers must not pass an unbounded Unix millisecond timestamp to `Int`.
pub(all) struct PeerRouteState {
  peer_id : String
  available : Bool
  quarantined : Bool
  failures : Int
  next_retry_at_ms : Int
  last_attempt_order : Int
} derive(Eq, Debug)

///|
pub(all) enum PeerDeliveryRefusal {
  InvalidPeerDeliveryWindow
  InvalidPeerRoute(Int)
  DuplicatePeerRoute
} derive(Eq, Debug)

///|
pub(all) enum PeerDeliverySelectionResult {
  PeerDeliverySelected(Array[Int])
  PeerDeliveryUnavailable
  PeerDeliveryBackpressured
  PeerDeliveryRefused(PeerDeliveryRefusal)
} derive(Eq, Debug)

///|
pub(all) enum PeerRouteUpdateResult {
  PeerRouteUpdated(PeerRouteState)
  PeerRouteUpdateRefused
} derive(Eq, Debug)

///|
fn peer_route_valid(route : PeerRouteState) -> Bool {
  route.peer_id != "" &&
  route.failures >= 0 &&
  route.next_retry_at_ms >= 0 &&
  route.last_attempt_order >= 0
}

///|
fn peer_route_precedes(left : PeerRouteState, right : PeerRouteState) -> Bool {
  if left.last_attempt_order != right.last_attempt_order {
    left.last_attempt_order < right.last_attempt_order
  } else if left.failures != right.failures {
    left.failures < right.failures
  } else {
    left.peer_id.compare(right.peer_id) < 0
  }
}

///|
/// Select a bounded fanout window using persisted least-recently-attempted
/// order. Socket creation and mutation of route state remain adapter concerns.
pub fn select_peer_delivery_batch(
  routes : Array[PeerRouteState],
  now_ms~ : Int,
  in_flight_count~ : Int,
  max_in_flight~ : Int,
  max_parallel~ : Int,
) -> PeerDeliverySelectionResult {
  if now_ms < 0 ||
    in_flight_count < 0 ||
    max_in_flight <= 0 ||
    max_parallel <= 0 ||
    in_flight_count > max_in_flight {
    return PeerDeliveryRefused(InvalidPeerDeliveryWindow)
  }
  let seen : Map[String, Bool] = Map([])
  let eligible : Array[(Int, PeerRouteState)] = []
  for index, route in routes {
    if !peer_route_valid(route) {
      return PeerDeliveryRefused(InvalidPeerRoute(index))
    }
    if seen.contains(route.peer_id) {
      return PeerDeliveryRefused(DuplicatePeerRoute)
    }
    seen[route.peer_id] = true
    if route.available && !route.quarantined && route.next_retry_at_ms <= now_ms {
      eligible.push((index, route))
    }
  }
  let capacity = max_in_flight - in_flight_count
  if capacity == 0 {
    return PeerDeliveryBackpressured
  }
  if eligible.length() == 0 {
    return PeerDeliveryUnavailable
  }
  eligible.sort_by(fn(left, right) {
    if peer_route_precedes(left.1, right.1) {
      -1
    } else if peer_route_precedes(right.1, left.1) {
      1
    } else {
      0
    }
  })
  let limit = if capacity < max_parallel { capacity } else { max_parallel }
  let selected : Array[Int] = []
  for index = 0; index < eligible.length() && index < limit; index = index + 1 {
    selected.push(eligible[index].0)
  }
  PeerDeliverySelected(selected)
}

///|
fn bounded_exponential_backoff(
  previous_failures : Int,
  base_backoff_ms : Int,
  max_backoff_ms : Int,
) -> Int {
  let mut delay = base_backoff_ms
  let mut remaining = previous_failures
  while remaining > 0 && delay < max_backoff_ms {
    delay = if delay > max_backoff_ms / 2 { max_backoff_ms } else { delay * 2 }
    remaining -= 1
  }
  if delay > max_backoff_ms {
    max_backoff_ms
  } else {
    delay
  }
}

///|
/// Return the complete scheduler row that an adapter persists after a failed
/// attempt. Backoff is exponential but capped before multiplication overflow.
pub fn record_peer_delivery_failure(
  route : PeerRouteState,
  now_ms~ : Int,
  attempt_order~ : Int,
  base_backoff_ms~ : Int,
  max_backoff_ms~ : Int,
) -> PeerRouteUpdateResult {
  if !peer_route_valid(route) ||
    route.quarantined ||
    now_ms < 0 ||
    attempt_order <= route.last_attempt_order ||
    base_backoff_ms <= 0 ||
    max_backoff_ms < base_backoff_ms {
    return PeerRouteUpdateRefused
  }
  let delay = bounded_exponential_backoff(
    route.failures,
    base_backoff_ms,
    max_backoff_ms,
  )
  let retry_at = now_ms + delay
  if retry_at < now_ms || route.failures == 2147483647 {
    return PeerRouteUpdateRefused
  }
  PeerRouteUpdated({
    ..route,
    failures: route.failures + 1,
    next_retry_at_ms: retry_at,
    last_attempt_order: attempt_order,
  })
}

///|
pub fn record_peer_delivery_success(
  route : PeerRouteState,
  attempt_order~ : Int,
) -> PeerRouteUpdateResult {
  if !peer_route_valid(route) ||
    route.quarantined ||
    attempt_order <= route.last_attempt_order {
    return PeerRouteUpdateRefused
  }
  PeerRouteUpdated({
    ..route,
    available: true,
    failures: 0,
    next_retry_at_ms: 0,
    last_attempt_order: attempt_order,
  })
}

///|
/// Attacker-controlled response metadata after transport decoding.
pub(all) struct PeerCheckpointResponse {
  peer_id : String
  checkpoint_digest : @commitment.AuditDigest
  authenticated : Bool
  received_at_ms : Int
} derive(Eq, Debug)

///|
pub(all) enum PeerCheckpointResponseSelection {
  PeerCheckpointResponseAccepted(Int)
  PeerCheckpointResponseUnavailable
  PeerCheckpointForkDetected(Int)
  PeerCheckpointResponseRefused
} derive(Eq, Debug)

///|
/// An authenticated conflicting digest is never raced away by a faster honest
/// response. It becomes fork evidence; unauthenticated bytes are ignored.
pub fn select_peer_checkpoint_response(
  responses : Array[PeerCheckpointResponse],
  expected_digest~ : @commitment.AuditDigest,
) -> PeerCheckpointResponseSelection {
  if expected_digest.0 == "" {
    return PeerCheckpointResponseRefused
  }
  let seen : Map[String, Bool] = Map([])
  let mut selected = -1
  let mut fork_count = 0
  for index, response in responses {
    if response.peer_id == "" || response.received_at_ms < 0 {
      return PeerCheckpointResponseRefused
    }
    if seen.contains(response.peer_id) {
      return PeerCheckpointResponseRefused
    }
    seen[response.peer_id] = true
    if response.authenticated {
      if response.checkpoint_digest != expected_digest {
        fork_count += 1
      } else if selected < 0 ||
        response.received_at_ms < responses[selected].received_at_ms ||
        (
          response.received_at_ms == responses[selected].received_at_ms &&
          response.peer_id.compare(responses[selected].peer_id) < 0
        ) {
        selected = index
      }
    }
  }
  if fork_count > 0 {
    PeerCheckpointForkDetected(fork_count)
  } else if selected >= 0 {
    PeerCheckpointResponseAccepted(selected)
  } else {
    PeerCheckpointResponseUnavailable
  }
}
