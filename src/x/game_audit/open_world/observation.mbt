///|
/// Canonically commit the observer identities and Byzantine fault budget used
/// for registration receipts in one open-world audit plan.
pub fn open_world_observer_manifest(
  hasher : &@bft.Hasher,
  observers~ : Array[@attestation.Participant],
  max_faults~ : Int,
) -> @bft.Digest {
  let sorted = observers.copy()
  sorted.sort_by(fn(left, right) {
    if left.id != right.id {
      right.id.compare(left.id)
    } else {
      right.key.0.compare(left.key.0)
    }
  })
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-registration-observers-v1")
  append_field(buffer, max_faults.to_string())
  append_field(buffer, sorted.length().to_string())
  for observer in sorted {
    append_field(buffer, observer.id)
    append_field(buffer, observer.key.0)
  }
  hasher.hash_string(buffer.to_string())
}

///|
/// Versioned, length-prefixed signature payload for one registration receipt.
pub fn serialize_open_world_registration_observation(
  observation : OpenWorldRegistrationObservation,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-registration-observation-v1")
  append_field(buffer, observation.audit_checkpoint_digest.0)
  append_field(buffer, observation.observer_id)
  append_field(buffer, observation.registration_index.to_string())
  append_field(buffer, observation.encounter_digest.0)
  buffer.to_string()
}

///|
/// Canonical append-only signing-ledger key for one audit plan and slot.
pub fn open_world_observer_signing_key(
  audit_checkpoint_digest : @bft.Digest,
  registration_index : Int,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-observer-signing-key-v1")
  append_field(buffer, audit_checkpoint_digest.0)
  append_field(buffer, registration_index.to_string())
  buffer.to_string()
}

///|
/// Internal raw signer; public callers must use the append-only signing ledger.
fn sign_open_world_registration_observation(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  audit_checkpoint_digest~ : @bft.Digest,
  observer_id~ : String,
  registration_index~ : Int,
  encounter_digest~ : @bft.Digest,
) -> SignedOpenWorldRegistrationObservation {
  let observation = OpenWorldRegistrationObservation::{
    audit_checkpoint_digest,
    observer_id,
    registration_index,
    encounter_digest,
  }
  let digest = hasher.hash_string(
    serialize_open_world_registration_observation(observation),
  )
  SignedOpenWorldRegistrationObservation::{
    observation,
    digest,
    signature: signer.sign(digest),
    signer_key: signer.public_key(),
  }
}

///|
/// Bind one local append-only signing ledger to an observer id and key.
pub fn OpenWorldObserverSigningLedger::new(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  observer_id~ : String,
) -> OpenWorldObserverSigningLedgerBuildResult {
  let store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  build_open_world_observer_signing_ledger(
    hasher,
    signer,
    observer_id~,
    storage=InMemorySigningStorage(store),
    trusted_anchor=None,
  )
}

///|
/// Restore a ledger over a caller-provided durable store.
///
/// When supplied, `trusted_anchor` must exactly match the observer identity,
/// signing key, Merkle root, and store size before the ledger can sign.
pub fn OpenWorldObserverSigningLedger::new_with_store(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  observer_id~ : String,
  store~ : &OpenWorldObserverSigningStore,
  trusted_anchor? : OpenWorldObserverSigningAnchor,
) -> OpenWorldObserverSigningLedgerBuildResult {
  build_open_world_observer_signing_ledger(
    hasher,
    signer,
    observer_id~,
    storage=ExternalSigningStorage(store),
    trusted_anchor~,
  )
}

///|
fn build_open_world_observer_signing_ledger(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  observer_id~ : String,
  storage~ : OpenWorldObserverSigningStorage,
  trusted_anchor~ : OpenWorldObserverSigningAnchor?,
) -> OpenWorldObserverSigningLedgerBuildResult {
  let signer_key = signer.public_key()
  if observer_id == "" || signer_key.0 == "" {
    return InvalidObserverSigningIdentity
  }
  match trusted_anchor {
    Some(anchor) => {
      let snapshot = storage.snapshot()
      if anchor.observer_id != observer_id ||
        anchor.signer_key != signer_key ||
        anchor.root != snapshot.root ||
        anchor.size != snapshot.size {
        return ObserverSigningStoreAnchorMismatch
      }
    }
    None => ()
  }
  ObserverSigningLedgerReady(OpenWorldObserverSigningLedger::{
    hasher,
    signer,
    observer_id,
    signer_key,
    storage,
  })
}

