///|
/// Pure trust-fact gate used by the runtime package before it mints an opaque
/// epoch-closure capability.
pub fn runtime_epoch_closure_facts_valid(
  frontier_complete : Bool,
  conflict_free : Bool,
  quorum_satisfied : Bool,
) -> Bool where {
  proof_ensure: result => {
    runtime_epoch_closure_facts_valid_post(
      frontier_complete, conflict_free, quorum_satisfied, result,
    )
  },
} {
  let result = frontier_complete && conflict_free && quorum_satisfied
  proof_assert runtime_epoch_closure_facts_valid_post(
    frontier_complete, conflict_free, quorum_satisfied, result,
  )
  result
}

///|
/// Pure fail-closed ACK gate. Storage mutation and concrete identities remain
/// in the runtime adapter; this predicate fixes the required conjunction.
pub fn runtime_checkpoint_ack_completion_allowed(
  authority_matches : Bool,
  boundary_matches : Bool,
  epoch_matches : Bool,
  digest_matches : Bool,
  accepted : Bool,
  duplicate : Bool,
) -> Bool where {
  proof_ensure: result => {
    runtime_checkpoint_ack_completion_allowed_post(
      authority_matches, boundary_matches, epoch_matches, digest_matches, accepted,
      duplicate, result,
    )
  },
} {
  let result = authority_matches &&
    boundary_matches &&
    epoch_matches &&
    digest_matches &&
    (accepted || duplicate)
  proof_assert runtime_checkpoint_ack_completion_allowed_post(
    authority_matches, boundary_matches, epoch_matches, digest_matches, accepted,
    duplicate, result,
  )
  result
}

///|
/// Pure fail-closed gate used after the concrete game adapter has checked the
/// producer signature and every roster-bound witness approval.
pub fn runtime_checkpoint_delivery_authentication_allowed(
  statement_valid : Bool,
  policy_valid : Bool,
  producer_identity_matches : Bool,
  producer_signature_valid : Bool,
  roster_valid : Bool,
  quorum_satisfied : Bool,
) -> Bool where {
  proof_ensure: result => {
    runtime_checkpoint_delivery_authentication_allowed_post(
      statement_valid, policy_valid, producer_identity_matches, producer_signature_valid,
      roster_valid, quorum_satisfied, result,
    )
  },
} {
  let result = statement_valid &&
    policy_valid &&
    producer_identity_matches &&
    producer_signature_valid &&
    roster_valid &&
    quorum_satisfied
  proof_assert runtime_checkpoint_delivery_authentication_allowed_post(
    statement_valid, policy_valid, producer_identity_matches, producer_signature_valid,
    roster_valid, quorum_satisfied, result,
  )
  result
}

///|
/// Pure conjunction behind an atomic checkpoint-seal plan. Concrete storage
/// reads and writes stay in `audit/runtime`; this gate fixes the facts that
/// every successfully prepared write set must preserve.
pub fn runtime_atomic_seal_advance_allowed(
  boundary_matches : Bool,
  closure_epoch_matches : Bool,
  closure_available : Bool,
  exact_next : Bool,
  parent_matches : Bool,
  destinations_valid : Bool,
  capacity_available : Bool,
  created_order_available : Bool,
) -> Bool where {
  proof_ensure: result => {
    runtime_atomic_seal_advance_allowed_post(
      boundary_matches, closure_epoch_matches, closure_available, exact_next, parent_matches,
      destinations_valid, capacity_available, created_order_available, result,
    )
  },
} {
  let result = boundary_matches &&
    closure_epoch_matches &&
    closure_available &&
    exact_next &&
    parent_matches &&
    destinations_valid &&
    capacity_available &&
    created_order_available
  proof_assert runtime_atomic_seal_advance_allowed_post(
    boundary_matches, closure_epoch_matches, closure_available, exact_next, parent_matches,
    destinations_valid, capacity_available, created_order_available, result,
  )
  result
}
