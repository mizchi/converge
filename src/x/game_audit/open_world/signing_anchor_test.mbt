///|
fn signing_anchor_checkpoint(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  log_session_id : String,
  manifest_digest : @bft.Digest,
  anchor_state_root : @bft.Digest,
  epoch? : Int = 41,
  previous_checkpoint? : @bft.Digest = @bft.Digest("observer-anchor-batch-40"),
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id: log_session_id,
    epoch,
    previous_checkpoint,
    manifest_digest,
    event_root: @bft.Digest("observer-anchor-publication-events"),
    public_state_root: anchor_state_root,
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: None,
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
    _ => fail("expected verified observer anchor checkpoint")
  }
}

///|
fn published_anchor_for_head_test(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  log_session_id : String,
  epoch : Int,
  previous_checkpoint : @bft.Digest,
  anchor : OpenWorldObserverSigningAnchor,
) -> PublishedOpenWorldObserverSigningAnchor raise Error {
  let anchor_map = @authmap.AuthenticatedMap::new(hasher)
  let key = open_world_observer_signing_anchor_key(anchor)
  ignore(anchor_map.put(key, open_world_observer_signing_anchor_value(anchor)))
  let checkpoint = signing_anchor_checkpoint(
    hasher,
    verifier,
    authority,
    log_session_id,
    open_world_observer_signing_anchor_log_manifest(hasher, log_session_id~),
    anchor_map.root(),
    epoch~,
    previous_checkpoint~,
  )
  let proof = match anchor_map.proof(key) {
    Some(proof) => proof
    None => fail("expected signing anchor head proof")
  }
  match
    open_published_open_world_observer_signing_anchor(
      hasher,
      checkpoint,
      log_session_id~,
      anchor~,
      membership_proof=proof,
    ) {
    ObserverSigningAnchorPublished(published) => published
    _ => fail("expected published signing anchor head")
  }
}

///|
test "authority checkpoint publishes anchor used for exact restore and rollback rejection" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("observer-anchor-authority")
  let signer = @bft.MockSigner::new("published-observer-key")
  let store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  let ledger = match
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      signer,
      observer_id="published-observer",
      store~,
    ) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => fail("expected signing ledger for published observer")
  }
  ignore(
    ledger.sign_registration(
      audit_checkpoint_digest=@bft.Digest("published-audit-plan"),
      registration_index=7,
      encounter_digest=@bft.Digest("published-encounter"),
    ),
  )
  let anchor = ledger.anchor()
  let log_session_id = "world-1:observer-signing-anchors"
  let anchor_map = @authmap.AuthenticatedMap::new(hasher)
  ignore(anchor_map.put("another-observer-key", "another-observer-anchor"))
  ignore(
    anchor_map.put(
      open_world_observer_signing_anchor_key(anchor),
      open_world_observer_signing_anchor_value(anchor),
    ),
  )
  let checkpoint = signing_anchor_checkpoint(
    hasher,
    verifier,
    authority,
    log_session_id,
    open_world_observer_signing_anchor_log_manifest(hasher, log_session_id~),
    anchor_map.root(),
  )
  let proof = match
    anchor_map.proof(open_world_observer_signing_anchor_key(anchor)) {
    Some(proof) => proof
    None => fail("expected observer anchor membership proof")
  }
  let published = match
    open_published_open_world_observer_signing_anchor(
      hasher,
      checkpoint,
      log_session_id~,
      anchor~,
      membership_proof=proof,
    ) {
    ObserverSigningAnchorPublished(published) => published
    ObserverSigningAnchorPublicationRefused(_) =>
      fail("expected published observer signing anchor")
  }
  assert_eq(published.anchor(), anchor)
  assert_eq(published.publication_checkpoint_digest(), checkpoint.digest())
  assert_eq(
    published.previous_checkpoint_digest(),
    @bft.Digest("observer-anchor-batch-40"),
  )
  assert_eq(published.publisher_key(), authority.public_key())
  assert_eq(published.log_session_id(), log_session_id)
  assert_eq(published.log_epoch(), 41)
  match
    OpenWorldObserverSigningLedger::new_with_published_anchor(
      hasher,
      signer,
      observer_id="published-observer",
      store~,
      published_anchor=published,
    ) {
    ObserverSigningLedgerReady(_) => ()
    _ => fail("expected exact published anchor restore")
  }
  let rolled_back_store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  assert_true(
    OpenWorldObserverSigningLedger::new_with_published_anchor(
      hasher,
      signer,
      observer_id="published-observer",
      store=rolled_back_store,
      published_anchor=published,
    )
    is ObserverSigningStoreAnchorMismatch,
  )
}

