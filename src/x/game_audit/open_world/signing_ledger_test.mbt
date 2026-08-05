///|
fn observer_signing_ledger(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  observer_id? : String = "observer-1",
) -> OpenWorldObserverSigningLedger raise Error {
  match OpenWorldObserverSigningLedger::new(hasher, signer, observer_id~) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => fail("expected valid observer signing ledger")
  }
}

///|
test "observer signing ledger reuses exact retry and rejects conflicting digest" {
  let hasher = @bft.FnvHasher::new()
  let signer = @bft.MockSigner::new("observer-key-1")
  let ledger = observer_signing_ledger(hasher, signer)
  let initial_root = ledger.root()
  let first = match
    ledger.sign_registration(
      audit_checkpoint_digest=@bft.Digest("audit-plan-1"),
      registration_index=4,
      encounter_digest=@bft.Digest("encounter-a"),
    ) {
    ObserverObservationSigned(receipt) => receipt
    _ => fail("first observer registration was not signed")
  }
  assert_eq(ledger.size(), 1)
  assert_not_eq(ledger.root(), initial_root)
  let committed_root = ledger.root()
  match
    ledger.sign_registration(
      audit_checkpoint_digest=@bft.Digest("audit-plan-1"),
      registration_index=4,
      encounter_digest=@bft.Digest("encounter-a"),
    ) {
    ObserverObservationReused(receipt) => assert_eq(receipt, first)
    _ => fail("exact observer retry did not reuse its receipt")
  }
  assert_eq(ledger.size(), 1)
  assert_eq(ledger.root(), committed_root)
  assert_eq(
    ledger.sign_registration(
      audit_checkpoint_digest=@bft.Digest("audit-plan-1"),
      registration_index=4,
      encounter_digest=@bft.Digest("encounter-b"),
    ),
    OpenWorldObserverSigningResult::ObserverSigningRefused(
      ConflictingObserverRegistration(@bft.Digest("encounter-a")),
    ),
  )
  assert_eq(ledger.size(), 1)
  assert_eq(ledger.root(), committed_root)
}

///|
test "observer signing ledger separates plans and registration slots" {
  let hasher = @bft.FnvHasher::new()
  let signer = @bft.MockSigner::new("observer-key-1")
  let ledger = observer_signing_ledger(hasher, signer)
  for
    entry in [
      (@bft.Digest("audit-plan-1"), 4, @bft.Digest("encounter-a")),
      (@bft.Digest("audit-plan-1"), 5, @bft.Digest("encounter-b")),
      (@bft.Digest("audit-plan-2"), 4, @bft.Digest("encounter-c")),
    ] {
    let (plan, slot, digest) = entry
    match
      ledger.sign_registration(
        audit_checkpoint_digest=plan,
        registration_index=slot,
        encounter_digest=digest,
      ) {
      ObserverObservationSigned(_) => ()
      _ => fail("independent observer target was not signed")
    }
  }
  assert_eq(ledger.size(), 3)
  let proof = ledger.proof(
    audit_checkpoint_digest=@bft.Digest("audit-plan-1"),
    registration_index=5,
  )
  match proof {
    Some(proof) =>
      assert_true(@authmap.verify_membership(hasher, ledger.root(), proof))
    None => fail("observer signing commitment proof missing")
  }
}

///|
test "invalid observer identity and signing targets fail closed" {
  let hasher = @bft.FnvHasher::new()
  let empty_key = @bft.MockSigner::new("")
  let signer = @bft.MockSigner::new("observer-key-1")
  assert_true(
    OpenWorldObserverSigningLedger::new(hasher, signer, observer_id="")
    is InvalidObserverSigningIdentity,
  )
  assert_true(
    OpenWorldObserverSigningLedger::new(
      hasher,
      empty_key,
      observer_id="observer-1",
    )
    is InvalidObserverSigningIdentity,
  )
  let ledger = observer_signing_ledger(hasher, signer)
  for
    entry in [
      (@bft.Digest(""), 0, @bft.Digest("encounter")),
      (@bft.Digest("plan"), -1, @bft.Digest("encounter")),
      (@bft.Digest("plan"), 0, @bft.Digest("")),
    ] {
    let (plan, slot, digest) = entry
    assert_eq(
      ledger.sign_registration(
        audit_checkpoint_digest=plan,
        registration_index=slot,
        encounter_digest=digest,
      ),
      OpenWorldObserverSigningResult::ObserverSigningRefused(
        InvalidObserverSigningTarget,
      ),
    )
  }
  assert_eq(ledger.size(), 0)
}