///|
pub fn OpenWorldObserverSigningLedger::observer_id(
  self : OpenWorldObserverSigningLedger,
) -> String {
  self.observer_id
}

///|
pub fn OpenWorldObserverSigningLedger::signer_key(
  self : OpenWorldObserverSigningLedger,
) -> @bft.PublicKey {
  self.signer_key
}

///|
pub fn OpenWorldObserverSigningLedger::root(
  self : OpenWorldObserverSigningLedger,
) -> @bft.Digest {
  self.storage.root()
}

///|
pub fn OpenWorldObserverSigningLedger::size(
  self : OpenWorldObserverSigningLedger,
) -> Int {
  self.storage.size()
}

///|
pub fn OpenWorldObserverSigningLedger::proof(
  self : OpenWorldObserverSigningLedger,
  audit_checkpoint_digest~ : @bft.Digest,
  registration_index~ : Int,
) -> @authmap.AuthMapProof? {
  self.storage.proof(
    open_world_observer_signing_key(audit_checkpoint_digest, registration_index),
  )
}

///|
/// Capture the exact store state that a trusted checkpoint can publish.
pub fn OpenWorldObserverSigningLedger::anchor(
  self : OpenWorldObserverSigningLedger,
) -> OpenWorldObserverSigningAnchor {
  let snapshot = self.storage.snapshot()
  OpenWorldObserverSigningAnchor::{
    observer_id: self.observer_id,
    signer_key: self.signer_key,
    root: snapshot.root,
    size: snapshot.size,
  }
}

///|
/// Sign at most one encounter digest for each exact `(audit plan, slot)`.
/// The reservation store commits before any signature is emitted.
pub fn OpenWorldObserverSigningLedger::sign_registration(
  self : OpenWorldObserverSigningLedger,
  audit_checkpoint_digest~ : @bft.Digest,
  registration_index~ : Int,
  encounter_digest~ : @bft.Digest,
) -> OpenWorldObserverSigningResult {
  let target_valid = audit_checkpoint_digest.0 != "" &&
    registration_index >= 0 &&
    encounter_digest.0 != ""
  let key = open_world_observer_signing_key(
    audit_checkpoint_digest, registration_index,
  )
  let reservation = if target_valid {
    self.storage.reserve(key, encounter_digest)
  } else {
    return ObserverSigningRefused(InvalidObserverSigningTarget)
  }
  let previous = match reservation {
    SigningSlotReserved => None
    SigningSlotAlreadyReserved(digest) => Some(digest)
    SigningStoreUnavailable =>
      return ObserverSigningRefused(ObserverSigningStoreUnavailable)
  }
  let previous_present = previous is Some(_)
  let previous_matches = match previous {
    Some(digest) => digest == encounter_digest
    None => false
  }
  match
    @audit.classify_open_world_observer_signing(
      target_valid~,
      previous_observation_present=previous_present,
      previous_digest_matches=previous_matches,
    ) {
    @audit.OpenWorldObserverSigningDecision::RejectInvalidObservation =>
      ObserverSigningRefused(InvalidObserverSigningTarget)
    @audit.OpenWorldObserverSigningDecision::RejectConflictingObservation =>
      match previous {
        Some(digest) =>
          ObserverSigningRefused(ConflictingObserverRegistration(digest))
        None => ObserverSigningRefused(InvalidObserverSigningTarget)
      }
    @audit.OpenWorldObserverSigningDecision::ReuseExistingObservation =>
      ObserverObservationReused(
        sign_open_world_registration_observation(
          self.hasher,
          self.signer,
          audit_checkpoint_digest~,
          observer_id=self.observer_id,
          registration_index~,
          encounter_digest~,
        ),
      )
    @audit.OpenWorldObserverSigningDecision::SignNewObservation =>
      ObserverObservationSigned(
        sign_open_world_registration_observation(
          self.hasher,
          self.signer,
          audit_checkpoint_digest~,
          observer_id=self.observer_id,
          registration_index~,
          encounter_digest~,
        ),
      )
  }
}

