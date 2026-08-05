///|
/// Reconstruct an authenticated publication capability from attacker-controlled
/// wire data. Checkpoint verification deliberately precedes map verification.
pub fn open_open_world_observer_signing_anchor_envelope(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  expected_publisher_key : @bft.PublicKey,
  log_session_id~ : String,
  envelope : OpenWorldObserverSigningAnchorEnvelope,
) -> OpenWorldObserverSigningAnchorEnvelopeOpenResult {
  match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      expected_publisher_key,
      envelope.signed_checkpoint,
    ) {
    @checkpoint.CheckpointOpenResult::Refused(reason) =>
      ObserverSigningAnchorEnvelopeRefused(
        ObserverSigningAnchorEnvelopeCheckpointRefused(reason),
      )
    @checkpoint.CheckpointOpenResult::Opened(verified_checkpoint) =>
      match
        open_published_open_world_observer_signing_anchor(
          hasher,
          verified_checkpoint,
          log_session_id~,
          anchor=envelope.anchor,
          membership_proof=envelope.membership_proof,
        ) {
        ObserverSigningAnchorPublished(published) =>
          ObserverSigningAnchorEnvelopeOpened(published)
        ObserverSigningAnchorPublicationRefused(reason) =>
          ObserverSigningAnchorEnvelopeRefused(
            ObserverSigningAnchorEnvelopePublicationRefused(reason),
          )
      }
  }
}

///|
pub fn OpenWorldInMemoryObserverSigningAnchorGapTransport::new(
  envelopes : Array[OpenWorldObserverSigningAnchorEnvelope],
) -> OpenWorldInMemoryObserverSigningAnchorGapTransport {
  let by_cursor : Map[String, Array[OpenWorldObserverSigningAnchorEnvelope]] = Map([],
  )
  for envelope in envelopes {
    let signed = envelope.signed_checkpoint
    let cursor = open_world_observer_signing_anchor_gap_cursor_key(
      signed.checkpoint.session_id,
      signed.authority_key,
      signed.checkpoint.epoch,
      signed.checkpoint.previous_checkpoint,
    )
    match by_cursor.get(cursor) {
      None => by_cursor[cursor] = [envelope]
      Some(existing) =>
        if open_world_observer_signing_anchor_envelope_is_new_candidate(
            existing, envelope,
          ) {
          let updated = existing.copy()
          updated.push(envelope)
          by_cursor[cursor] = updated
        }
    }
  }
  OpenWorldInMemoryObserverSigningAnchorGapTransport::{ by_cursor, }
}

///|
fn open_world_observer_signing_anchor_gap_cursor_key(
  log_session_id : String,
  publisher_key : @bft.PublicKey,
  epoch : Int,
  previous_checkpoint : @bft.Digest,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-observer-signing-anchor-gap-cursor-v1")
  append_field(buffer, log_session_id)
  append_field(buffer, publisher_key.0)
  append_field(buffer, epoch.to_string())
  append_field(buffer, previous_checkpoint.0)
  buffer.to_string()
}

///|
fn open_world_observer_signing_anchor_gap_request_valid(
  request : OpenWorldObserverSigningAnchorGapRequest,
) -> Bool {
  request.log_session_id != "" &&
  request.publisher_key.0 != "" &&
  request.after_checkpoint_digest.0 != "" &&
  request.target_epoch > request.after_epoch &&
  request.max_items > 0
}

///|
fn open_world_observer_signing_anchor_envelope_is_new_candidate(
  candidates : Array[OpenWorldObserverSigningAnchorEnvelope],
  candidate : OpenWorldObserverSigningAnchorEnvelope,
) -> Bool {
  for existing in candidates {
    if existing == candidate {
      return false
    }
  }
  true
}

