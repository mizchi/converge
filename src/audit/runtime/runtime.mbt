///|
/// Stable trust boundary shared by closures, checkpoints, outbox entries, and
/// acknowledgments. Game-specific payloads stay outside this contract.
pub(all) struct AuditBoundary {
  protocol_version : Int
  purpose : String
  manifest_digest : @commitment.AuditDigest
  scope_id : String
  unit_id : String
} derive(Eq, Debug)

///|
/// Game-adapter evidence from which the generic runtime may mint a trusted
/// epoch-closure capability.
pub(all) struct EpochClosureEvidence {
  boundary : AuditBoundary
  epoch : Int
  roster_digest : @commitment.AuditDigest
  frontier_digest : @commitment.AuditDigest
  certificate_digest : @commitment.AuditDigest
} derive(Eq, Debug)

///|
pub(all) enum EpochClosureRefusal {
  NonPositiveProtocolVersion
  EmptyPurpose
  EmptyManifestDigest
  EmptyScopeId
  EmptyUnitId
  NegativeClosureEpoch
  EmptyRosterDigest
  EmptyFrontierDigest
  EmptyCertificateDigest
} derive(Eq, Debug)

///|
pub(all) enum EpochClosurePendingReason {
  MissingFrontierEvents
  UnderQuorum
} derive(Eq, Debug)

///|
pub(all) enum EpochClosureConflictReason {
  EquivocationDetected
} derive(Eq, Debug)

///|
/// Opaque proof token. Only `open_trusted_epoch_closure` can construct it.
pub struct TrustedEpochClosure {
  evidence_value : EpochClosureEvidence
} derive(Eq, Debug)

///|
pub(all) enum EpochClosureOpenResult {
  EpochClosureReady(TrustedEpochClosure)
  EpochClosurePending(EpochClosurePendingReason)
  EpochClosureConflict(EpochClosureConflictReason)
  EpochClosureRefused(EpochClosureRefusal)
} derive(Eq, Debug)

///|
fn boundary_valid(boundary : AuditBoundary) -> Bool {
  boundary.protocol_version > 0 &&
  boundary.purpose != "" &&
  boundary.manifest_digest.0 != "" &&
  boundary.scope_id != "" &&
  boundary.unit_id != ""
}

///|
fn classify_closure_structure(
  evidence : EpochClosureEvidence,
) -> EpochClosureRefusal? {
  if evidence.boundary.protocol_version <= 0 {
    Some(NonPositiveProtocolVersion)
  } else if evidence.boundary.purpose == "" {
    Some(EmptyPurpose)
  } else if evidence.boundary.manifest_digest.0 == "" {
    Some(EmptyManifestDigest)
  } else if evidence.boundary.scope_id == "" {
    Some(EmptyScopeId)
  } else if evidence.boundary.unit_id == "" {
    Some(EmptyUnitId)
  } else if evidence.epoch < 0 {
    Some(NegativeClosureEpoch)
  } else if evidence.roster_digest.0 == "" {
    Some(EmptyRosterDigest)
  } else if evidence.frontier_digest.0 == "" {
    Some(EmptyFrontierDigest)
  } else if evidence.certificate_digest.0 == "" {
    Some(EmptyCertificateDigest)
  } else {
    None
  }
}

///|
/// Mint a closure only after the trusted game adapter reports a complete
/// contiguous frontier, no conflict, and its mode-specific quorum.
///
/// Structural refusal is evaluated first. A detected conflict dominates
/// missing evidence because callers must not present it as a mere timeout.
pub fn open_trusted_epoch_closure(
  evidence : EpochClosureEvidence,
  frontier_complete~ : Bool,
  conflict_free~ : Bool,
  quorum_satisfied~ : Bool,
) -> EpochClosureOpenResult {
  match classify_closure_structure(evidence) {
    Some(reason) => EpochClosureRefused(reason)
    None =>
      if !conflict_free {
        EpochClosureConflict(EquivocationDetected)
      } else if !frontier_complete {
        EpochClosurePending(MissingFrontierEvents)
      } else if !quorum_satisfied {
        EpochClosurePending(UnderQuorum)
      } else if @audit.runtime_epoch_closure_facts_valid(
          frontier_complete, conflict_free, quorum_satisfied,
        ) {
        EpochClosureReady(TrustedEpochClosure::{ evidence_value: evidence })
      } else {
        abort("epoch closure fact validator diverged")
      }
  }
}

