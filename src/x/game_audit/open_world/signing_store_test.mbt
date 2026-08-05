///|
test "in-memory signing store reserves one digest with compare-and-set semantics" {
  let hasher = @bft.FnvHasher::new()
  let store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  let initial_root = store.root()
  assert_eq(
    store.reserve("plan-slot", @bft.Digest("encounter-a")),
    OpenWorldObserverSigningReservation::SigningSlotReserved,
  )
  assert_eq(store.size(), 1)
  assert_not_eq(store.root(), initial_root)
  let committed_root = store.root()
  assert_eq(
    store.reserve("plan-slot", @bft.Digest("encounter-a")),
    OpenWorldObserverSigningReservation::SigningSlotAlreadyReserved(
      @bft.Digest("encounter-a"),
    ),
  )
  assert_eq(
    store.reserve("plan-slot", @bft.Digest("encounter-b")),
    OpenWorldObserverSigningReservation::SigningSlotAlreadyReserved(
      @bft.Digest("encounter-a"),
    ),
  )
  assert_eq(store.size(), 1)
  assert_eq(store.root(), committed_root)
}

///|
test "trusted anchor rejects an empty or foreign restored store" {
  let hasher = @bft.FnvHasher::new()
  let signer = @bft.MockSigner::new("anchored-observer-key")
  let committed_store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  let committed = match
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      signer,
      observer_id="anchored-observer",
      store=committed_store,
    ) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => fail("expected ledger over committed store")
  }
  ignore(
    committed.sign_registration(
      audit_checkpoint_digest=@bft.Digest("audit-plan"),
      registration_index=9,
      encounter_digest=@bft.Digest("encounter-nine"),
    ),
  )
  let anchor = committed.anchor()
  let restored = OpenWorldObserverSigningLedger::new_with_store(
    hasher,
    signer,
    observer_id="anchored-observer",
    store=committed_store,
    trusted_anchor=anchor,
  )
  match restored {
    ObserverSigningLedgerReady(_) => ()
    _ => fail("expected exact trusted anchor to restore the signing ledger")
  }
  let rolled_back = OpenWorldInMemoryObserverSigningStore::new(hasher)
  assert_true(
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      signer,
      observer_id="anchored-observer",
      store=rolled_back,
      trusted_anchor=anchor,
    )
    is ObserverSigningStoreAnchorMismatch,
  )
  assert_true(
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      signer,
      observer_id="foreign-observer",
      store=committed_store,
      trusted_anchor=anchor,
    )
    is ObserverSigningStoreAnchorMismatch,
  )
  let foreign_signer = @bft.MockSigner::new("foreign-observer-key")
  assert_true(
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      foreign_signer,
      observer_id="anchored-observer",
      store=committed_store,
      trusted_anchor=anchor,
    )
    is ObserverSigningStoreAnchorMismatch,
  )
}

///|
struct CountingObserverSigner {
  key : @bft.PublicKey
  mut call_count : Int
}

///|
impl @bft.Signer for CountingObserverSigner with fn sign(
  self : CountingObserverSigner,
  digest : @bft.Digest,
) -> @bft.Signature {
  self.call_count += 1
  @bft.Signature("counted:" + digest.0)
}

///|
impl @bft.Signer for CountingObserverSigner with fn public_key(
  self : CountingObserverSigner,
) -> @bft.PublicKey {
  self.key
}

///|
struct UnavailableObserverSigningStore {}

///|
impl OpenWorldObserverSigningStore for UnavailableObserverSigningStore with fn reserve(
  _self : UnavailableObserverSigningStore,
  _key : String,
  _encounter_digest : @bft.Digest,
) -> OpenWorldObserverSigningReservation {
  SigningStoreUnavailable
}

///|
impl OpenWorldObserverSigningStore for UnavailableObserverSigningStore with fn snapshot(
  _self : UnavailableObserverSigningStore,
) -> OpenWorldObserverSigningStoreSnapshot {
  OpenWorldObserverSigningStoreSnapshot::{
    root: @bft.Digest("unavailable-store"),
    size: 0,
  }
}

///|
impl OpenWorldObserverSigningStore for UnavailableObserverSigningStore with fn proof(
  _self : UnavailableObserverSigningStore,
  _key : String,
) -> @authmap.AuthMapProof? {
  None
}

///|
test "store failure occurs before any observer signature is emitted" {
  let hasher = @bft.FnvHasher::new()
  let signer = CountingObserverSigner::{
    key: @bft.PublicKey("counting-observer"),
    call_count: 0,
  }
  let store = UnavailableObserverSigningStore::{  }
  let ledger = match
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      signer,
      observer_id="counting-observer",
      store~,
    ) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => fail("expected ledger over unavailable store")
  }
  assert_eq(
    ledger.sign_registration(
      audit_checkpoint_digest=@bft.Digest("audit-plan"),
      registration_index=1,
      encounter_digest=@bft.Digest("encounter-one"),
    ),
    OpenWorldObserverSigningResult::ObserverSigningRefused(
      ObserverSigningStoreUnavailable,
    ),
  )
  assert_eq(signer.call_count, 0)
}

///|
test "shared signing store prevents two ledger instances from equivocating" {
  let hasher = @bft.FnvHasher::new()
  let first_signer = CountingObserverSigner::{
    key: @bft.PublicKey("shared-observer-key"),
    call_count: 0,
  }
  let second_signer = CountingObserverSigner::{
    key: @bft.PublicKey("shared-observer-key"),
    call_count: 0,
  }
  let store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  let first = match
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      first_signer,
      observer_id="shared-observer",
      store~,
    ) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => fail("expected first ledger over shared store")
  }
  let second = match
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      second_signer,
      observer_id="shared-observer",
      store~,
    ) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => fail("expected second ledger over shared store")
  }
  match
    first.sign_registration(
      audit_checkpoint_digest=@bft.Digest("shared-plan"),
      registration_index=3,
      encounter_digest=@bft.Digest("encounter-a"),
    ) {
    ObserverObservationSigned(_) => ()
    _ => fail("expected the first reservation to sign")
  }
  assert_eq(first_signer.call_count, 1)
  assert_eq(
    second.sign_registration(
      audit_checkpoint_digest=@bft.Digest("shared-plan"),
      registration_index=3,
      encounter_digest=@bft.Digest("encounter-b"),
    ),
    OpenWorldObserverSigningResult::ObserverSigningRefused(
      ConflictingObserverRegistration(@bft.Digest("encounter-a")),
    ),
  )
  assert_eq(second_signer.call_count, 0)
}
