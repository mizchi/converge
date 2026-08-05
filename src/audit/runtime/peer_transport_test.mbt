///|
fn peer_route(
  peer_id : String,
  last_attempt_order : Int,
  next_retry_at_ms? : Int = 0,
  failures? : Int = 0,
  available? : Bool = true,
  quarantined? : Bool = false,
) -> PeerRouteState {
  {
    peer_id,
    available,
    quarantined,
    failures,
    next_retry_at_ms,
    last_attempt_order,
  }
}

///|
test "peer delivery selects a bounded fair batch and reports backpressure" {
  let routes = [
    peer_route("newest", 30),
    peer_route("oldest", 10),
    peer_route("middle", 20),
    peer_route("sleeping", 0, next_retry_at_ms=101),
    peer_route("quarantined", 0, quarantined=true),
  ]
  debug_inspect(
    select_peer_delivery_batch(
      routes,
      now_ms=100,
      in_flight_count=1,
      max_in_flight=3,
      max_parallel=3,
    ),
    content="PeerDeliverySelected([1, 2])",
  )
  debug_inspect(
    select_peer_delivery_batch(
      routes,
      now_ms=100,
      in_flight_count=3,
      max_in_flight=3,
      max_parallel=2,
    ),
    content="PeerDeliveryBackpressured",
  )
}

///|
test "peer delivery rejects duplicate identities and invalid limits" {
  debug_inspect(
    select_peer_delivery_batch(
      [peer_route("peer", 0), peer_route("peer", 1)],
      now_ms=0,
      in_flight_count=0,
      max_in_flight=1,
      max_parallel=1,
    ),
    content="PeerDeliveryRefused(DuplicatePeerRoute)",
  )
  debug_inspect(
    select_peer_delivery_batch(
      [],
      now_ms=-1,
      in_flight_count=0,
      max_in_flight=1,
      max_parallel=1,
    ),
    content="PeerDeliveryRefused(InvalidPeerDeliveryWindow)",
  )
}

///|
test "peer response selection ignores unauthenticated data and surfaces signed forks" {
  let expected = @commitment.AuditDigest("checkpoint")
  debug_inspect(
    select_peer_checkpoint_response(
      [
        {
          peer_id: "slow",
          checkpoint_digest: expected,
          authenticated: true,
          received_at_ms: 20,
        },
        {
          peer_id: "attacker",
          checkpoint_digest: @commitment.AuditDigest("forged"),
          authenticated: false,
          received_at_ms: 1,
        },
        {
          peer_id: "fast",
          checkpoint_digest: expected,
          authenticated: true,
          received_at_ms: 10,
        },
      ],
      expected_digest=expected,
    ),
    content="PeerCheckpointResponseAccepted(2)",
  )
  debug_inspect(
    select_peer_checkpoint_response(
      [
        {
          peer_id: "honest",
          checkpoint_digest: expected,
          authenticated: true,
          received_at_ms: 10,
        },
        {
          peer_id: "forking-peer",
          checkpoint_digest: @commitment.AuditDigest("other-checkpoint"),
          authenticated: true,
          received_at_ms: 11,
        },
      ],
      expected_digest=expected,
    ),
    content="PeerCheckpointForkDetected(1)",
  )
}

///|
test "peer retry transition persists bounded exponential backoff and resets on success" {
  let initial = peer_route("peer", 0)
  let first = match
    record_peer_delivery_failure(
      initial,
      now_ms=100,
      attempt_order=1,
      base_backoff_ms=10,
      max_backoff_ms=100,
    ) {
    PeerRouteUpdated(route) => route
    PeerRouteUpdateRefused => abort("valid first failure was refused")
  }
  assert_eq(first, {
    peer_id: "peer",
    available: true,
    quarantined: false,
    failures: 1,
    next_retry_at_ms: 110,
    last_attempt_order: 1,
  })
  let second = match
    record_peer_delivery_failure(
      first,
      now_ms=110,
      attempt_order=2,
      base_backoff_ms=10,
      max_backoff_ms=100,
    ) {
    PeerRouteUpdated(route) => route
    PeerRouteUpdateRefused => abort("valid second failure was refused")
  }
  inspect(second.next_retry_at_ms, content="130")
  debug_inspect(
    record_peer_delivery_success(second, attempt_order=3),
    content=(
      #|PeerRouteUpdated(
      #|  {
      #|    peer_id: "peer",
      #|    available: true,
      #|    quarantined: false,
      #|    failures: 0,
      #|    next_retry_at_ms: 0,
      #|    last_attempt_order: 3,
      #|  },
      #|)
    ),
  )
}
