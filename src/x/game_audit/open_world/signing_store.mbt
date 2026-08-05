///|
/// Construct a sequential, process-local reference signing store.
pub fn OpenWorldInMemoryObserverSigningStore::new(
  hasher : &@bft.Hasher,
) -> OpenWorldInMemoryObserverSigningStore {
  OpenWorldInMemoryObserverSigningStore::{
    records: Map([]),
    commitment: @authmap.AuthenticatedMap::new(hasher),
  }
}

///|
pub impl OpenWorldObserverSigningStore for OpenWorldInMemoryObserverSigningStore with fn reserve(
  self : OpenWorldInMemoryObserverSigningStore,
  key : String,
  encounter_digest : @bft.Digest,
) -> OpenWorldObserverSigningReservation {
  match self.records.get(key) {
    Some(previous) => SigningSlotAlreadyReserved(previous)
    None => {
      self.records[key] = encounter_digest
      ignore(self.commitment.put(key, encounter_digest.0))
      SigningSlotReserved
    }
  }
}

///|
pub impl OpenWorldObserverSigningStore for OpenWorldInMemoryObserverSigningStore with fn snapshot(
  self : OpenWorldInMemoryObserverSigningStore,
) -> OpenWorldObserverSigningStoreSnapshot {
  OpenWorldObserverSigningStoreSnapshot::{
    root: self.commitment.root(),
    size: self.commitment.size(),
  }
}

///|
pub fn OpenWorldInMemoryObserverSigningStore::root(
  self : OpenWorldInMemoryObserverSigningStore,
) -> @bft.Digest {
  self.snapshot().root
}

///|
pub fn OpenWorldInMemoryObserverSigningStore::size(
  self : OpenWorldInMemoryObserverSigningStore,
) -> Int {
  self.snapshot().size
}

///|
pub impl OpenWorldObserverSigningStore for OpenWorldInMemoryObserverSigningStore with fn proof(
  self : OpenWorldInMemoryObserverSigningStore,
  key : String,
) -> @authmap.AuthMapProof? {
  self.commitment.proof(key)
}

///|
fn OpenWorldObserverSigningStorage::reserve(
  self : OpenWorldObserverSigningStorage,
  key : String,
  encounter_digest : @bft.Digest,
) -> OpenWorldObserverSigningReservation {
  match self {
    InMemorySigningStorage(store) => store.reserve(key, encounter_digest)
    ExternalSigningStorage(store) => store.reserve(key, encounter_digest)
  }
}

///|
fn OpenWorldObserverSigningStorage::root(
  self : OpenWorldObserverSigningStorage,
) -> @bft.Digest {
  self.snapshot().root
}

///|
fn OpenWorldObserverSigningStorage::snapshot(
  self : OpenWorldObserverSigningStorage,
) -> OpenWorldObserverSigningStoreSnapshot {
  match self {
    InMemorySigningStorage(store) => store.snapshot()
    ExternalSigningStorage(store) => store.snapshot()
  }
}

///|
fn OpenWorldObserverSigningStorage::size(
  self : OpenWorldObserverSigningStorage,
) -> Int {
  self.snapshot().size
}

///|
fn OpenWorldObserverSigningStorage::proof(
  self : OpenWorldObserverSigningStorage,
  key : String,
) -> @authmap.AuthMapProof? {
  match self {
    InMemorySigningStorage(store) => store.proof(key)
    ExternalSigningStorage(store) => store.proof(key)
  }
}