///|
fn observation_rejection(
  kind : OpenWorldObservationAlertKind,
  signed : SignedOpenWorldRegistrationObservation,
  detail : String,
) -> OpenWorldObservationDeliveryResult {
  ObservationRejected(OpenWorldObservationAlert::{
    kind,
    observer_id: signed.observation.observer_id,
    digest: signed.digest,
    detail,
  })
}

///|
/// Construct a collector only when the verified audit plan commits the exact
/// canonical observer roster and fault policy.
pub fn OpenWorldRegistrationObserverCollector::new(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  audit_plan : @checkpoint.VerifiedCheckpoint,
  game_manifest_digest~ : @bft.Digest,
  sample_numerator~ : Int,
  sample_denominator~ : Int,
  observers~ : Array[@attestation.Participant],
  max_faults~ : Int,
  registration_index~ : Int,
  encounter_digest~ : @bft.Digest,
) -> OpenWorldRegistrationObserverCollectorBuildResult {
  if !audit_policy_valid(sample_numerator, sample_denominator) {
    return InvalidRegistrationAuditPolicy
  }
  if game_manifest_digest.0 == "" {
    return InvalidRegistrationGameManifest
  }
  if registration_index < 0 || encounter_digest.0 == "" {
    return InvalidRegistrationObserverTarget
  }
  if !@audit.open_world_observer_policy_valid(observers.length(), max_faults) {
    return InvalidRegistrationObserverPolicy
  }
  let observer_keys : Map[String, @bft.PublicKey] = Map([])
  let observer_indices : Map[String, Int] = Map([])
  let used_keys : Map[String, Bool] = Map([])
  let mut roster_valid = true
  for index, observer in observers {
    if observer.id == "" ||
      observer.key.0 == "" ||
      observer_keys.contains(observer.id) ||
      used_keys.contains(observer.key.0) {
      roster_valid = false
    } else {
      observer_keys[observer.id] = observer.key
      observer_indices[observer.id] = index
      used_keys[observer.key.0] = true
    }
  }
  if !roster_valid {
    return InvalidRegistrationObserverRoster
  }
  let observer_manifest_digest = open_world_observer_manifest(
    hasher,
    observers~,
    max_faults~,
  )
  let expected_plan_manifest = open_world_audit_manifest(
    hasher,
    game_manifest_digest~,
    observer_manifest_digest~,
    sample_numerator~,
    sample_denominator~,
  )
  if audit_plan.checkpoint().manifest_digest != expected_plan_manifest {
    return RegistrationObserverManifestMismatch
  }
  RegistrationObserverCollectorReady(OpenWorldRegistrationObserverCollector::{
    hasher,
    verifier,
    audit_checkpoint_digest: audit_plan.digest(),
    observer_manifest_digest,
    registration_index,
    encounter_digest,
    observer_keys,
    observer_indices,
    approvals: Array::make(observers.length(), false),
    observer_count: observers.length(),
    max_faults,
    roster_valid,
  })
}

