///|
/// A delayed audit seed opened against an authority-verified epoch checkpoint.
///
/// Fields are private so callers cannot invent a sampling policy or seed that
/// was not committed before encounter anchors became known.
pub struct RevealedOpenWorldAuditEpoch {
  hasher : &@bft.Hasher
  audit_checkpoint_digest : @bft.Digest
  anchor_seal_checkpoint_digest : @bft.Digest
  eligible_anchor_root : @bft.Digest
  eligible_registry_root : @bft.Digest
  observer_manifest_digest : @bft.Digest
  registered_count : Int
  authority_key : @bft.PublicKey
  world_id : String
  epoch : Int
  seed : String
  sample_numerator : Int
  sample_denominator : Int
}

///|
pub(all) enum OpenWorldAuditEpochRefusal {
  InvalidAuditPolicy
  InvalidAuditSeed
  InvalidGameManifest
  InvalidObserverManifest
  MissingAuditSeedCommitment
  AuditSeedCommitmentMismatch
  AuditManifestMismatch
  AuditSealAuthorityMismatch
  AuditSealSessionMismatch
  AuditSealEpochMismatch
  AuditSealParentMismatch
  AuditSealManifestMismatch
  InvalidEligibleAnchorRoot
  InvalidEligibleRegistryRoot
  InvalidRegisteredCount
} derive(Eq, Debug)

///|
/// One observer's signed statement that an exact registration was visible
/// before the audit epoch was sealed.
pub(all) struct OpenWorldRegistrationObservation {
  audit_checkpoint_digest : @bft.Digest
  observer_id : String
  registration_index : Int
  encounter_digest : @bft.Digest
} derive(Eq, Debug)

///|
pub(all) struct SignedOpenWorldRegistrationObservation {
  observation : OpenWorldRegistrationObservation
  digest : @bft.Digest
  signature : @bft.Signature
  signer_key : @bft.PublicKey
} derive(Eq, Debug)

///|
/// Atomic result of reserving one `(plan, slot)` before signing.
pub(all) enum OpenWorldObserverSigningReservation {
  SigningSlotReserved
  SigningSlotAlreadyReserved(@bft.Digest)
  SigningStoreUnavailable
} derive(Eq, Debug)

///|
/// One atomically read view of an observer signing store commitment.
pub(all) struct OpenWorldObserverSigningStoreSnapshot {
  root : @bft.Digest
  size : Int
} derive(Eq, Debug)

///|
/// Persistence boundary for observer anti-equivocation state.
///
/// Production implementations must make `reserve` atomic and durable before
/// returning `SigningSlotReserved`, and read `snapshot` atomically.
pub(open) trait OpenWorldObserverSigningStore {
  fn reserve(Self, String, @bft.Digest) -> OpenWorldObserverSigningReservation
  fn snapshot(Self) -> OpenWorldObserverSigningStoreSnapshot
  fn proof(Self, String) -> @authmap.AuthMapProof?
}

///|
/// Sequential reference adapter used by tests and local single-process runs.
pub struct OpenWorldInMemoryObserverSigningStore {
  records : Map[String, @bft.Digest]
  commitment : @authmap.AuthenticatedMap
}

///|
enum OpenWorldObserverSigningStorage {
  InMemorySigningStorage(OpenWorldInMemoryObserverSigningStore)
  ExternalSigningStorage(&OpenWorldObserverSigningStore)
}

///|
/// Trusted externally anchored view used to reject exact snapshot rollback.
pub(all) struct OpenWorldObserverSigningAnchor {
  observer_id : String
  signer_key : @bft.PublicKey
  root : @bft.Digest
  size : Int
} derive(Eq, Debug)

