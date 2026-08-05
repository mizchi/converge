///|
/// Domain manifest for checkpoints published by an independent audit log.
pub fn open_world_audit_transparency_log_manifest(
  hasher : &@bft.Hasher,
  log_session_id~ : String,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-audit-transparency-log-v1")
  append_field(buffer, log_session_id)
  hasher.hash_string(buffer.to_string())
}

///|
pub fn open_world_audit_transparency_plan_key(
  world_id~ : String,
  audit_epoch~ : Int,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-audit-transparency-plan-key-v1")
  append_field(buffer, world_id)
  append_field(buffer, audit_epoch.to_string())
  buffer.to_string()
}

///|
pub fn open_world_audit_transparency_seal_key(
  world_id~ : String,
  audit_epoch~ : Int,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-audit-transparency-seal-key-v1")
  append_field(buffer, world_id)
  append_field(buffer, audit_epoch.to_string())
  buffer.to_string()
}

///|
pub fn open_world_audit_transparency_plan_value(
  audit_checkpoint_digest~ : @bft.Digest,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-audit-transparency-plan-value-v1")
  append_field(buffer, audit_checkpoint_digest.0)
  buffer.to_string()
}

///|
pub fn open_world_audit_transparency_seal_value(
  audit_checkpoint_digest~ : @bft.Digest,
  seal_checkpoint_digest~ : @bft.Digest,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "open-world-audit-transparency-seal-value-v1")
  append_field(buffer, audit_checkpoint_digest.0)
  append_field(buffer, seal_checkpoint_digest.0)
  buffer.to_string()
}

///|
/// Open a publication capability only after authenticating the independent
/// checkpoint and both exact authenticated-map entries.
pub fn open_open_world_audit_transparency_envelope(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  expected_publisher_key~ : @bft.PublicKey,
  expected_publication_checkpoint_digest~ : @bft.Digest,
  log_session_id~ : String,
  world_id~ : String,
  audit_checkpoint~ : @checkpoint.VerifiedCheckpoint,
  seal_checkpoint~ : @checkpoint.VerifiedCheckpoint,
  envelope~ : OpenWorldAuditTransparencyEnvelope,
) -> OpenWorldAuditTransparencyOpenResult {
  let publication = match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      expected_publisher_key,
      envelope.signed_checkpoint,
    ) {
    Opened(value) => value
    Refused(reason) =>
      return AuditTransparencyRefused(
        AuditTransparencyCheckpointRefused(reason),
      )
  }
  if publication.digest() != expected_publication_checkpoint_digest {
    return AuditTransparencyRefused(AuditTransparencyExpectedCheckpointMismatch)
  }
  let audit = audit_checkpoint.checkpoint()
  let seal = seal_checkpoint.checkpoint()
  if world_id == "" || audit.session_id != world_id {
    return AuditTransparencyRefused(AuditTransparencyAuditBoundaryMismatch)
  }
  if seal.session_id != world_id ||
    seal.epoch != audit.epoch + 1 ||
    seal.previous_checkpoint != audit_checkpoint.digest() {
    return AuditTransparencyRefused(AuditTransparencySealBoundaryMismatch)
  }
  let published = publication.checkpoint()
  if log_session_id == "" || published.session_id != log_session_id {
    return AuditTransparencyRefused(AuditTransparencySessionMismatch)
  }
  let manifest_matches = published.manifest_digest ==
    open_world_audit_transparency_log_manifest(hasher, log_session_id~)
  if !manifest_matches {
    return AuditTransparencyRefused(AuditTransparencyManifestMismatch)
  }
  let audit_key = open_world_audit_transparency_plan_key(
    world_id~,
    audit_epoch=audit.epoch,
  )
  let audit_value = open_world_audit_transparency_plan_value(
    audit_checkpoint_digest=audit_checkpoint.digest(),
  )
  let audit_membership_valid = envelope.audit_membership_proof.key == audit_key &&
    envelope.audit_membership_proof.value == audit_value &&
    @authmap.verify_membership(
      hasher,
      published.public_state_root,
      envelope.audit_membership_proof,
    )
  if !audit_membership_valid {
    return AuditTransparencyRefused(AuditTransparencyPlanMembershipInvalid)
  }
  let seal_key = open_world_audit_transparency_seal_key(
    world_id~,
    audit_epoch=audit.epoch,
  )
  let seal_value = open_world_audit_transparency_seal_value(
    audit_checkpoint_digest=audit_checkpoint.digest(),
    seal_checkpoint_digest=seal_checkpoint.digest(),
  )
  let seal_membership_valid = envelope.seal_membership_proof.key == seal_key &&
    envelope.seal_membership_proof.value == seal_value &&
    @authmap.verify_membership(
      hasher,
      published.public_state_root,
      envelope.seal_membership_proof,
    )
  if !seal_membership_valid {
    return AuditTransparencyRefused(AuditTransparencySealMembershipInvalid)
  }
  if !@audit.open_world_audit_transparency_allowed(
      trusted_publication_boundary=true,
      audit_checkpoint_authenticated=true,
      seal_checkpoint_authenticated=true,
      transparency_manifest_matches=manifest_matches,
      audit_membership_valid~,
      seal_membership_valid~,
    ) {
    return AuditTransparencyRefused(AuditTransparencySealMembershipInvalid)
  }
  AuditTransparencyOpened(PublishedOpenWorldAuditTransparency::{
    publication_checkpoint_digest: publication.digest(),
    previous_checkpoint_digest: published.previous_checkpoint,
    publisher_key: publication.authority_key(),
    log_session_id,
    log_epoch: published.epoch,
    world_id,
    audit_checkpoint_digest: audit_checkpoint.digest(),
    seal_checkpoint_digest: seal_checkpoint.digest(),
  })
}

///|
pub fn PublishedOpenWorldAuditTransparency::publication_checkpoint_digest(
  self : PublishedOpenWorldAuditTransparency,
) -> @bft.Digest {
  self.publication_checkpoint_digest
}

///|
pub fn PublishedOpenWorldAuditTransparency::previous_checkpoint_digest(
  self : PublishedOpenWorldAuditTransparency,
) -> @bft.Digest {
  self.previous_checkpoint_digest
}

///|
pub fn PublishedOpenWorldAuditTransparency::publisher_key(
  self : PublishedOpenWorldAuditTransparency,
) -> @bft.PublicKey {
  self.publisher_key
}

///|
pub fn PublishedOpenWorldAuditTransparency::log_session_id(
  self : PublishedOpenWorldAuditTransparency,
) -> String {
  self.log_session_id
}

///|
pub fn PublishedOpenWorldAuditTransparency::log_epoch(
  self : PublishedOpenWorldAuditTransparency,
) -> Int {
  self.log_epoch
}

///|
pub fn PublishedOpenWorldAuditTransparency::world_id(
  self : PublishedOpenWorldAuditTransparency,
) -> String {
  self.world_id
}

///|
pub fn PublishedOpenWorldAuditTransparency::audit_checkpoint_digest(
  self : PublishedOpenWorldAuditTransparency,
) -> @bft.Digest {
  self.audit_checkpoint_digest
}

///|
pub fn PublishedOpenWorldAuditTransparency::seal_checkpoint_digest(
  self : PublishedOpenWorldAuditTransparency,
) -> @bft.Digest {
  self.seal_checkpoint_digest
}
