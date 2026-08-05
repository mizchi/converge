///|
fn observer_roster(
  size : Int,
) -> (Array[@bft.MockSigner], Array[@attestation.Participant]) {
  let signers : Array[@bft.MockSigner] = []
  let observers : Array[@attestation.Participant] = []
  for index in 0..<size {
    let id = "observer-" + index.to_string()
    let signer = @bft.MockSigner::new(id)
    signers.push(signer)
    observers.push({ id, key: signer.public_key() })
  }
  (signers, observers)
}

///|
fn sign_observation_for_test(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  audit_checkpoint_digest~ : @bft.Digest,
  observer_id~ : String,
  registration_index~ : Int,
  encounter_digest~ : @bft.Digest,
) -> SignedOpenWorldRegistrationObservation raise Error {
  let ledger = match
    OpenWorldObserverSigningLedger::new(hasher, signer, observer_id~) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => fail("expected observer signing ledger")
  }
  match
    ledger.sign_registration(
      audit_checkpoint_digest~,
      registration_index~,
      encounter_digest~,
    ) {
    ObserverObservationSigned(receipt) => receipt
    _ => fail("expected signed registration observation")
  }
}

///|
fn observer_plan(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  observers : Array[@attestation.Participant],
  max_faults : Int,
  world_id? : String = "observed-world",
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let observer_manifest = open_world_observer_manifest(
    hasher,
    observers~,
    max_faults~,
  )
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id: world_id,
    epoch: 20,
    previous_checkpoint: @bft.Digest("world-epoch-19"),
    manifest_digest: open_world_audit_manifest(
      hasher,
      game_manifest_digest=@bft.Digest("observed-world-kernel-v1"),
      observer_manifest_digest=observer_manifest,
      sample_numerator=1,
      sample_denominator=100,
    ),
    event_root: @bft.Digest("observer-plan-events"),
    public_state_root: @bft.Digest("observer-plan-state"),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: Some(
      open_world_audit_seed_commitment(
        hasher,
        world_id~,
        epoch=20,
        seed="observer-seed",
      ),
    ),
  })
  let signed = @checkpoint.sign_prepared_checkpoint(authority, prepared)
  match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      authority.public_key(),
      signed,
    ) {
    Opened(verified) => verified
    _ => fail("expected verified observer audit plan")
  }
}

///|
fn observer_collector(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  plan : @checkpoint.VerifiedCheckpoint,
  observers : Array[@attestation.Participant],
  max_faults : Int,
  registration_index? : Int = 7,
  encounter_digest? : @bft.Digest = @bft.Digest("encounter-seven"),
) -> OpenWorldRegistrationObserverCollector raise Error {
  match
    OpenWorldRegistrationObserverCollector::new(
      hasher,
      verifier,
      plan,
      game_manifest_digest=@bft.Digest("observed-world-kernel-v1"),
      sample_numerator=1,
      sample_denominator=100,
      observers~,
      max_faults~,
      registration_index~,
      encounter_digest~,
    ) {
    RegistrationObserverCollectorReady(collector) => collector
    _ => fail("expected registration observer collector")
  }
}

///|
test "observer manifest is roster-order independent and plan-bound" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-authority")
  let (_, observers) = observer_roster(4)
  let reversed = [observers[3], observers[2], observers[1], observers[0]]
  assert_eq(
    open_world_observer_manifest(hasher, observers~, max_faults=1),
    open_world_observer_manifest(hasher, observers=reversed, max_faults=1),
  )
  assert_not_eq(
    open_world_observer_manifest(hasher, observers~, max_faults=1),
    open_world_observer_manifest(hasher, observers~, max_faults=0),
  )
  let plan = observer_plan(hasher, verifier, authority, observers, 1)
  let (_, foreign) = observer_roster(5)
  assert_true(
    OpenWorldRegistrationObserverCollector::new(
      hasher,
      verifier,
      plan,
      game_manifest_digest=@bft.Digest("observed-world-kernel-v1"),
      sample_numerator=1,
      sample_denominator=100,
      observers=foreign,
      max_faults=1,
      registration_index=7,
      encounter_digest=@bft.Digest("encounter-seven"),
    )
    is RegistrationObserverManifestMismatch,
  )
}