///|
/// Opaque evidence that a trusted authority checkpoint included one exact
/// observer signing-store anchor in its domain-separated authenticated map.
pub struct PublishedOpenWorldObserverSigningAnchor {
  anchor : OpenWorldObserverSigningAnchor
  publication_checkpoint_digest : @bft.Digest
  previous_checkpoint_digest : @bft.Digest
  publisher_key : @bft.PublicKey
  log_session_id : String
  log_epoch : Int
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObserverSigningAnchorPublicationRefusal {
  InvalidObserverSigningAnchor
  ObserverSigningAnchorLogSessionMismatch
  ObserverSigningAnchorLogManifestMismatch
  ObserverSigningAnchorMembershipProofInvalid
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObserverSigningAnchorPublicationResult {
  ObserverSigningAnchorPublished(PublishedOpenWorldObserverSigningAnchor)
  ObserverSigningAnchorPublicationRefused(
    OpenWorldObserverSigningAnchorPublicationRefusal
  )
} derive(Eq, Debug)

///|
/// Network-safe representation of an observer signing anchor publication.
///
/// This is untrusted data, not a publication capability. Receivers must call
/// `open_open_world_observer_signing_anchor_envelope` before using its anchor.
pub(all) struct OpenWorldObserverSigningAnchorEnvelope {
  signed_checkpoint : @checkpoint.SignedCheckpoint
  anchor : OpenWorldObserverSigningAnchor
  membership_proof : @authmap.AuthMapProof
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObserverSigningAnchorEnvelopeRefusal {
  ObserverSigningAnchorEnvelopeCheckpointRefused(
    @checkpoint.CheckpointVerification
  )
  ObserverSigningAnchorEnvelopePublicationRefused(
    OpenWorldObserverSigningAnchorPublicationRefusal
  )
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObserverSigningAnchorEnvelopeOpenResult {
  ObserverSigningAnchorEnvelopeOpened(PublishedOpenWorldObserverSigningAnchor)
  ObserverSigningAnchorEnvelopeRefused(
    OpenWorldObserverSigningAnchorEnvelopeRefusal
  )
} derive(Eq, Debug)

///|
/// Network representation proving that one independently signed transparency
/// checkpoint published both an audit plan and its exact seal link.
pub(all) struct OpenWorldAuditTransparencyEnvelope {
  signed_checkpoint : @checkpoint.SignedCheckpoint
  audit_membership_proof : @authmap.AuthMapProof
  seal_membership_proof : @authmap.AuthMapProof
} derive(Eq, Debug)

///|
/// Opaque evidence that an authenticated transparency checkpoint included one
/// exact audit checkpoint and the seal that names it as its parent.
pub struct PublishedOpenWorldAuditTransparency {
  publication_checkpoint_digest : @bft.Digest
  previous_checkpoint_digest : @bft.Digest
  publisher_key : @bft.PublicKey
  log_session_id : String
  log_epoch : Int
  world_id : String
  audit_checkpoint_digest : @bft.Digest
  seal_checkpoint_digest : @bft.Digest
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldAuditTransparencyRefusal {
  AuditTransparencyCheckpointRefused(@checkpoint.CheckpointVerification)
  AuditTransparencyExpectedCheckpointMismatch
  AuditTransparencyAuditBoundaryMismatch
  AuditTransparencySealBoundaryMismatch
  AuditTransparencySessionMismatch
  AuditTransparencyManifestMismatch
  AuditTransparencyPlanMembershipInvalid
  AuditTransparencySealMembershipInvalid
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldAuditTransparencyOpenResult {
  AuditTransparencyOpened(PublishedOpenWorldAuditTransparency)
  AuditTransparencyRefused(OpenWorldAuditTransparencyRefusal)
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObserverSigningAnchorForkKind {
  SameEpochSigningAnchorCheckpoint
  WrongParentSigningAnchorCheckpoint
} derive(Eq, Debug)

///|
/// Opaque evidence composed only from two authority-verified anchor checkpoint
/// capabilities under the same log session and publisher.
pub struct OpenWorldObserverSigningAnchorFork {
  kind : OpenWorldObserverSigningAnchorForkKind
  log_session_id : String
  publisher_key : @bft.PublicKey
  accepted_epoch : Int
  accepted_checkpoint_digest : @bft.Digest
  observed_epoch : Int
  conflicting_checkpoint_digest : @bft.Digest
  conflicting_previous_checkpoint_digest : @bft.Digest
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObserverSigningAnchorHeadDelivery {
  SigningAnchorHeadAdvanced
  SigningAnchorHeadDuplicate
  SigningAnchorHeadForkDetected(OpenWorldObserverSigningAnchorFork)
  SigningAnchorHeadGap(Int, Int)
  SigningAnchorHeadStale
  SigningAnchorHeadBoundaryMismatch
} derive(Eq, Debug)

///|
/// Atomic result of validating an ordered gap-recovery response.
pub(all) enum OpenWorldObserverSigningAnchorHeadBatchDelivery {
  SigningAnchorHeadBatchAdvanced(Int)
  SigningAnchorHeadBatchNoChange
  SigningAnchorHeadBatchForkDetected(Int, OpenWorldObserverSigningAnchorFork)
  SigningAnchorHeadBatchGap(Int, Int, Int)
  SigningAnchorHeadBatchStale(Int, Int)
  SigningAnchorHeadBatchBoundaryMismatch(Int)
} derive(Eq, Debug)

///|
/// Request for a bounded, contiguous page after one authenticated local head.
pub(all) struct OpenWorldObserverSigningAnchorGapRequest {
  log_session_id : String
  publisher_key : @bft.PublicKey
  after_epoch : Int
  after_checkpoint_digest : @bft.Digest
  target_epoch : Int
  max_items : Int
} derive(Eq, Debug)

///|
/// Untrusted wire response. Every envelope is reopened by the receiver before
/// the head tracker is mutated.
pub(all) struct OpenWorldObserverSigningAnchorGapResponse {
  envelopes : Array[OpenWorldObserverSigningAnchorEnvelope]
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObserverSigningAnchorGapFetchResult {
  ObserverSigningAnchorGapFetched(OpenWorldObserverSigningAnchorGapResponse)
  ObserverSigningAnchorGapUnavailable
  ObserverSigningAnchorGapSourceAmbiguous(Int)
  ObserverSigningAnchorGapRequestInvalid
} derive(Eq, Debug)

///|
/// Network/storage boundary for retrieving a bounded gap page.
///
/// Implementations are not trusted to authenticate or order their response.
/// The receiver treats the response as attacker-controlled wire data.
pub(open) trait OpenWorldObserverSigningAnchorGapTransport {
  fn fetch(Self, OpenWorldObserverSigningAnchorGapRequest) -> OpenWorldObserverSigningAnchorGapFetchResult
}

///|
/// Sequential reference source for tests and local single-process runs.
pub struct OpenWorldInMemoryObserverSigningAnchorGapTransport {
  by_cursor : Map[String, Array[OpenWorldObserverSigningAnchorEnvelope]]
}

///|
pub(all) enum OpenWorldObserverSigningAnchorGapRecoveryResult {
  ObserverSigningAnchorGapRecoveryAdvanced(Int, Bool)
  ObserverSigningAnchorGapRecoveryNoChange(Bool)
  ObserverSigningAnchorGapRecoveryBatchRefused(
    OpenWorldObserverSigningAnchorHeadBatchDelivery
  )
  ObserverSigningAnchorGapRecoveryUnavailable
  ObserverSigningAnchorGapRecoverySourceAmbiguous(Int)
  ObserverSigningAnchorGapRecoveryInvalidRequest
  ObserverSigningAnchorGapRecoveryMalformedResponse
  ObserverSigningAnchorGapRecoveryEnvelopeRefused(
    Int,
    OpenWorldObserverSigningAnchorEnvelopeRefusal
  )
} derive(Eq, Debug)

///|
/// Sequential peer-gossip view of one authority's anchor checkpoint chain.
pub struct OpenWorldObserverSigningAnchorHeadTracker {
  log_session_id : String
  publisher_key : @bft.PublicKey
  mut current_epoch : Int
  mut current_checkpoint_digest : @bft.Digest
  observed_checkpoints : Map[Int, @bft.Digest]
}

///|
/// Append-only local signing state for one observer identity.
pub struct OpenWorldObserverSigningLedger {
  hasher : &@bft.Hasher
  signer : &@bft.Signer
  observer_id : String
  signer_key : @bft.PublicKey
  storage : OpenWorldObserverSigningStorage
}

///|
pub(all) enum OpenWorldObserverSigningLedgerBuildResult {
  ObserverSigningLedgerReady(OpenWorldObserverSigningLedger)
  InvalidObserverSigningIdentity
  ObserverSigningStoreAnchorMismatch
}

///|
pub(all) enum OpenWorldObserverSigningRefusal {
  InvalidObserverSigningTarget
  ConflictingObserverRegistration(@bft.Digest)
  ObserverSigningStoreUnavailable
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObserverSigningResult {
  ObserverObservationSigned(SignedOpenWorldRegistrationObservation)
  ObserverObservationReused(SignedOpenWorldRegistrationObservation)
  ObserverSigningRefused(OpenWorldObserverSigningRefusal)
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObservationAlertKind {
  InvalidObserverRoster
  ObservationHashMismatch
  UnknownObserver
  ObserverSignerKeyMismatch
  InvalidObserverSignature
  WrongObservationAuditCheckpoint
  WrongObservationRegistrationIndex
  WrongObservationEncounterDigest
} derive(Eq, Debug)

///|
pub(all) struct OpenWorldObservationAlert {
  kind : OpenWorldObservationAlertKind
  observer_id : String
  digest : @bft.Digest
  detail : String
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldObservationDeliveryResult {
  ObservationAccepted
  ObservationDuplicate
  ObservationRejected(OpenWorldObservationAlert)
} derive(Eq, Debug)

///|
/// Collector bound to one plan, roster, slot, and encounter digest.
pub struct OpenWorldRegistrationObserverCollector {
  hasher : &@bft.Hasher
  verifier : &@bft.Verifier
  audit_checkpoint_digest : @bft.Digest
  observer_manifest_digest : @bft.Digest
  registration_index : Int
  encounter_digest : @bft.Digest
  observer_keys : Map[String, @bft.PublicKey]
  observer_indices : Map[String, Int]
  approvals : Array[Bool]
  observer_count : Int
  max_faults : Int
  roster_valid : Bool
}

///|
pub(all) enum OpenWorldRegistrationObserverCollectorBuildResult {
  RegistrationObserverCollectorReady(OpenWorldRegistrationObserverCollector)
  InvalidRegistrationAuditPolicy
  InvalidRegistrationGameManifest
  InvalidRegistrationObserverTarget
  InvalidRegistrationObserverPolicy
  InvalidRegistrationObserverRoster
  RegistrationObserverManifestMismatch
}

///|
/// Opaque proof that a plan-bound `n - f` observer quorum signed the same
/// `(audit checkpoint, slot, encounter digest)` registration.
pub struct OpenWorldRegistrationCertificate {
  audit_checkpoint_digest : @bft.Digest
  observer_manifest_digest : @bft.Digest
  registration_index : Int
  encounter_digest : @bft.Digest
  observer_count : Int
  max_faults : Int
  approval_count : Int
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldRegistrationCertificationResult {
  RegistrationObserved(OpenWorldRegistrationCertificate)
  RegistrationObservationPending(Int, Int)
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldAuditEpochRevealResult {
  AuditEpochRevealed(RevealedOpenWorldAuditEpoch)
  AuditEpochRefused(OpenWorldAuditEpochRefusal)
}

///|
/// Capability-bearing result of evaluating one irregular encounter.
pub(all) enum OpenWorldEncounterGateResult {
  EncounterPeerFinalized(@attestation.FinalizedCheckpoint)
  EncounterCentralFinalized(@attestation.FinalizedCheckpoint)
  EncounterProvisional
  EncounterCentralReplayRequired
  EncounterRejected
  EncounterInvalidAnchor
  EncounterAnchorNotCommitted
  EncounterEpochAuthorityMismatch
  EncounterEpochParentMismatch
  EncounterEvidenceMismatch
  EncounterInvalidRegistrationIndex
}

///|
pub(all) enum OpenWorldSealConflictKind {
  TruncatedRegistry
  SubstitutedSlot
  MissingSlot
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldSealConflictSource {
  AuthoritySignedEncounter
  ObserverQuorum
} derive(Eq, Debug)

///|
/// Opaque evidence that an authority-signed encounter conflicts with the
/// authority's later indexed registry seal.
pub struct OpenWorldSealConflict {
  kind : OpenWorldSealConflictKind
  source : OpenWorldSealConflictSource
  audit_checkpoint_digest : @bft.Digest
  seal_checkpoint_digest : @bft.Digest
  encounter_digest : @bft.Digest
  registration_index : Int
  sealed_encounter_digest : @bft.Digest?
  observer_approval_count : Int?
}

///|
pub(all) enum OpenWorldSealConflictDetection {
  SealConflictDetected(OpenWorldSealConflict)
  SealConflictNotFound
  SealConflictEvidenceInvalid
  SealConflictBoundaryMismatch
}
