///|
fn signing_anchor_envelope_for_transport_test(
  hasher : &@bft.Hasher,
  authority : &@bft.Signer,
  log_session_id : String,
  epoch : Int,
  previous_checkpoint : @bft.Digest,
  anchor : OpenWorldObserverSigningAnchor,
) -> OpenWorldObserverSigningAnchorEnvelope raise Error {
  let anchor_map = @authmap.AuthenticatedMap::new(hasher)
  let key = open_world_observer_signing_anchor_key(anchor)
  ignore(anchor_map.put(key, open_world_observer_signing_anchor_value(anchor)))
  let signed_checkpoint = @checkpoint.sign_checkpoint(hasher, authority, {
    session_id: log_session_id,
    epoch,
    previous_checkpoint,
    manifest_digest: open_world_observer_signing_anchor_log_manifest(
      hasher,
      log_session_id~,
    ),
    event_root: @bft.Digest("observer-anchor-transport-events"),
    public_state_root: anchor_map.root(),
    asset_delta_root: @bft.Digest("observer-anchor-transport-no-assets"),
    hidden_state_commitment: None,
  })
  let membership_proof = match anchor_map.proof(key) {
    Some(proof) => proof
    None => fail("expected observer signing anchor membership proof")
  }
  { signed_checkpoint, anchor, membership_proof }
}

///|
fn open_anchor_envelope_for_transport_test(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  log_session_id : String,
  envelope : OpenWorldObserverSigningAnchorEnvelope,
) -> PublishedOpenWorldObserverSigningAnchor raise Error {
  match
    open_open_world_observer_signing_anchor_envelope(
      hasher,
      verifier,
      authority.public_key(),
      log_session_id~,
      envelope,
    ) {
    ObserverSigningAnchorEnvelopeOpened(published) => published
    ObserverSigningAnchorEnvelopeRefused(_) =>
      fail("expected authenticated observer signing anchor envelope")
  }
}

///|
test "wire anchor envelope opens only after authority and membership verification" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("anchor-envelope-authority")
  let session = "world-1:anchor-envelope"
  let anchor = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("observer-root-7"),
    size: 7,
  }
  let envelope = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    7,
    @bft.Digest("anchor-envelope-6"),
    anchor,
  )
  match
    open_open_world_observer_signing_anchor_envelope(
      hasher,
      verifier,
      authority.public_key(),
      log_session_id=session,
      envelope,
    ) {
    ObserverSigningAnchorEnvelopeOpened(published) => {
      assert_eq(published.anchor(), anchor)
      assert_eq(published.log_epoch(), 7)
      assert_eq(published.log_session_id(), session)
      assert_eq(published.publisher_key(), authority.public_key())
    }
    ObserverSigningAnchorEnvelopeRefused(_) =>
      fail("expected valid anchor envelope to open")
  }
  assert_eq(
    open_open_world_observer_signing_anchor_envelope(
      hasher,
      verifier,
      @bft.PublicKey("another-authority"),
      log_session_id=session,
      envelope,
    ),
    OpenWorldObserverSigningAnchorEnvelopeOpenResult::ObserverSigningAnchorEnvelopeRefused(
      OpenWorldObserverSigningAnchorEnvelopeRefusal::ObserverSigningAnchorEnvelopeCheckpointRefused(
        @checkpoint.CheckpointVerification::WrongAuthority,
      ),
    ),
  )
}

///|
test "wire anchor envelope rejects checkpoint and membership tampering" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("anchor-envelope-tamper-authority")
  let session = "world-1:anchor-envelope-tamper"
  let anchor = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("observer-root-8"),
    size: 8,
  }
  let envelope = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    8,
    @bft.Digest("anchor-envelope-7"),
    anchor,
  )
  let tampered_checkpoint : OpenWorldObserverSigningAnchorEnvelope = {
    ..envelope,
    signed_checkpoint: {
      ..envelope.signed_checkpoint,
      signature: @bft.Signature("invalid-anchor-envelope-signature"),
    },
  }
  assert_eq(
    open_open_world_observer_signing_anchor_envelope(
      hasher,
      verifier,
      authority.public_key(),
      log_session_id=session,
      tampered_checkpoint,
    ),
    OpenWorldObserverSigningAnchorEnvelopeOpenResult::ObserverSigningAnchorEnvelopeRefused(
      OpenWorldObserverSigningAnchorEnvelopeRefusal::ObserverSigningAnchorEnvelopeCheckpointRefused(
        @checkpoint.CheckpointVerification::InvalidSignature,
      ),
    ),
  )
  let tampered_anchor : OpenWorldObserverSigningAnchorEnvelope = {
    ..envelope,
    anchor: { ..anchor, size: 9 },
  }
  assert_eq(
    open_open_world_observer_signing_anchor_envelope(
      hasher,
      verifier,
      authority.public_key(),
      log_session_id=session,
      tampered_anchor,
    ),
    OpenWorldObserverSigningAnchorEnvelopeOpenResult::ObserverSigningAnchorEnvelopeRefused(
      OpenWorldObserverSigningAnchorEnvelopeRefusal::ObserverSigningAnchorEnvelopePublicationRefused(
        OpenWorldObserverSigningAnchorPublicationRefusal::ObserverSigningAnchorMembershipProofInvalid,
      ),
    ),
  )
}