///|
test "n minus f observer receipts certify one exact registration" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-authority")
  let (signers, observers) = observer_roster(4)
  let plan = observer_plan(hasher, verifier, authority, observers, 1)
  let collector = observer_collector(hasher, verifier, plan, observers, 1)
  for index in 0..<3 {
    let receipt = sign_observation_for_test(
      hasher,
      signers[index],
      audit_checkpoint_digest=plan.digest(),
      observer_id=observers[index].id,
      registration_index=7,
      encounter_digest=@bft.Digest("encounter-seven"),
    )
    assert_eq(
      collector.deliver(receipt),
      OpenWorldObservationDeliveryResult::ObservationAccepted,
    )
    if index == 0 {
      assert_eq(
        collector.deliver(receipt),
        OpenWorldObservationDeliveryResult::ObservationDuplicate,
      )
    }
  }
  match collector.certify() {
    RegistrationObserved(certificate) => {
      assert_eq(certificate.audit_checkpoint_digest(), plan.digest())
      assert_eq(certificate.registration_index(), 7)
      assert_eq(certificate.encounter_digest(), @bft.Digest("encounter-seven"))
      assert_eq(certificate.approval_count(), 3)
      assert_eq(certificate.required_approvals(), 3)
    }
    _ => fail("n-f observer receipts did not certify registration")
  }
}

///|
test "observer receipts are bound to target roster and signature" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-authority")
  let (signers, observers) = observer_roster(4)
  let plan = observer_plan(hasher, verifier, authority, observers, 1)
  let collector = observer_collector(hasher, verifier, plan, observers, 1)
  let wrong_target = sign_observation_for_test(
    hasher,
    signers[0],
    audit_checkpoint_digest=plan.digest(),
    observer_id=observers[0].id,
    registration_index=8,
    encounter_digest=@bft.Digest("encounter-seven"),
  )
  match collector.deliver(wrong_target) {
    ObservationRejected(alert) =>
      assert_eq(alert.kind, WrongObservationRegistrationIndex)
    _ => fail("cross-slot observer receipt was accepted")
  }
  let wrong_plan = sign_observation_for_test(
    hasher,
    signers[0],
    audit_checkpoint_digest=@bft.Digest("foreign-audit-plan"),
    observer_id=observers[0].id,
    registration_index=7,
    encounter_digest=@bft.Digest("encounter-seven"),
  )
  match collector.deliver(wrong_plan) {
    ObservationRejected(alert) =>
      assert_eq(alert.kind, WrongObservationAuditCheckpoint)
    _ => fail("cross-plan observer receipt was accepted")
  }
  let wrong_digest = sign_observation_for_test(
    hasher,
    signers[0],
    audit_checkpoint_digest=plan.digest(),
    observer_id=observers[0].id,
    registration_index=7,
    encounter_digest=@bft.Digest("different-encounter"),
  )
  match collector.deliver(wrong_digest) {
    ObservationRejected(alert) =>
      assert_eq(alert.kind, WrongObservationEncounterDigest)
    _ => fail("cross-encounter observer receipt was accepted")
  }
  let valid = sign_observation_for_test(
    hasher,
    signers[0],
    audit_checkpoint_digest=plan.digest(),
    observer_id=observers[0].id,
    registration_index=7,
    encounter_digest=@bft.Digest("encounter-seven"),
  )
  let forged : SignedOpenWorldRegistrationObservation = {
    ..valid,
    signature: @bft.Signature("forged"),
  }
  match collector.deliver(forged) {
    ObservationRejected(alert) =>
      assert_eq(alert.kind, InvalidObserverSignature)
    _ => fail("forged observer receipt was accepted")
  }
}