///|
test "observer signing anchor publication rejects invalid boundaries and proofs" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("observer-anchor-authority")
  let log_session_id = "world-1:observer-signing-anchors"
  let anchor = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("observer-root-1"),
    size: 3,
  }
  let anchor_map = @authmap.AuthenticatedMap::new(hasher)
  ignore(
    anchor_map.put(
      open_world_observer_signing_anchor_key(anchor),
      open_world_observer_signing_anchor_value(anchor),
    ),
  )
  let checkpoint = signing_anchor_checkpoint(
    hasher,
    verifier,
    authority,
    log_session_id,
    open_world_observer_signing_anchor_log_manifest(hasher, log_session_id~),
    anchor_map.root(),
  )
  let proof = match
    anchor_map.proof(open_world_observer_signing_anchor_key(anchor)) {
    Some(proof) => proof
    None => fail("expected observer anchor proof")
  }
  let invalid_anchor = OpenWorldObserverSigningAnchor::{ ..anchor, size: -1 }
  assert_eq(
    open_published_open_world_observer_signing_anchor(
      hasher,
      checkpoint,
      log_session_id~,
      anchor=invalid_anchor,
      membership_proof=proof,
    ),
    OpenWorldObserverSigningAnchorPublicationResult::ObserverSigningAnchorPublicationRefused(
      InvalidObserverSigningAnchor,
    ),
  )
  assert_eq(
    open_published_open_world_observer_signing_anchor(
      hasher,
      checkpoint,
      log_session_id="world-2:observer-signing-anchors",
      anchor~,
      membership_proof=proof,
    ),
    OpenWorldObserverSigningAnchorPublicationResult::ObserverSigningAnchorPublicationRefused(
      ObserverSigningAnchorLogSessionMismatch,
    ),
  )
  let wrong_manifest = signing_anchor_checkpoint(
    hasher,
    verifier,
    authority,
    log_session_id,
    @bft.Digest("wrong-anchor-log-manifest"),
    anchor_map.root(),
  )
  assert_eq(
    open_published_open_world_observer_signing_anchor(
      hasher,
      wrong_manifest,
      log_session_id~,
      anchor~,
      membership_proof=proof,
    ),
    OpenWorldObserverSigningAnchorPublicationResult::ObserverSigningAnchorPublicationRefused(
      ObserverSigningAnchorLogManifestMismatch,
    ),
  )
  let substituted = OpenWorldObserverSigningAnchor::{
    ..anchor,
    root: @bft.Digest("substituted-observer-root"),
  }
  assert_eq(
    open_published_open_world_observer_signing_anchor(
      hasher,
      checkpoint,
      log_session_id~,
      anchor=substituted,
      membership_proof=proof,
    ),
    OpenWorldObserverSigningAnchorPublicationResult::ObserverSigningAnchorPublicationRefused(
      ObserverSigningAnchorMembershipProofInvalid,
    ),
  )
  let replaced_map = @authmap.AuthenticatedMap::new(hasher)
  ignore(
    replaced_map.put(
      open_world_observer_signing_anchor_key(anchor),
      open_world_observer_signing_anchor_value(anchor),
    ),
  )
  ignore(
    replaced_map.put(
      open_world_observer_signing_anchor_key(substituted),
      open_world_observer_signing_anchor_value(substituted),
    ),
  )
  assert_eq(replaced_map.size(), 1)
  let replaced_checkpoint = signing_anchor_checkpoint(
    hasher,
    verifier,
    authority,
    log_session_id,
    open_world_observer_signing_anchor_log_manifest(hasher, log_session_id~),
    replaced_map.root(),
  )
  let replaced_proof = match
    replaced_map.proof(open_world_observer_signing_anchor_key(anchor)) {
    Some(proof) => proof
    None => fail("expected replaced observer anchor proof")
  }
  assert_eq(
    open_published_open_world_observer_signing_anchor(
      hasher,
      replaced_checkpoint,
      log_session_id~,
      anchor~,
      membership_proof=replaced_proof,
    ),
    OpenWorldObserverSigningAnchorPublicationResult::ObserverSigningAnchorPublicationRefused(
      ObserverSigningAnchorMembershipProofInvalid,
    ),
  )
  match
    open_published_open_world_observer_signing_anchor(
      hasher,
      replaced_checkpoint,
      log_session_id~,
      anchor=substituted,
      membership_proof=replaced_proof,
    ) {
    ObserverSigningAnchorPublished(_) => ()
    _ => fail("expected the unique replacement anchor to be published")
  }
}