///|
/// Select a bounded contiguous page. This adapter performs no cryptographic
/// verification; that remains a mandatory receiver-side responsibility.
pub impl OpenWorldObserverSigningAnchorGapTransport for OpenWorldInMemoryObserverSigningAnchorGapTransport with fn fetch(
  self : OpenWorldInMemoryObserverSigningAnchorGapTransport,
  request : OpenWorldObserverSigningAnchorGapRequest,
) -> OpenWorldObserverSigningAnchorGapFetchResult {
  if !open_world_observer_signing_anchor_gap_request_valid(request) {
    return ObserverSigningAnchorGapRequestInvalid
  }
  let selected : Array[OpenWorldObserverSigningAnchorEnvelope] = []
  let mut current_epoch = request.after_epoch
  let mut current_checkpoint_digest = request.after_checkpoint_digest
  while current_epoch < request.target_epoch &&
        selected.length() < request.max_items {
    let cursor = open_world_observer_signing_anchor_gap_cursor_key(
      request.log_session_id,
      request.publisher_key,
      current_epoch + 1,
      current_checkpoint_digest,
    )
    match self.by_cursor.get(cursor) {
      None => {
        if selected.length() == 0 {
          return ObserverSigningAnchorGapUnavailable
        }
        return ObserverSigningAnchorGapFetched({ envelopes: selected })
      }
      Some(candidates) => {
        if candidates.length() > 1 {
          return ObserverSigningAnchorGapSourceAmbiguous(candidates.length())
        }
        let next = candidates[0]
        selected.push(next)
        current_epoch = next.signed_checkpoint.checkpoint.epoch
        current_checkpoint_digest = next.signed_checkpoint.digest
      }
    }
  }
  ObserverSigningAnchorGapFetched({ envelopes: selected })
}

///|
/// Fetch, authenticate, and atomically merge one bounded gap page.
///
/// No tracker state changes until every envelope has opened successfully. The
/// subsequent batch merge also plans every chain transition before committing.
pub fn OpenWorldObserverSigningAnchorHeadTracker::recover_gap(
  self : OpenWorldObserverSigningAnchorHeadTracker,
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  transport : &OpenWorldObserverSigningAnchorGapTransport,
  target_epoch~ : Int,
  max_items~ : Int,
) -> OpenWorldObserverSigningAnchorGapRecoveryResult {
  let request = OpenWorldObserverSigningAnchorGapRequest::{
    log_session_id: self.log_session_id(),
    publisher_key: self.publisher_key(),
    after_epoch: self.current_epoch(),
    after_checkpoint_digest: self.current_checkpoint_digest(),
    target_epoch,
    max_items,
  }
  if !open_world_observer_signing_anchor_gap_request_valid(request) {
    return ObserverSigningAnchorGapRecoveryInvalidRequest
  }
  match transport.fetch(request) {
    ObserverSigningAnchorGapRequestInvalid =>
      ObserverSigningAnchorGapRecoveryInvalidRequest
    ObserverSigningAnchorGapUnavailable =>
      ObserverSigningAnchorGapRecoveryUnavailable
    ObserverSigningAnchorGapSourceAmbiguous(candidate_count) =>
      ObserverSigningAnchorGapRecoverySourceAmbiguous(candidate_count)
    ObserverSigningAnchorGapFetched(response) => {
      if response.envelopes.length() == 0 ||
        response.envelopes.length() > max_items {
        return ObserverSigningAnchorGapRecoveryMalformedResponse
      }
      let published : Array[PublishedOpenWorldObserverSigningAnchor] = []
      for index, envelope in response.envelopes {
        if envelope.signed_checkpoint.checkpoint.epoch > target_epoch {
          return ObserverSigningAnchorGapRecoveryMalformedResponse
        }
        match
          open_open_world_observer_signing_anchor_envelope(
            hasher,
            verifier,
            self.publisher_key(),
            log_session_id=self.log_session_id(),
            envelope,
          ) {
          ObserverSigningAnchorEnvelopeOpened(anchor) => published.push(anchor)
          ObserverSigningAnchorEnvelopeRefused(reason) =>
            return ObserverSigningAnchorGapRecoveryEnvelopeRefused(
              index, reason,
            )
        }
      }
      let delivery = self.deliver_batch(published)
      let has_more = self.current_epoch() < target_epoch
      match delivery {
        SigningAnchorHeadBatchAdvanced(advanced) =>
          ObserverSigningAnchorGapRecoveryAdvanced(advanced, has_more)
        SigningAnchorHeadBatchNoChange =>
          ObserverSigningAnchorGapRecoveryNoChange(has_more)
        refusal => ObserverSigningAnchorGapRecoveryBatchRefused(refusal)
      }
    }
  }
}
