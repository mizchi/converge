///|
/// BFT validation adapter that wraps CRDT event delivery.
/// Validates hash integrity, signatures, equivocation, and causal ordering
/// before accepting events.
pub struct BFTAdapter {
  hasher : &Hasher
  verifier : &Verifier
  session : String
  /// Immutable session roster: peer id → expected signing key.
  peer_keys : Map[String, PublicKey]
  /// Stores accepted digests for causal delivery checks
  digest_store : Map[String, Bool]
  /// Maps each accepted digest to the EventId authenticated by that digest.
  digest_ids : Map[String, @types.EventId]
  /// Maps (peer_id, counter) → digest for equivocation detection
  event_digests : Map[String, Digest]
  /// Buffer for events whose dependencies haven't arrived yet
  pending_buffer : Array[SignedEvent]
  /// Events flushed from the buffer after dependencies are met
  flushed_events : Array[AuthenticatedEvent]
  /// Validation failures discovered while flushing buffered events.
  flushed_alerts : Array[BFTAlert]
}

///|
/// Create a new BFTAdapter with given hasher and verifier.
pub fn BFTAdapter::new(
  hasher : &Hasher,
  verifier : &Verifier,
  session_id~ : String,
) -> BFTAdapter {
  BFTAdapter::{
    hasher,
    verifier,
    session: session_id,
    peer_keys: {},
    digest_store: {},
    digest_ids: {},
    event_digests: {},
    pending_buffer: [],
    flushed_events: [],
    flushed_alerts: [],
  }
}

///|
pub fn BFTAdapter::session_id(self : BFTAdapter) -> String {
  self.session
}

///|
/// Register a peer's signing key from a trusted session manifest.
/// Registration is idempotent, but an existing peer cannot be rebound.
pub fn BFTAdapter::register_peer(
  self : BFTAdapter,
  peer : @types.PeerId,
  key : PublicKey,
) -> Bool {
  match self.peer_keys.get(peer.0) {
    Some(existing) => existing == key
    None => {
      self.peer_keys[peer.0] = key
      true
    }
  }
}

///|
/// Sign an event, producing a SignedEvent with hash and signature.
pub fn BFTAdapter::sign(
  self : BFTAdapter,
  signer : &Signer,
  event : @types.Event,
  dep_hashes : Array[Digest],
) -> SignedEvent {
  let serialized = serialize_for_hash(self.session, event, dep_hashes)
  let digest = self.hasher.hash_string(serialized)
  let signature = signer.sign(digest)
  let author_key = signer.public_key()
  SignedEvent::{
    session_id: self.session,
    digest,
    signature,
    author_key,
    dep_hashes,
    event,
  }
}

///|
/// Deliver a signed event through the BFT validation pipeline.
/// Returns Accepted if valid, Buffered if waiting for deps, or Rejected with alert.
pub fn BFTAdapter::deliver(
  self : BFTAdapter,
  signed : SignedEvent,
) -> DeliveryResult {
  let event = signed.event
  let peer_id = event.id.peer
  // Step 1: Reject cross-session replay before accepting any event identity.
  if signed.session_id != self.session {
    return Rejected(BFTAlert::{
      kind: SessionMismatch,
      peer: peer_id,
      digest: signed.digest,
      detail: "expected=" + self.session + " received=" + signed.session_id,
    })
  }
  // Step 2: Hash integrity check. The session is part of the signed digest.
  let serialized = serialize_for_hash(
    signed.session_id,
    event,
    signed.dep_hashes,
  )
  let recomputed = self.hasher.hash_string(serialized)
  if recomputed != signed.digest {
    return Rejected(BFTAlert::{
      kind: HashMismatch,
      peer: peer_id,
      digest: signed.digest,
      detail: "recomputed=" + recomputed.0 + " received=" + signed.digest.0,
    })
  }
  // Step 3: Bind event authorship to the trusted session roster.
  match self.peer_keys.get(peer_id.0) {
    None =>
      return Rejected(BFTAlert::{
        kind: UnknownPeer,
        peer: peer_id,
        digest: signed.digest,
        detail: "peer is not registered in the session roster",
      })
    Some(expected_key) =>
      if expected_key != signed.author_key {
        return Rejected(BFTAlert::{
          kind: AuthorKeyMismatch,
          peer: peer_id,
          digest: signed.digest,
          detail: "expected=" +
          expected_key.0 +
          " received=" +
          signed.author_key.0,
        })
      }
  }
  // Step 4: Signature verification
  if !self.verifier.verify(signed.author_key, signed.digest, signed.signature) {
    return Rejected(BFTAlert::{
      kind: InvalidSignature,
      peer: peer_id,
      digest: signed.digest,
      detail: "signature verification failed for key=" + signed.author_key.0,
    })
  }
  if event.deps.length() != signed.dep_hashes.length() {
    return Rejected(self.dependency_mismatch_alert(signed))
  }
  // Step 5: Equivocation detection. A buffered event reserves its sequence id.
  let eq_key = peer_id.0 + ":" + event.id.counter.to_string()
  match self.event_digests.get(eq_key) {
    Some(existing) =>
      if existing != signed.digest {
        return Rejected(BFTAlert::{
          kind: Equivocation,
          peer: peer_id,
          digest: signed.digest,
          detail: "existing=" + existing.0 + " new=" + signed.digest.0,
        })
      } else {
        // Duplicate delivery preserves whether the first copy is accepted or buffered.
        if self.digest_store.contains(signed.digest.0) {
          return Accepted(authenticated_event(signed))
        }
        return Buffered
      }
    None => ()
  }
  // Reserve before buffering so a conflicting event cannot flush later.
  self.event_digests[eq_key] = signed.digest
  // Step 6: Causal delivery — check all dep_hashes are in digest_store
  let mut missing = false
  for dep in signed.dep_hashes {
    if !self.digest_store.contains(dep.0) {
      missing = true
      break
    }
  }
  if missing {
    self.pending_buffer.push(signed)
    return Buffered
  }
  if !self.dependencies_match(signed) {
    return Rejected(self.dependency_mismatch_alert(signed))
  }
  // All checks passed — accept
  self.accept(signed)
  Accepted(authenticated_event(signed))
}