///|
test "in-memory gap transport recovers an authenticated chain page by page" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("anchor-gap-authority")
  let session = "world-1:anchor-gap"
  let base = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("gap-root-10"),
    size: 10,
  }
  let envelope_10 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    10,
    @bft.Digest("gap-checkpoint-9"),
    base,
  )
  let head_10 = open_anchor_envelope_for_transport_test(
    hasher, verifier, authority, session, envelope_10,
  )
  let envelope_11 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("gap-root-11"), size: 11 },
  )
  let head_11 = open_anchor_envelope_for_transport_test(
    hasher, verifier, authority, session, envelope_11,
  )
  let envelope_12 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    12,
    head_11.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("gap-root-12"), size: 12 },
  )
  let head_12 = open_anchor_envelope_for_transport_test(
    hasher, verifier, authority, session, envelope_12,
  )
  let envelope_13 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    13,
    head_12.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("gap-root-13"), size: 13 },
  )
  let transport = OpenWorldInMemoryObserverSigningAnchorGapTransport::new([
    envelope_13, envelope_11, envelope_12,
  ])
  let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_10)
  assert_eq(
    tracker.recover_gap(
      hasher,
      verifier,
      transport,
      target_epoch=13,
      max_items=2,
    ),
    OpenWorldObserverSigningAnchorGapRecoveryResult::ObserverSigningAnchorGapRecoveryAdvanced(
      2, true,
    ),
  )
  assert_eq(tracker.current_epoch(), 12)
  assert_eq(
    tracker.recover_gap(
      hasher,
      verifier,
      transport,
      target_epoch=13,
      max_items=2,
    ),
    OpenWorldObserverSigningAnchorGapRecoveryResult::ObserverSigningAnchorGapRecoveryAdvanced(
      1, false,
    ),
  )
  assert_eq(tracker.current_epoch(), 13)
  assert_eq(tracker.observed_checkpoint_count(), 4)
}

///|
struct FixedObserverSigningAnchorGapTransport {
  result : OpenWorldObserverSigningAnchorGapFetchResult
}

///|
impl OpenWorldObserverSigningAnchorGapTransport for FixedObserverSigningAnchorGapTransport with fn fetch(
  self,
  _request,
) -> OpenWorldObserverSigningAnchorGapFetchResult {
  self.result
}