///|
pub fn TrustedEpochClosure::evidence(
  self : TrustedEpochClosure,
) -> EpochClosureEvidence {
  self.evidence_value
}

///|
pub fn TrustedEpochClosure::epoch(self : TrustedEpochClosure) -> Int {
  self.evidence_value.epoch
}

///|
pub(all) enum CheckpointOutboxState {
  OutboxPending
  OutboxInFlight(Int)
  OutboxAcknowledgedState
} derive(Eq, Debug)

///|
/// Opaque outbox record. A storage adapter serializes this value and performs
/// transaction/CAS; the transition logic remains pure.
pub struct CheckpointOutboxEntry {
  boundary_value : AuditBoundary
  destination_id_value : String
  epoch_value : Int
  checkpoint_digest_value : @commitment.AuditDigest
  canonical_envelope_value : String
  created_order_value : Int
  state_value : CheckpointOutboxState
} derive(Eq, Debug)

///|
pub(all) enum OutboxEntryRefusal {
  InvalidOutboxBoundary
  EmptyDestinationId
  NegativeCheckpointEpoch
  EmptyCheckpointDigest
  EmptyCanonicalEnvelope
  NegativeCreatedOrder
} derive(Eq, Debug)

///|
pub(all) enum CheckpointOutboxOpenResult {
  OutboxEntryReady(CheckpointOutboxEntry)
  OutboxEntryRefused(OutboxEntryRefusal)
} derive(Eq, Debug)

///|
pub fn open_checkpoint_outbox_entry(
  boundary~ : AuditBoundary,
  destination_id~ : String,
  epoch~ : Int,
  checkpoint_digest~ : @commitment.AuditDigest,
  canonical_envelope~ : String,
  created_order~ : Int,
) -> CheckpointOutboxOpenResult {
  if !boundary_valid(boundary) {
    OutboxEntryRefused(InvalidOutboxBoundary)
  } else if destination_id == "" {
    OutboxEntryRefused(EmptyDestinationId)
  } else if epoch < 0 {
    OutboxEntryRefused(NegativeCheckpointEpoch)
  } else if checkpoint_digest.0 == "" {
    OutboxEntryRefused(EmptyCheckpointDigest)
  } else if canonical_envelope == "" {
    OutboxEntryRefused(EmptyCanonicalEnvelope)
  } else if created_order < 0 {
    OutboxEntryRefused(NegativeCreatedOrder)
  } else {
    OutboxEntryReady(CheckpointOutboxEntry::{
      boundary_value: boundary,
      destination_id_value: destination_id,
      epoch_value: epoch,
      checkpoint_digest_value: checkpoint_digest,
      canonical_envelope_value: canonical_envelope,
      created_order_value: created_order,
      state_value: OutboxPending,
    })
  }
}

///|
pub fn CheckpointOutboxEntry::boundary(
  self : CheckpointOutboxEntry,
) -> AuditBoundary {
  self.boundary_value
}

///|
pub fn CheckpointOutboxEntry::destination_id(
  self : CheckpointOutboxEntry,
) -> String {
  self.destination_id_value
}

///|
pub fn CheckpointOutboxEntry::epoch(self : CheckpointOutboxEntry) -> Int {
  self.epoch_value
}

///|
pub fn CheckpointOutboxEntry::checkpoint_digest(
  self : CheckpointOutboxEntry,
) -> @commitment.AuditDigest {
  self.checkpoint_digest_value
}

///|
pub fn CheckpointOutboxEntry::canonical_envelope(
  self : CheckpointOutboxEntry,
) -> String {
  self.canonical_envelope_value
}

///|
pub fn CheckpointOutboxEntry::created_order(
  self : CheckpointOutboxEntry,
) -> Int {
  self.created_order_value
}

///|
pub fn CheckpointOutboxEntry::state(
  self : CheckpointOutboxEntry,
) -> CheckpointOutboxState {
  self.state_value
}

///|
fn CheckpointOutboxEntry::with_state(
  self : CheckpointOutboxEntry,
  state : CheckpointOutboxState,
) -> CheckpointOutboxEntry {
  CheckpointOutboxEntry::{
    boundary_value: self.boundary_value,
    destination_id_value: self.destination_id_value,
    epoch_value: self.epoch_value,
    checkpoint_digest_value: self.checkpoint_digest_value,
    canonical_envelope_value: self.canonical_envelope_value,
    created_order_value: self.created_order_value,
    state_value: state,
  }
}

///|
pub(all) enum OutboxClaimRefusal {
  NegativeClaimTime
  NonPositiveLeaseDuration
  LeaseDeadlineOverflow
} derive(Eq, Debug)

