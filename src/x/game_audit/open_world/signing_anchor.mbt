///|
/// Domain-separate an authority checkpoint used as an observer-anchor batch.
pub fn open_world_observer_signing_anchor_log_manifest(
  hasher : &@bft.Hasher,
  log_session_id~ : String,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-observer-signing-anchor-log-v1")
  append_field(buffer, log_session_id)
  hasher.hash_string(buffer.to_string())
}

///|
/// Canonical authenticated-map key for one observer signing identity.
pub fn open_world_observer_signing_anchor_key(
  anchor : OpenWorldObserverSigningAnchor,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-observer-signing-anchor-key-v1")
  append_field(buffer, anchor.observer_id)
  append_field(buffer, anchor.signer_key.0)
  buffer.to_string()
}

///|
/// Canonical authenticated-map value for one observer signing snapshot.
pub fn open_world_observer_signing_anchor_value(
  anchor : OpenWorldObserverSigningAnchor,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-observer-signing-anchor-value-v1")
  append_field(buffer, anchor.root.0)
  append_field(buffer, anchor.size.to_string())
  buffer.to_string()
}

///|
fn open_world_observer_signing_anchor_valid(
  anchor : OpenWorldObserverSigningAnchor,
) -> Bool {
  anchor.observer_id != "" &&
  anchor.signer_key.0 != "" &&
  anchor.root.0 != "" &&
  anchor.size >= 0
}

///|
/// Verify that an already authority-verified checkpoint published one exact
/// observer anchor under the expected log session and domain manifest.
pub fn open_published_open_world_observer_signing_anchor(
  hasher : &@bft.Hasher,
  publication_checkpoint : @checkpoint.VerifiedCheckpoint,
  log_session_id~ : String,
  anchor~ : OpenWorldObserverSigningAnchor,
  membership_proof~ : @authmap.AuthMapProof,
) -> OpenWorldObserverSigningAnchorPublicationResult {
  let checkpoint = publication_checkpoint.checkpoint()
  let anchor_valid = open_world_observer_signing_anchor_valid(anchor)
  let log_session_matches = log_session_id != "" &&
    checkpoint.session_id == log_session_id
  let log_manifest_matches = checkpoint.manifest_digest ==
    open_world_observer_signing_anchor_log_manifest(hasher, log_session_id~)
  let membership_proof_valid = if anchor_valid &&
    log_session_matches &&
    log_manifest_matches {
    membership_proof.key == open_world_observer_signing_anchor_key(anchor) &&
    membership_proof.value == open_world_observer_signing_anchor_value(anchor) &&
    @authmap.verify_membership(
      hasher,
      checkpoint.public_state_root,
      membership_proof,
    )
  } else {
    false
  }
  match
    @audit.classify_open_world_signing_anchor_publication(
      anchor_valid~,
      log_session_matches~,
      log_manifest_matches~,
      membership_proof_valid~,
    ) {
    @audit.OpenWorldSigningAnchorPublicationDecision::RejectInvalidSigningAnchor =>
      ObserverSigningAnchorPublicationRefused(InvalidObserverSigningAnchor)
    @audit.OpenWorldSigningAnchorPublicationDecision::RejectSigningAnchorLogSession =>
      ObserverSigningAnchorPublicationRefused(
        ObserverSigningAnchorLogSessionMismatch,
      )
    @audit.OpenWorldSigningAnchorPublicationDecision::RejectSigningAnchorLogManifest =>
      ObserverSigningAnchorPublicationRefused(
        ObserverSigningAnchorLogManifestMismatch,
      )
    @audit.OpenWorldSigningAnchorPublicationDecision::RejectSigningAnchorMembership =>
      ObserverSigningAnchorPublicationRefused(
        ObserverSigningAnchorMembershipProofInvalid,
      )
    @audit.OpenWorldSigningAnchorPublicationDecision::PublishSigningAnchor =>
      ObserverSigningAnchorPublished(PublishedOpenWorldObserverSigningAnchor::{
        anchor,
        publication_checkpoint_digest: publication_checkpoint.digest(),
        previous_checkpoint_digest: checkpoint.previous_checkpoint,
        publisher_key: publication_checkpoint.authority_key(),
        log_session_id,
        log_epoch: checkpoint.epoch,
      })
  }
}

///|
pub fn PublishedOpenWorldObserverSigningAnchor::anchor(
  self : PublishedOpenWorldObserverSigningAnchor,
) -> OpenWorldObserverSigningAnchor {
  self.anchor
}

///|
pub fn PublishedOpenWorldObserverSigningAnchor::publication_checkpoint_digest(
  self : PublishedOpenWorldObserverSigningAnchor,
) -> @bft.Digest {
  self.publication_checkpoint_digest
}

///|
pub fn PublishedOpenWorldObserverSigningAnchor::previous_checkpoint_digest(
  self : PublishedOpenWorldObserverSigningAnchor,
) -> @bft.Digest {
  self.previous_checkpoint_digest
}

///|
pub fn PublishedOpenWorldObserverSigningAnchor::publisher_key(
  self : PublishedOpenWorldObserverSigningAnchor,
) -> @bft.PublicKey {
  self.publisher_key
}

///|
pub fn PublishedOpenWorldObserverSigningAnchor::log_session_id(
  self : PublishedOpenWorldObserverSigningAnchor,
) -> String {
  self.log_session_id
}

///|
pub fn PublishedOpenWorldObserverSigningAnchor::log_epoch(
  self : PublishedOpenWorldObserverSigningAnchor,
) -> Int {
  self.log_epoch
}

///|
/// Restore only from an anchor whose publication was authenticated first.
pub fn OpenWorldObserverSigningLedger::new_with_published_anchor(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  observer_id~ : String,
  store~ : &OpenWorldObserverSigningStore,
  published_anchor~ : PublishedOpenWorldObserverSigningAnchor,
) -> OpenWorldObserverSigningLedgerBuildResult {
  build_open_world_observer_signing_ledger(
    hasher,
    signer,
    observer_id~,
    storage=ExternalSigningStorage(store),
    trusted_anchor=Some(published_anchor.anchor),
  )
}
