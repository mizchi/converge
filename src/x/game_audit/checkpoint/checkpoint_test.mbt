///|
fn candidate() -> Checkpoint {
  {
    session_id: "dungeon-42",
    epoch: 7,
    previous_checkpoint: @bft.Digest("previous"),
    manifest_digest: @bft.Digest("manifest"),
    event_root: @bft.Digest("events"),
    public_state_root: @bft.Digest("state"),
    asset_delta_root: @bft.Digest("items"),
    hidden_state_commitment: None,
  }
}

///|
test "authority signs and verifies a complete checkpoint" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let signed = sign_checkpoint(hasher, authority, candidate())
  assert_eq(
    verify_checkpoint(hasher, verifier, authority.public_key(), signed),
    CheckpointVerification::Verified,
  )
}

///|
test "tampering with an event root invalidates the checkpoint digest" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let signed = sign_checkpoint(hasher, authority, candidate())
  let tampered : SignedCheckpoint = {
    checkpoint: { ..signed.checkpoint, event_root: @bft.Digest("tampered") },
    digest: signed.digest,
    signature: signed.signature,
    authority_key: signed.authority_key,
  }
  assert_eq(
    verify_checkpoint(hasher, verifier, authority.public_key(), tampered),
    CheckpointVerification::HashMismatch,
  )
}

///|
test "a different authority key cannot finalize a checkpoint" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let signed = sign_checkpoint(hasher, authority, candidate())
  assert_eq(
    verify_checkpoint(
      hasher,
      verifier,
      @bft.PublicKey("other-authority"),
      signed,
    ),
    CheckpointVerification::WrongAuthority,
  )
}

///|
test "an invalid authority signature is rejected" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let signed = sign_checkpoint(hasher, authority, candidate())
  let tampered : SignedCheckpoint = {
    checkpoint: signed.checkpoint,
    digest: signed.digest,
    signature: @bft.Signature("not-a-valid-signature"),
    authority_key: signed.authority_key,
  }
  assert_eq(
    verify_checkpoint(hasher, verifier, authority.public_key(), tampered),
    CheckpointVerification::InvalidSignature,
  )
}

///|
test "hidden state commitment is authenticated when present" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let with_hidden : Checkpoint = {
    ..candidate(),
    hidden_state_commitment: Some(@bft.Digest("fog-of-war")),
  }
  let signed = sign_checkpoint(hasher, authority, with_hidden)
  let tampered : SignedCheckpoint = {
    checkpoint: {
      ..signed.checkpoint,
      hidden_state_commitment: Some(@bft.Digest("revealed-too-late")),
    },
    digest: signed.digest,
    signature: signed.signature,
    authority_key: signed.authority_key,
  }
  assert_eq(
    verify_checkpoint(hasher, verifier, authority.public_key(), tampered),
    CheckpointVerification::HashMismatch,
  )
}

///|
test "canonical checkpoint serialization separates string boundaries" {
  let left = { ..candidate(), session_id: "a:b" }
  let right = { ..candidate(), session_id: "a", epoch: 0 }
  assert_not_eq(serialize_checkpoint(left), serialize_checkpoint(right))
}

///|
test "successful verification opens an unforgeable checkpoint capability" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let signed = sign_checkpoint(hasher, authority, candidate())
  match open_checkpoint(hasher, verifier, authority.public_key(), signed) {
    Opened(verified) => {
      assert_eq(verified.digest(), signed.digest)
      assert_eq(verified.checkpoint(), candidate())
    }
    Refused(_) => fail("expected verified checkpoint")
  }
}

///|
test "participants and authority share one prepared checkpoint digest" {
  let hasher = @bft.FnvHasher::new()
  let authority = @bft.MockSigner::new("authority")
  let prepared = prepare_checkpoint(hasher, candidate())
  let signed = sign_prepared_checkpoint(authority, prepared)
  assert_eq(prepared.checkpoint(), candidate())
  assert_eq(prepared.digest(), signed.digest)
  assert_eq(signed, sign_checkpoint(hasher, authority, candidate()))
}

///|
test "failed verification cannot open a checkpoint capability" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let signed = sign_checkpoint(hasher, authority, candidate())
  match
    open_checkpoint(hasher, verifier, @bft.PublicKey("other-authority"), signed) {
    Opened(_) => fail("wrong authority unexpectedly opened the checkpoint")
    Refused(reason) => assert_eq(reason, CheckpointVerification::WrongAuthority)
  }
}

///|
test "game checkpoint projects into the generic converge audit contract" {
  let adapted = @commitment.adapt_checkpoint(candidate())
  assert_eq(adapted.scope_id, "dungeon-42")
  assert_eq(adapted.epoch, 7)
  assert_eq(adapted.previous_checkpoint, @commitment.AuditDigest("previous"))
  assert_eq(adapted.manifest_digest, @commitment.AuditDigest("manifest"))
  assert_eq(adapted.event_root, @commitment.AuditDigest("events"))
  assert_eq(adapted.state_root, @commitment.AuditDigest("state"))
  assert_eq(adapted.effect_root, @commitment.AuditDigest("items"))
  assert_eq(adapted.sealed_state_commitment, None)
}

///|
test "game checkpoint binds the exact layered macro event history" {
  let policy = match
    @audit.open_checkpoint_policy({
      event_interval_ms: 10,
      micro_checkpoint_interval_ms: 50,
      macro_checkpoint_interval_ms: 100,
      event_retention_ms: 100,
      micro_checkpoint_retention_ms: 200,
      macro_checkpoint_retention_ms: 300,
    }) {
    @audit.CheckpointPolicyOpenResult::Opened(policy) => policy
    @audit.CheckpointPolicyOpenResult::Refused(_) => abort("valid policy")
  }
  let builder = match
    @layered.LayeredCheckpointBuilder::open(
      @bft.FnvHasher::new(),
      policy,
      scope_id="dungeon-42",
      origin_ms=0,
      previous_macro_digest=@bft.Digest("previous"),
      max_pending_events=4,
    ) {
    @layered.LayeredBuilderOpenResult::LayeredBuilderReady(builder) => builder
    @layered.LayeredBuilderOpenResult::LayeredBuilderRefused(_) =>
      abort("valid builder")
  }
  assert_eq(
    builder.append_event(20, "signed-event-a"),
    @layered.AppendAuditEventResult::AuditEventAppended,
  )
  let sealed_macro = match builder.advance_watermark(100, max_windows=2) {
    @layered.AdvanceWatermarkResult::WatermarkAdvanced(emission) =>
      emission.macro_checkpoints()[0]
    @layered.AdvanceWatermarkResult::WatermarkRefused(_) =>
      abort("valid watermark")
  }
  let checkpoint = checkpoint_from_layered_macro(
    sealed_macro,
    manifest_digest=@bft.Digest("manifest"),
    public_state_root=@bft.Digest("state"),
    asset_delta_root=@bft.Digest("items"),
    hidden_state_commitment=None,
  )
  let macro_checkpoint = sealed_macro.checkpoint()
  assert_eq(checkpoint.session_id, "dungeon-42")
  assert_eq(checkpoint.epoch, 0)
  assert_eq(checkpoint.previous_checkpoint, @bft.Digest("previous"))
  assert_eq(checkpoint.event_root, macro_checkpoint.micro_root)
  assert_true(checkpoint.matches_layered_macro(macro_checkpoint))
  assert_false(
    { ..checkpoint, event_root: @bft.Digest("other") }.matches_layered_macro(
      macro_checkpoint,
    ),
  )
}