///|
test "under-quorum and invalid observer rosters fail closed" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-authority")
  let (signers, observers) = observer_roster(4)
  let plan = observer_plan(hasher, verifier, authority, observers, 1)
  let collector = observer_collector(hasher, verifier, plan, observers, 1)
  for index in 0..<2 {
    ignore(
      collector.deliver(
        sign_observation_for_test(
          hasher,
          signers[index],
          audit_checkpoint_digest=plan.digest(),
          observer_id=observers[index].id,
          registration_index=7,
          encounter_digest=@bft.Digest("encounter-seven"),
        ),
      ),
    )
  }
  assert_eq(
    collector.certify(),
    OpenWorldRegistrationCertificationResult::RegistrationObservationPending(
      2, 3,
    ),
  )
  let (_, invalid_observers) = observer_roster(3)
  let invalid_plan = observer_plan(
    hasher, verifier, authority, invalid_observers, 1,
  )
  assert_true(
    OpenWorldRegistrationObserverCollector::new(
      hasher,
      verifier,
      invalid_plan,
      game_manifest_digest=@bft.Digest("observed-world-kernel-v1"),
      sample_numerator=1,
      sample_denominator=100,
      observers=invalid_observers,
      max_faults=1,
      registration_index=7,
      encounter_digest=@bft.Digest("encounter-seven"),
    )
    is InvalidRegistrationObserverPolicy,
  )
  let duplicate_key = [
    observers[0],
    { id: "duplicate-key", key: observers[0].key },
    observers[2],
    observers[3],
  ]
  let duplicate_plan = observer_plan(
    hasher, verifier, authority, duplicate_key, 1,
  )
  assert_true(
    OpenWorldRegistrationObserverCollector::new(
      hasher,
      verifier,
      duplicate_plan,
      game_manifest_digest=@bft.Digest("observed-world-kernel-v1"),
      sample_numerator=1,
      sample_denominator=100,
      observers=duplicate_key,
      max_faults=1,
      registration_index=7,
      encounter_digest=@bft.Digest("encounter-seven"),
    )
    is InvalidRegistrationObserverRoster,
  )
}

///|
fn observer_certificate(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  plan : @checkpoint.VerifiedCheckpoint,
  signers : Array[@bft.MockSigner],
  observers : Array[@attestation.Participant],
  registration_index : Int,
  encounter_digest : @bft.Digest,
) -> OpenWorldRegistrationCertificate raise Error {
  let collector = observer_collector(
    hasher,
    verifier,
    plan,
    observers,
    1,
    registration_index~,
    encounter_digest~,
  )
  for index in 0..<3 {
    ignore(
      collector.deliver(
        sign_observation_for_test(
          hasher,
          signers[index],
          audit_checkpoint_digest=plan.digest(),
          observer_id=observers[index].id,
          registration_index~,
          encounter_digest~,
        ),
      ),
    )
  }
  match collector.certify() {
    RegistrationObserved(certificate) => certificate
    _ => fail("expected observed registration certificate")
  }
}

///|
fn revealed_observer_epoch(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  plan : @checkpoint.VerifiedCheckpoint,
  observer_manifest_digest : @bft.Digest,
  registry : @authmap.AuthenticatedMap,
  registered_count : Int,
) -> RevealedOpenWorldAuditEpoch raise Error {
  let eligible = @merkle.MerkleTree::build(hasher, [])
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id: plan.checkpoint().session_id,
    epoch: plan.checkpoint().epoch + 1,
    previous_checkpoint: plan.digest(),
    manifest_digest: open_world_anchor_seal_manifest(
      hasher,
      audit_manifest_digest=plan.checkpoint().manifest_digest,
      registered_count~,
    ),
    event_root: eligible.root(),
    public_state_root: registry.root(),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: None,
  })
  let signed = @checkpoint.sign_prepared_checkpoint(authority, prepared)
  let seal = match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      authority.public_key(),
      signed,
    ) {
    Opened(verified) => verified
    _ => fail("expected verified observer seal")
  }
  match
    reveal_open_world_audit_epoch(
      hasher,
      plan,
      seal,
      game_manifest_digest=@bft.Digest("observed-world-kernel-v1"),
      observer_manifest_digest~,
      sample_numerator=1,
      sample_denominator=100,
      registered_count~,
      seed="observer-seed",
    ) {
    AuditEpochRevealed(epoch) => epoch
    _ => fail("expected revealed observer epoch")
  }
}