///|
pub(all) enum CheckpointOutboxClaimResult {
  OutboxClaimed(CheckpointOutboxEntry)
  OutboxNotRetryable
  OutboxClaimRefused(OutboxClaimRefusal)
} derive(Eq, Debug)

///|
fn outbox_retryable_at(entry : CheckpointOutboxEntry, now_ms : Int) -> Bool {
  match entry.state_value {
    OutboxPending => true
    OutboxInFlight(lease_expires_at_ms) => lease_expires_at_ms <= now_ms
    OutboxAcknowledgedState => false
  }
}

///|
/// Claim a pending entry, or reclaim an expired in-flight lease. The returned
/// value must be persisted with CAS before its bytes are sent.
pub fn claim_checkpoint_outbox(
  entry : CheckpointOutboxEntry,
  now_ms~ : Int,
  lease_duration_ms~ : Int,
) -> CheckpointOutboxClaimResult {
  if now_ms < 0 {
    return OutboxClaimRefused(NegativeClaimTime)
  }
  if lease_duration_ms <= 0 {
    return OutboxClaimRefused(NonPositiveLeaseDuration)
  }
  if !outbox_retryable_at(entry, now_ms) {
    return OutboxNotRetryable
  }
  let lease_expires_at_ms = now_ms + lease_duration_ms
  if lease_expires_at_ms < now_ms {
    return OutboxClaimRefused(LeaseDeadlineOverflow)
  }
  OutboxClaimed(entry.with_state(OutboxInFlight(lease_expires_at_ms)))
}

///|
pub(all) enum CheckpointOutboxReleaseResult {
  OutboxReleased(CheckpointOutboxEntry)
  OutboxReleaseNoop
} derive(Eq, Debug)

///|
/// Return an in-flight entry to pending after an explicit transport failure.
/// Expired leases are also reclaimable directly by `claim_checkpoint_outbox`.
pub fn release_checkpoint_outbox(
  entry : CheckpointOutboxEntry,
) -> CheckpointOutboxReleaseResult {
  match entry.state_value {
    OutboxInFlight(_) => OutboxReleased(entry.with_state(OutboxPending))
    OutboxPending | OutboxAcknowledgedState => OutboxReleaseNoop
  }
}

///|
pub(all) enum RetrySelectionRefusal {
  NegativeSelectionTime
  InvalidSelectionBoundary
  EmptySelectionDestination
} derive(Eq, Debug)

///|
pub(all) enum RetrySelectionResult {
  RetrySelected(Int)
  NoRetryableCheckpoint
  RetrySelectionRefused(RetrySelectionRefusal)
} derive(Eq, Debug)

///|
fn outbox_precedes(
  left : CheckpointOutboxEntry,
  right : CheckpointOutboxEntry,
) -> Bool {
  if left.epoch_value != right.epoch_value {
    left.epoch_value < right.epoch_value
  } else if left.created_order_value != right.created_order_value {
    left.created_order_value < right.created_order_value
  } else {
    left.checkpoint_digest_value.0.compare(right.checkpoint_digest_value.0) < 0
  }
}

///|
/// Select the oldest retryable checkpoint for exactly one scope/destination.
/// Array order never decides which epoch wins.
pub fn select_oldest_retryable_checkpoint(
  entries : Array[CheckpointOutboxEntry],
  boundary~ : AuditBoundary,
  destination_id~ : String,
  now_ms~ : Int,
) -> RetrySelectionResult {
  if now_ms < 0 {
    return RetrySelectionRefused(NegativeSelectionTime)
  }
  if !boundary_valid(boundary) {
    return RetrySelectionRefused(InvalidSelectionBoundary)
  }
  if destination_id == "" {
    return RetrySelectionRefused(EmptySelectionDestination)
  }
  let mut selected_index = -1
  for index = 0; index < entries.length(); index = index + 1 {
    let candidate = entries[index]
    if candidate.boundary_value == boundary &&
      candidate.destination_id_value == destination_id &&
      outbox_retryable_at(candidate, now_ms) &&
      (
        selected_index < 0 ||
        outbox_precedes(candidate, entries[selected_index])
      ) {
      selected_index = index
    }
  }
  if selected_index < 0 {
    NoRetryableCheckpoint
  } else {
    RetrySelected(selected_index)
  }
}