///|
fn authenticated_event(signed : SignedEvent) -> AuthenticatedEvent {
  AuthenticatedEvent::{
    session_id: signed.session_id,
    digest: signed.digest,
    author_key: signed.author_key,
    event: signed.event,
  }
}

///|
pub fn AuthenticatedEvent::session_id(self : AuthenticatedEvent) -> String {
  self.session_id
}

///|
pub fn AuthenticatedEvent::digest(self : AuthenticatedEvent) -> Digest {
  self.digest
}

///|
pub fn AuthenticatedEvent::author_key(self : AuthenticatedEvent) -> PublicKey {
  self.author_key
}

///|
pub fn AuthenticatedEvent::event(self : AuthenticatedEvent) -> @types.Event {
  self.event
}

///|
/// Accept a validated event: store its digest and try to flush buffered events.
fn BFTAdapter::accept(self : BFTAdapter, signed : SignedEvent) -> Unit {
  let event = signed.event
  let eq_key = event.id.peer.0 + ":" + event.id.counter.to_string()
  self.digest_store[signed.digest.0] = true
  self.digest_ids[signed.digest.0] = event.id
  // This is also set when buffering; the assignment is intentionally idempotent.
  self.event_digests[eq_key] = signed.digest
  self.try_flush()
}

///|
/// Try to flush buffered events whose dependencies are now satisfied.
/// Uses a queue-based approach for O(n) instead of O(n²) repeated scans.
fn BFTAdapter::try_flush(self : BFTAdapter) -> Unit {
  let len = self.pending_buffer.length()
  if len == 0 {
    return
  }
  // Build index: dep_digest → indices of events waiting on it
  let waiters : Map[String, Array[Int]] = Map([])
  let unmet_count : Array[Int] = Array::make(len, 0)
  for i, signed in self.pending_buffer {
    let mut unmet = 0
    for dep in signed.dep_hashes {
      if !self.digest_store.contains(dep.0) {
        unmet += 1
        match waiters.get(dep.0) {
          Some(list) => list.push(i)
          None => waiters[dep.0] = [i]
        }
      }
    }
    unmet_count[i] = unmet
  }
  // Seed queue with events whose deps are already satisfied
  let queue : Array[Int] = []
  for i = 0; i < len; i = i + 1 {
    if unmet_count[i] == 0 {
      queue.push(i)
    }
  }
  // Process queue: accept ready events, then unblock their dependents
  let processed : Array[Bool] = Array::make(len, false)
  let mut qi = 0
  while qi < queue.length() {
    let idx = queue[qi]
    qi += 1
    if processed[idx] {
      continue
    }
    let signed = self.pending_buffer[idx]
    let event = signed.event
    if !self.dependencies_match(signed) {
      processed[idx] = true
      self.flushed_alerts.push(self.dependency_mismatch_alert(signed))
      continue
    }
    processed[idx] = true
    let eq_key = event.id.peer.0 + ":" + event.id.counter.to_string()
    self.digest_store[signed.digest.0] = true
    self.digest_ids[signed.digest.0] = event.id
    self.event_digests[eq_key] = signed.digest
    self.flushed_events.push(authenticated_event(signed))
    // Unblock events waiting on this digest
    match waiters.get(signed.digest.0) {
      Some(waiting) =>
        for w_idx in waiting {
          unmet_count[w_idx] -= 1
          if unmet_count[w_idx] == 0 {
            queue.push(w_idx)
          }
        }
      None => ()
    }
  }
  // Compact: keep only unaccepted events
  let remaining : Array[SignedEvent] = []
  for i, signed in self.pending_buffer {
    if !processed[i] {
      remaining.push(signed)
    }
  }
  self.pending_buffer.clear()
  for item in remaining {
    self.pending_buffer.push(item)
  }
}

///|
fn BFTAdapter::dependencies_match(
  self : BFTAdapter,
  signed : SignedEvent,
) -> Bool {
  if signed.event.deps.length() != signed.dep_hashes.length() {
    return false
  }
  for i, digest in signed.dep_hashes {
    match self.digest_ids.get(digest.0) {
      Some(id) => if id != signed.event.deps[i] { return false }
      None => return false
    }
  }
  true
}

///|
fn BFTAdapter::dependency_mismatch_alert(
  self : BFTAdapter,
  signed : SignedEvent,
) -> BFTAlert {
  ignore(self)
  {
    kind: DependencyMismatch,
    peer: signed.event.id.peer,
    digest: signed.digest,
    detail: "event dependency ids do not match authenticated dependency digests",
  }
}

///|
/// Take all events that were flushed from the buffer, clearing the list.
pub fn BFTAdapter::take_flushed(self : BFTAdapter) -> Array[AuthenticatedEvent] {
  let result = self.flushed_events.copy()
  self.flushed_events.clear()
  result
}

///|
/// Take validation alerts discovered during causal buffer flushing.
pub fn BFTAdapter::take_flushed_alerts(self : BFTAdapter) -> Array[BFTAlert] {
  let result = self.flushed_alerts.copy()
  self.flushed_alerts.clear()
  result
}
