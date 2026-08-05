///|
fn transparency_verified_checkpoint(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  signer : &@bft.Signer,
  checkpoint : @checkpoint.Checkpoint,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let signed = @checkpoint.sign_checkpoint(hasher, signer, checkpoint)
  match
    @checkpoint.open_checkpoint(hasher, verifier, signer.public_key(), signed) {
    Opened(value) => value
    _ => fail("expected verified checkpoint")
  }
}

///|
test "independent transparency checkpoint publishes exact audit and seal" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-authority")
  let publisher = @bft.MockSigner::new("transparency-publisher")
  let world_id = "world:transparency"
  let log_session_id = "world:transparency:log"
  let audit = transparency_verified_checkpoint(hasher, verifier, authority, {
    session_id: world_id,
    epoch: 10,
    previous_checkpoint: @bft.Digest("world-9"),
    manifest_digest: @bft.Digest("audit-manifest"),
    event_root: @bft.Digest("audit-events"),
    public_state_root: @bft.Digest("audit-state"),
    asset_delta_root: @bft.Digest("audit-assets"),
    hidden_state_commitment: None,
  })
  let seal = transparency_verified_checkpoint(hasher, verifier, authority, {
    session_id: world_id,
    epoch: 11,
    previous_checkpoint: audit.digest(),
    manifest_digest: @bft.Digest("seal-manifest"),
    event_root: @bft.Digest("seal-events"),
    public_state_root: @bft.Digest("seal-state"),
    asset_delta_root: @bft.Digest("seal-assets"),
    hidden_state_commitment: None,
  })
  let published = @authmap.AuthenticatedMap::new(hasher)
  let audit_key = open_world_audit_transparency_plan_key(
    world_id~,
    audit_epoch=10,
  )
  let seal_key = open_world_audit_transparency_seal_key(
    world_id~,
    audit_epoch=10,
  )
  ignore(
    published.put(
      audit_key,
      open_world_audit_transparency_plan_value(
        audit_checkpoint_digest=audit.digest(),
      ),
    ),
  )
  ignore(
    published.put(
      seal_key,
      open_world_audit_transparency_seal_value(
        audit_checkpoint_digest=audit.digest(),
        seal_checkpoint_digest=seal.digest(),
      ),
    ),
  )
  let publication = @checkpoint.sign_checkpoint(hasher, publisher, {
    session_id: log_session_id,
    epoch: 4,
    previous_checkpoint: @bft.Digest("transparency-3"),
    manifest_digest: open_world_audit_transparency_log_manifest(
      hasher,
      log_session_id~,
    ),
    event_root: @bft.Digest("transparency-events"),
    public_state_root: published.root(),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: None,
  })
  let audit_proof = published.proof(audit_key).unwrap()
  let seal_proof = published.proof(seal_key).unwrap()
  let envelope = OpenWorldAuditTransparencyEnvelope::{
    signed_checkpoint: publication,
    audit_membership_proof: audit_proof,
    seal_membership_proof: seal_proof,
  }
  match
    open_open_world_audit_transparency_envelope(
      hasher,
      verifier,
      expected_publisher_key=publisher.public_key(),
      expected_publication_checkpoint_digest=publication.digest,
      log_session_id~,
      world_id~,
      audit_checkpoint=audit,
      seal_checkpoint=seal,
      envelope~,
    ) {
    AuditTransparencyOpened(value) => {
      assert_eq(value.publication_checkpoint_digest(), publication.digest)
      assert_eq(value.audit_checkpoint_digest(), audit.digest())
      assert_eq(value.seal_checkpoint_digest(), seal.digest())
    }
    _ => fail("expected published audit transparency capability")
  }
  assert_true(
    open_open_world_audit_transparency_envelope(
      hasher,
      verifier,
      expected_publisher_key=publisher.public_key(),
      expected_publication_checkpoint_digest=@bft.Digest("foreign-head"),
      log_session_id~,
      world_id~,
      audit_checkpoint=audit,
      seal_checkpoint=seal,
      envelope~,
    )
    is AuditTransparencyRefused(AuditTransparencyExpectedCheckpointMismatch),
  )
  let forged = OpenWorldAuditTransparencyEnvelope::{
    ..envelope,
    seal_membership_proof: audit_proof,
  }
  assert_true(
    open_open_world_audit_transparency_envelope(
      hasher,
      verifier,
      expected_publisher_key=publisher.public_key(),
      expected_publication_checkpoint_digest=publication.digest,
      log_session_id~,
      world_id~,
      audit_checkpoint=audit,
      seal_checkpoint=seal,
      envelope=forged,
    )
    is AuditTransparencyRefused(AuditTransparencySealMembershipInvalid),
  )
}