///|
/// Authenticate and deduplicate one plan-bound registration observation.
pub fn OpenWorldRegistrationObserverCollector::deliver(
  self : OpenWorldRegistrationObserverCollector,
  signed : SignedOpenWorldRegistrationObservation,
) -> OpenWorldObservationDeliveryResult {
  if !self.roster_valid {
    return observation_rejection(
      InvalidObserverRoster,
      signed,
      "observer roster is ambiguous",
    )
  }
  let recomputed = self.hasher.hash_string(
    serialize_open_world_registration_observation(signed.observation),
  )
  if recomputed != signed.digest {
    return observation_rejection(
      ObservationHashMismatch,
      signed,
      "observation digest mismatch",
    )
  }
  if signed.observation.audit_checkpoint_digest != self.audit_checkpoint_digest {
    return observation_rejection(
      WrongObservationAuditCheckpoint,
      signed,
      "observation targets another audit plan",
    )
  }
  if signed.observation.registration_index != self.registration_index {
    return observation_rejection(
      WrongObservationRegistrationIndex,
      signed,
      "observation targets another registration slot",
    )
  }
  if signed.observation.encounter_digest != self.encounter_digest {
    return observation_rejection(
      WrongObservationEncounterDigest,
      signed,
      "observation targets another encounter digest",
    )
  }
  let observer_id = signed.observation.observer_id
  let index = match self.observer_indices.get(observer_id) {
    None =>
      return observation_rejection(
        UnknownObserver,
        signed,
        "observer is absent from the plan roster",
      )
    Some(index) => index
  }
  let expected_key = match self.observer_keys.get(observer_id) {
    None =>
      return observation_rejection(
        InvalidObserverRoster,
        signed,
        "observer index has no signing key",
      )
    Some(key) => key
  }
  if signed.signer_key != expected_key {
    return observation_rejection(
      ObserverSignerKeyMismatch,
      signed,
      "observation signer does not own the observer id",
    )
  }
  if !self.verifier.verify(signed.signer_key, signed.digest, signed.signature) {
    return observation_rejection(
      InvalidObserverSignature,
      signed,
      "observer signature is invalid",
    )
  }
  if self.approvals[index] {
    return ObservationDuplicate
  }
  self.approvals[index] = true
  ObservationAccepted
}

///|
pub fn OpenWorldRegistrationObserverCollector::required_approvals(
  self : OpenWorldRegistrationObserverCollector,
) -> Int {
  @audit.open_world_observer_quorum_size(self.observer_count, self.max_faults)
}

///|
/// Issue an opaque receipt only after a plan-bound `n - f` observer quorum.
pub fn OpenWorldRegistrationObserverCollector::certify(
  self : OpenWorldRegistrationObserverCollector,
) -> OpenWorldRegistrationCertificationResult {
  let mut approval_count = 0
  for approved in self.approvals {
    if approved {
      approval_count += 1
    }
  }
  let required = self.required_approvals()
  if !@audit.open_world_observer_certificate_allowed(
      observer_count=self.observer_count,
      max_faults=self.max_faults,
      approval_count~,
    ) {
    return RegistrationObservationPending(approval_count, required)
  }
  RegistrationObserved(OpenWorldRegistrationCertificate::{
    audit_checkpoint_digest: self.audit_checkpoint_digest,
    observer_manifest_digest: self.observer_manifest_digest,
    registration_index: self.registration_index,
    encounter_digest: self.encounter_digest,
    observer_count: self.observer_count,
    max_faults: self.max_faults,
    approval_count,
  })
}

///|
pub fn OpenWorldRegistrationCertificate::audit_checkpoint_digest(
  self : OpenWorldRegistrationCertificate,
) -> @bft.Digest {
  self.audit_checkpoint_digest
}

///|
pub fn OpenWorldRegistrationCertificate::observer_manifest_digest(
  self : OpenWorldRegistrationCertificate,
) -> @bft.Digest {
  self.observer_manifest_digest
}

///|
pub fn OpenWorldRegistrationCertificate::registration_index(
  self : OpenWorldRegistrationCertificate,
) -> Int {
  self.registration_index
}

///|
pub fn OpenWorldRegistrationCertificate::encounter_digest(
  self : OpenWorldRegistrationCertificate,
) -> @bft.Digest {
  self.encounter_digest
}

///|
pub fn OpenWorldRegistrationCertificate::observer_count(
  self : OpenWorldRegistrationCertificate,
) -> Int {
  self.observer_count
}

///|
pub fn OpenWorldRegistrationCertificate::max_faults(
  self : OpenWorldRegistrationCertificate,
) -> Int {
  self.max_faults
}

///|
pub fn OpenWorldRegistrationCertificate::approval_count(
  self : OpenWorldRegistrationCertificate,
) -> Int {
  self.approval_count
}

///|
pub fn OpenWorldRegistrationCertificate::required_approvals(
  self : OpenWorldRegistrationCertificate,
) -> Int {
  @audit.open_world_observer_quorum_size(self.observer_count, self.max_faults)
}