///|
test "gap recovery authenticates the complete page before mutating the tracker" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("anchor-gap-atomic-authority")
  let session = "world-1:anchor-gap-atomic"
  let base = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("atomic-root-10"),
    size: 10,
  }
  let envelope_10 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    10,
    @bft.Digest("atomic-checkpoint-9"),
    base,
  )
  let head_10 = open_anchor_envelope_for_transport_test(
    hasher, verifier, authority, session, envelope_10,
  )
  let envelope_11 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("atomic-root-11"), size: 11 },
  )
  let head_11 = open_anchor_envelope_for_transport_test(
    hasher, verifier, authority, session, envelope_11,
  )
  let envelope_12 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    12,
    head_11.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("atomic-root-12"), size: 12 },
  )
  let invalid_12 : OpenWorldObserverSigningAnchorEnvelope = {
    ..envelope_12,
    signed_checkpoint: {
      ..envelope_12.signed_checkpoint,
      signature: @bft.Signature("invalid-gap-page-signature"),
    },
  }
  let transport = FixedObserverSigningAnchorGapTransport::{
    result: ObserverSigningAnchorGapFetched({
      envelopes: [envelope_11, invalid_12],
    }),
  }
  let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_10)
  assert_eq(
    tracker.recover_gap(
      hasher,
      verifier,
      transport,
      target_epoch=12,
      max_items=2,
    ),
    OpenWorldObserverSigningAnchorGapRecoveryResult::ObserverSigningAnchorGapRecoveryEnvelopeRefused(
      1,
      OpenWorldObserverSigningAnchorEnvelopeRefusal::ObserverSigningAnchorEnvelopeCheckpointRefused(
        @checkpoint.CheckpointVerification::InvalidSignature,
      ),
    ),
  )
  assert_eq(tracker.current_epoch(), 10)
  assert_eq(tracker.observed_checkpoint_count(), 1)
  let wrong_parent_12 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    12,
    @bft.Digest("wrong-atomic-checkpoint-11"),
    { ..base, root: @bft.Digest("wrong-atomic-root-12"), size: 12 },
  )
  let invalid_chain = FixedObserverSigningAnchorGapTransport::{
    result: ObserverSigningAnchorGapFetched({
      envelopes: [envelope_11, wrong_parent_12],
    }),
  }
  match
    tracker.recover_gap(
      hasher,
      verifier,
      invalid_chain,
      target_epoch=12,
      max_items=2,
    ) {
    ObserverSigningAnchorGapRecoveryBatchRefused(
      SigningAnchorHeadBatchForkDetected(index, evidence)
    ) => {
      assert_eq(index, 1)
      assert_eq(evidence.kind(), WrongParentSigningAnchorCheckpoint)
    }
    _ => fail("expected authenticated but unlinked page to be batch-refused")
  }
  assert_eq(tracker.current_epoch(), 10)
  assert_eq(tracker.observed_checkpoint_count(), 1)
}

///|
test "gap recovery rejects invalid requests and oversized peer responses" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("anchor-gap-bounds-authority")
  let session = "world-1:anchor-gap-bounds"
  let base = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("bounds-root-10"),
    size: 10,
  }
  let envelope_10 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    10,
    @bft.Digest("bounds-checkpoint-9"),
    base,
  )
  let head_10 = open_anchor_envelope_for_transport_test(
    hasher, verifier, authority, session, envelope_10,
  )
  let envelope_11 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("bounds-root-11"), size: 11 },
  )
  let oversized = FixedObserverSigningAnchorGapTransport::{
    result: ObserverSigningAnchorGapFetched({
      envelopes: [envelope_11, envelope_11],
    }),
  }
  let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_10)
  assert_eq(
    tracker.recover_gap(
      hasher,
      verifier,
      oversized,
      target_epoch=11,
      max_items=1,
    ),
    OpenWorldObserverSigningAnchorGapRecoveryResult::ObserverSigningAnchorGapRecoveryMalformedResponse,
  )
  assert_eq(
    tracker.recover_gap(
      hasher,
      verifier,
      oversized,
      target_epoch=10,
      max_items=1,
    ),
    OpenWorldObserverSigningAnchorGapRecoveryResult::ObserverSigningAnchorGapRecoveryInvalidRequest,
  )
  assert_eq(tracker.current_epoch(), 10)
  assert_eq(tracker.observed_checkpoint_count(), 1)
}

///|
test "gap source ambiguity is not mistaken for authority fork evidence" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("anchor-gap-ambiguous-authority")
  let session = "world-1:anchor-gap-ambiguous"
  let base = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("ambiguous-root-10"),
    size: 10,
  }
  let envelope_10 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    10,
    @bft.Digest("ambiguous-checkpoint-9"),
    base,
  )
  let head_10 = open_anchor_envelope_for_transport_test(
    hasher, verifier, authority, session, envelope_10,
  )
  let left_11 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("ambiguous-left-root-11"), size: 11 },
  )
  let right_11 = signing_anchor_envelope_for_transport_test(
    hasher,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("ambiguous-right-root-11"), size: 11 },
  )
  let transport = OpenWorldInMemoryObserverSigningAnchorGapTransport::new([
    left_11, right_11,
  ])
  let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_10)
  assert_eq(
    tracker.recover_gap(
      hasher,
      verifier,
      transport,
      target_epoch=11,
      max_items=2,
    ),
    OpenWorldObserverSigningAnchorGapRecoveryResult::ObserverSigningAnchorGapRecoverySourceAmbiguous(
      2,
    ),
  )
  assert_eq(tracker.current_epoch(), 10)
  assert_eq(tracker.observed_checkpoint_count(), 1)
}