///|
pub(all) enum CheckpointAckDecision {
  CheckpointAccepted
  CheckpointDuplicate
  CheckpointGap
  CheckpointSameEpochFork
  CheckpointParentFork
  CheckpointStaleUnknown
  CheckpointBoundaryMismatch
  CheckpointRefused
} derive(Eq, Debug)

///|
pub(all) enum OutboxAckRefusal {
  AckAuthorityMismatch
  AckBoundaryMismatch
  AckEpochMismatch
  AckDigestMismatch
  AckDecisionNotSuccessful
} derive(Eq, Debug)

///|
/// Raw canonical ACK fields before signature or channel authentication.
pub(all) struct CheckpointAckEvidence {
  boundary : AuditBoundary
  authority_id : String
  epoch : Int
  checkpoint_digest : @commitment.AuditDigest
  decision : CheckpointAckDecision
} derive(Eq, Debug)

///|
/// Opaque ACK capability. The transport adapter must authenticate the raw
/// evidence before it can cross this boundary.
pub struct AuthenticatedCheckpointAck {
  evidence_value : CheckpointAckEvidence
} derive(Eq, Debug)

///|
pub(all) enum CheckpointAckRefusal {
  InvalidAckBoundary
  EmptyAckAuthorityId
  NegativeAckEpoch
  EmptyAckDigest
  AckAuthenticationFailed
} derive(Eq, Debug)

///|
pub(all) enum CheckpointAckOpenResult {
  CheckpointAckReady(AuthenticatedCheckpointAck)
  CheckpointAckRefused(CheckpointAckRefusal)
} derive(Eq, Debug)

///|
pub fn open_authenticated_checkpoint_ack(
  evidence : CheckpointAckEvidence,
  authentication_succeeded~ : Bool,
) -> CheckpointAckOpenResult {
  if !boundary_valid(evidence.boundary) {
    CheckpointAckRefused(InvalidAckBoundary)
  } else if evidence.authority_id == "" {
    CheckpointAckRefused(EmptyAckAuthorityId)
  } else if evidence.epoch < 0 {
    CheckpointAckRefused(NegativeAckEpoch)
  } else if evidence.checkpoint_digest.0 == "" {
    CheckpointAckRefused(EmptyAckDigest)
  } else if !authentication_succeeded {
    CheckpointAckRefused(AckAuthenticationFailed)
  } else {
    CheckpointAckReady(AuthenticatedCheckpointAck::{ evidence_value: evidence })
  }
}

///|
/// Persistable evidence after the transport adapter has authenticated it.
pub fn AuthenticatedCheckpointAck::evidence(
  self : AuthenticatedCheckpointAck,
) -> CheckpointAckEvidence {
  self.evidence_value
}

///|
pub(all) enum CheckpointOutboxAckResult {
  OutboxAcknowledged(CheckpointOutboxEntry)
  OutboxAlreadyAcknowledged
  OutboxAckRefused(OutboxAckRefusal)
} derive(Eq, Debug)

///|
/// Complete an outbox entry only for an exact authenticated Accepted or
/// historical Duplicate ACK. All refusals preserve the original entry.
pub fn acknowledge_checkpoint_outbox(
  entry : CheckpointOutboxEntry,
  ack : AuthenticatedCheckpointAck,
) -> CheckpointOutboxAckResult {
  let evidence = ack.evidence_value
  let authority_matches = evidence.authority_id == entry.destination_id_value
  let boundary_matches = evidence.boundary == entry.boundary_value
  let epoch_matches = evidence.epoch == entry.epoch_value
  let digest_matches = evidence.checkpoint_digest ==
    entry.checkpoint_digest_value
  let accepted = evidence.decision == CheckpointAccepted
  let duplicate = evidence.decision == CheckpointDuplicate
  if !authority_matches {
    return OutboxAckRefused(AckAuthorityMismatch)
  }
  if !boundary_matches {
    return OutboxAckRefused(AckBoundaryMismatch)
  }
  if !epoch_matches {
    return OutboxAckRefused(AckEpochMismatch)
  }
  if !digest_matches {
    return OutboxAckRefused(AckDigestMismatch)
  }
  if !@audit.runtime_checkpoint_ack_completion_allowed(
      authority_matches, boundary_matches, epoch_matches, digest_matches, accepted,
      duplicate,
    ) {
    return OutboxAckRefused(AckDecisionNotSuccessful)
  }
  if entry.state_value == OutboxAcknowledgedState {
    return OutboxAlreadyAcknowledged
  }
  OutboxAcknowledged(entry.with_state(OutboxAcknowledgedState))
}