///|
test "anchor head tracker advances one parent at a time and deduplicates history" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("head-authority")
  let session = "world-1:anchor-heads"
  let anchor_41 = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("root-41"),
    size: 41,
  }
  let head_41 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    41,
    @bft.Digest("head-40"),
    anchor_41,
  )
  let anchor_42 = OpenWorldObserverSigningAnchor::{
    ..anchor_41,
    root: @bft.Digest("root-42"),
    size: 42,
  }
  let head_42 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    42,
    head_41.publication_checkpoint_digest(),
    anchor_42,
  )
  let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_41)
  assert_eq(tracker.log_session_id(), session)
  assert_eq(tracker.publisher_key(), authority.public_key())
  assert_eq(
    tracker.deliver(head_42),
    OpenWorldObserverSigningAnchorHeadDelivery::SigningAnchorHeadAdvanced,
  )
  assert_eq(tracker.current_epoch(), 42)
  assert_eq(tracker.observed_checkpoint_count(), 2)
  assert_eq(
    tracker.current_checkpoint_digest(),
    head_42.publication_checkpoint_digest(),
  )
  assert_eq(
    tracker.deliver(head_42),
    OpenWorldObserverSigningAnchorHeadDelivery::SigningAnchorHeadDuplicate,
  )
  assert_eq(
    tracker.deliver(head_41),
    OpenWorldObserverSigningAnchorHeadDelivery::SigningAnchorHeadDuplicate,
  )
}

