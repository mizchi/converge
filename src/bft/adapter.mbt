///|
/// BFT validation adapter that wraps CRDT event delivery.
/// Validates hash integrity, signatures, equivocation, and causal ordering
/// before accepting events.
pub(all) struct BFTAdapter {
  hasher : &Hasher
  verifier : &Verifier
  /// Stores accepted digests for causal delivery checks
  digest_store : Map[String, Bool]
  /// Maps (peer_id, counter) → digest for equivocation detection
  event_digests : Map[String, Digest]
  /// Buffer for events whose dependencies haven't arrived yet
  pending_buffer : Array[SignedEvent]
  /// Events flushed from the buffer after dependencies are met
  flushed_events : Array[@types.Event]
}

///|
/// Create a new BFTAdapter with given hasher and verifier.
pub fn BFTAdapter::new(hasher : &Hasher, verifier : &Verifier) -> BFTAdapter {
  BFTAdapter::{
    hasher,
    verifier,
    digest_store: {},
    event_digests: {},
    pending_buffer: [],
    flushed_events: [],
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
  let serialized = serialize_for_hash(event, dep_hashes)
  let digest = self.hasher.hash_string(serialized)
  let signature = signer.sign(digest)
  let author_key = signer.public_key()
  SignedEvent::{ digest, signature, author_key, dep_hashes, event }
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
  // Step 1: Hash integrity check
  let serialized = serialize_for_hash(event, signed.dep_hashes)
  let recomputed = self.hasher.hash_string(serialized)
  if recomputed != signed.digest {
    return Rejected(BFTAlert::{
      kind: HashMismatch,
      peer: peer_id,
      digest: signed.digest,
      detail: "recomputed=" + recomputed.0 + " received=" + signed.digest.0,
    })
  }
  // Step 2: Signature verification
  if not(
      self.verifier.verify(signed.author_key, signed.digest, signed.signature),
    ) {
    return Rejected(BFTAlert::{
      kind: InvalidSignature,
      peer: peer_id,
      digest: signed.digest,
      detail: "signature verification failed for key=" + signed.author_key.0,
    })
  }
  // Step 3: Equivocation detection
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
        // Duplicate delivery of same event — accept idempotently
        return Accepted(event)
      }
    None => ()
  }
  // Step 4: Causal delivery — check all dep_hashes are in digest_store
  let mut missing = false
  for dep in signed.dep_hashes {
    if not(self.digest_store.contains(dep.0)) {
      missing = true
      break
    }
  }
  if missing {
    self.pending_buffer.push(signed)
    return Buffered
  }
  // All checks passed — accept
  self.accept(signed)
  Accepted(event)
}

///|
/// Accept a validated event: store its digest and try to flush buffered events.
fn BFTAdapter::accept(self : BFTAdapter, signed : SignedEvent) -> Unit {
  let event = signed.event
  let eq_key = event.id.peer.0 + ":" + event.id.counter.to_string()
  self.digest_store[signed.digest.0] = true
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
  let waiters : Map[String, Array[Int]] = {}
  let unmet_count : Array[Int] = Array::make(len, 0)
  for i, signed in self.pending_buffer {
    let mut unmet = 0
    for dep in signed.dep_hashes {
      if not(self.digest_store.contains(dep.0)) {
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
  let accepted : Array[Bool] = Array::make(len, false)
  let mut qi = 0
  while qi < queue.length() {
    let idx = queue[qi]
    qi += 1
    if accepted[idx] {
      continue
    }
    accepted[idx] = true
    let signed = self.pending_buffer[idx]
    let event = signed.event
    let eq_key = event.id.peer.0 + ":" + event.id.counter.to_string()
    self.digest_store[signed.digest.0] = true
    self.event_digests[eq_key] = signed.digest
    self.flushed_events.push(event)
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
    if not(accepted[i]) {
      remaining.push(signed)
    }
  }
  self.pending_buffer.clear()
  for item in remaining {
    self.pending_buffer.push(item)
  }
}

///|
/// Take all events that were flushed from the buffer, clearing the list.
pub fn BFTAdapter::take_flushed(self : BFTAdapter) -> Array[@types.Event] {
  let result = self.flushed_events.copy()
  self.flushed_events.clear()
  result
}