///|
test "observer quorum and non-membership prove a hidden registration" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-authority")
  let (signers, observers) = observer_roster(4)
  let plan = observer_plan(hasher, verifier, authority, observers, 1)
  let certificate = observer_certificate(
    hasher,
    verifier,
    plan,
    signers,
    observers,
    7,
    @bft.Digest("encounter-seven"),
  )
  let registry = @authmap.AuthenticatedMap::new(hasher)
  ignore(
    registry.put(
      open_world_encounter_registration_key(0),
      "registered-encounter-zero",
    ),
  )
  let observer_manifest_digest = open_world_observer_manifest(
    hasher,
    observers~,
    max_faults=1,
  )
  let epoch = revealed_observer_epoch(
    hasher, verifier, authority, plan, observer_manifest_digest, registry, 8,
  )
  let absence = registry
    .absence_proof(open_world_encounter_registration_key(7))
    .unwrap()
  match
    detect_observed_open_world_seal_conflict(
      hasher,
      epoch,
      certificate,
      missing_registration=absence,
    ) {
    SealConflictDetected(conflict) => {
      assert_eq(conflict.kind(), OpenWorldSealConflictKind::MissingSlot)
      assert_eq(conflict.source(), OpenWorldSealConflictSource::ObserverQuorum)
      assert_eq(conflict.encounter_digest(), @bft.Digest("encounter-seven"))
      assert_eq(conflict.observer_approval_count(), Some(3))
    }
    _ => fail("observer quorum did not prove hidden registration")
  }
}

///|
test "foreign observer certificate and tampered absence cannot accuse seal" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-authority")
  let (signers, observers) = observer_roster(4)
  let plan = observer_plan(hasher, verifier, authority, observers, 1)
  let certificate = observer_certificate(
    hasher,
    verifier,
    plan,
    signers,
    observers,
    7,
    @bft.Digest("encounter-seven"),
  )
  let registry = @authmap.AuthenticatedMap::new(hasher)
  ignore(
    registry.put(
      open_world_encounter_registration_key(0),
      "registered-encounter-zero",
    ),
  )
  let observer_manifest_digest = open_world_observer_manifest(
    hasher,
    observers~,
    max_faults=1,
  )
  let epoch = revealed_observer_epoch(
    hasher, verifier, authority, plan, observer_manifest_digest, registry, 8,
  )
  let absence = registry
    .absence_proof(open_world_encounter_registration_key(7))
    .unwrap()
  let tampered : @authmap.AuthMapAbsenceProof = {
    ..absence,
    key: open_world_encounter_registration_key(6),
  }
  assert_true(
    detect_observed_open_world_seal_conflict(
      hasher,
      epoch,
      certificate,
      missing_registration=tampered,
    )
    is SealConflictEvidenceInvalid,
  )
  let foreign_plan = observer_plan(
    hasher,
    verifier,
    authority,
    observers,
    1,
    world_id="foreign-world",
  )
  let foreign_certificate = observer_certificate(
    hasher,
    verifier,
    foreign_plan,
    signers,
    observers,
    7,
    @bft.Digest("encounter-seven"),
  )
  assert_true(
    detect_observed_open_world_seal_conflict(
      hasher,
      epoch,
      foreign_certificate,
      missing_registration=absence,
    )
    is SealConflictBoundaryMismatch,
  )
}