///|
test "anchor head tracker creates evidence for same-epoch and parent forks" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("fork-authority")
  let session = "world-1:fork-heads"
  let base = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("base-root"),
    size: 10,
  }
  let head_10 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    10,
    @bft.Digest("head-9"),
    base,
  )
  let fork_a = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("fork-a"), size: 11 },
  )
  let fork_b = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("fork-b"), size: 12 },
  )
  let same_epoch_tracker = OpenWorldObserverSigningAnchorHeadTracker::new(
    fork_a,
  )
  match same_epoch_tracker.deliver(fork_b) {
    SigningAnchorHeadForkDetected(evidence) => {
      assert_eq(evidence.kind(), SameEpochSigningAnchorCheckpoint)
      assert_eq(evidence.log_session_id(), session)
      assert_eq(evidence.publisher_key(), authority.public_key())
      assert_eq(evidence.accepted_epoch(), 11)
      assert_eq(evidence.observed_epoch(), 11)
      assert_not_eq(
        evidence.accepted_checkpoint_digest(),
        evidence.conflicting_checkpoint_digest(),
      )
      assert_eq(
        evidence.conflicting_previous_checkpoint_digest(),
        head_10.publication_checkpoint_digest(),
      )
    }
    _ => fail("expected same-epoch signing anchor fork evidence")
  }
  let wrong_parent = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    11,
    @bft.Digest("different-head-10"),
    { ..base, root: @bft.Digest("wrong-parent"), size: 11 },
  )
  let parent_tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_10)
  match parent_tracker.deliver(wrong_parent) {
    SigningAnchorHeadForkDetected(evidence) => {
      assert_eq(evidence.kind(), WrongParentSigningAnchorCheckpoint)
      assert_eq(evidence.accepted_epoch(), 10)
      assert_eq(evidence.observed_epoch(), 11)
      assert_eq(
        evidence.accepted_checkpoint_digest(),
        head_10.publication_checkpoint_digest(),
      )
      assert_eq(
        evidence.conflicting_checkpoint_digest(),
        wrong_parent.publication_checkpoint_digest(),
      )
      assert_eq(
        evidence.conflicting_previous_checkpoint_digest(),
        @bft.Digest("different-head-10"),
      )
    }
    _ => fail("expected wrong-parent signing anchor fork evidence")
  }
}

///|
test "anchor head gaps stale checkpoints and foreign boundaries do not accuse" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("boundary-authority")
  let foreign_authority = @bft.MockSigner::new("foreign-head-authority")
  let session = "world-1:boundary-heads"
  let anchor = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("boundary-root"),
    size: 10,
  }
  let head_10 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    10,
    @bft.Digest("head-9"),
    anchor,
  )
  let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_10)
  let gap = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    13,
    @bft.Digest("head-12"),
    { ..anchor, root: @bft.Digest("gap-root"), size: 13 },
  )
  assert_eq(
    tracker.deliver(gap),
    OpenWorldObserverSigningAnchorHeadDelivery::SigningAnchorHeadGap(11, 13),
  )
  let stale = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    9,
    @bft.Digest("head-8"),
    { ..anchor, root: @bft.Digest("stale-root"), size: 9 },
  )
  assert_eq(
    tracker.deliver(stale),
    OpenWorldObserverSigningAnchorHeadDelivery::SigningAnchorHeadStale,
  )
  let foreign_session = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    "world-2:boundary-heads",
    10,
    @bft.Digest("head-9"),
    anchor,
  )
  assert_eq(
    tracker.deliver(foreign_session),
    OpenWorldObserverSigningAnchorHeadDelivery::SigningAnchorHeadBoundaryMismatch,
  )
  let foreign_publisher = published_anchor_for_head_test(
    hasher,
    verifier,
    foreign_authority,
    session,
    10,
    @bft.Digest("head-9"),
    anchor,
  )
  assert_eq(
    tracker.deliver(foreign_publisher),
    OpenWorldObserverSigningAnchorHeadDelivery::SigningAnchorHeadBoundaryMismatch,
  )
  assert_eq(tracker.current_epoch(), 10)
}

///|
test "anchor head batch fills a gap atomically and is idempotent" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("batch-authority")
  let session = "world-1:batch-heads"
  let base = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("batch-root-10"),
    size: 10,
  }
  let head_10 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    10,
    @bft.Digest("batch-head-9"),
    base,
  )
  let head_11 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("batch-root-11"), size: 11 },
  )
  let head_12 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    12,
    head_11.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("batch-root-12"), size: 12 },
  )
  let head_13 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    13,
    head_12.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("batch-root-13"), size: 13 },
  )
  let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_10)
  assert_eq(
    tracker.deliver(head_13),
    OpenWorldObserverSigningAnchorHeadDelivery::SigningAnchorHeadGap(11, 13),
  )
  assert_eq(
    tracker.deliver_batch([head_11, head_12, head_13]),
    OpenWorldObserverSigningAnchorHeadBatchDelivery::SigningAnchorHeadBatchAdvanced(
      3,
    ),
  )
  assert_eq(tracker.current_epoch(), 13)
  assert_eq(tracker.observed_checkpoint_count(), 4)
  assert_eq(
    tracker.deliver_batch([head_11, head_12, head_13]),
    OpenWorldObserverSigningAnchorHeadBatchDelivery::SigningAnchorHeadBatchNoChange,
  )
  assert_eq(
    tracker.deliver_batch([]),
    OpenWorldObserverSigningAnchorHeadBatchDelivery::SigningAnchorHeadBatchNoChange,
  )
}

///|
test "invalid anchor head batches roll back every planned advance" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("batch-rollback-authority")
  let session = "world-1:batch-rollback-heads"
  let base = OpenWorldObserverSigningAnchor::{
    observer_id: "observer-1",
    signer_key: @bft.PublicKey("observer-key-1"),
    root: @bft.Digest("rollback-root-10"),
    size: 10,
  }
  let head_10 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    10,
    @bft.Digest("rollback-head-9"),
    base,
  )
  let head_11 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("rollback-root-11"), size: 11 },
  )
  let wrong_parent_12 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    12,
    @bft.Digest("wrong-head-11"),
    { ..base, root: @bft.Digest("wrong-parent-root-12"), size: 12 },
  )
  let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(head_10)
  match tracker.deliver_batch([head_11, wrong_parent_12]) {
    SigningAnchorHeadBatchForkDetected(index, evidence) => {
      assert_eq(index, 1)
      assert_eq(evidence.kind(), WrongParentSigningAnchorCheckpoint)
    }
    _ => fail("expected atomic batch parent-fork rejection")
  }
  assert_eq(tracker.current_epoch(), 10)
  assert_eq(tracker.observed_checkpoint_count(), 1)
  let head_13 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    13,
    @bft.Digest("head-12"),
    { ..base, root: @bft.Digest("gap-root-13"), size: 13 },
  )
  assert_eq(
    tracker.deliver_batch([head_11, head_13]),
    OpenWorldObserverSigningAnchorHeadBatchDelivery::SigningAnchorHeadBatchGap(
      1, 12, 13,
    ),
  )
  assert_eq(tracker.current_epoch(), 10)
  let foreign = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    "world-2:batch-rollback-heads",
    12,
    head_11.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("foreign-root-12"), size: 12 },
  )
  assert_eq(
    tracker.deliver_batch([head_11, foreign]),
    OpenWorldObserverSigningAnchorHeadBatchDelivery::SigningAnchorHeadBatchBoundaryMismatch(
      1,
    ),
  )
  assert_eq(tracker.current_epoch(), 10)
  let stale = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    9,
    @bft.Digest("rollback-head-8"),
    { ..base, root: @bft.Digest("rollback-stale-root-9"), size: 9 },
  )
  assert_eq(
    tracker.deliver_batch([stale]),
    OpenWorldObserverSigningAnchorHeadBatchDelivery::SigningAnchorHeadBatchStale(
      0, 9,
    ),
  )
  assert_eq(tracker.current_epoch(), 10)
  let conflicting_11 = published_anchor_for_head_test(
    hasher,
    verifier,
    authority,
    session,
    11,
    head_10.publication_checkpoint_digest(),
    { ..base, root: @bft.Digest("conflicting-root-11"), size: 111 },
  )
  match tracker.deliver_batch([head_11, conflicting_11]) {
    SigningAnchorHeadBatchForkDetected(index, evidence) => {
      assert_eq(index, 1)
      assert_eq(evidence.kind(), SameEpochSigningAnchorCheckpoint)
    }
    _ => fail("expected within-batch same-epoch fork rejection")
  }
  assert_eq(tracker.current_epoch(), 10)
  assert_eq(tracker.observed_checkpoint_count(), 1)
}
