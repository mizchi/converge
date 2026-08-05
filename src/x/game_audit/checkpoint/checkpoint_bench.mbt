///|
/// Hash and sign 1000 complete checkpoint summaries.
test "bench: sign 1000 checkpoints" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let authority = @bft.MockSigner::new("authority")
  let checkpoint : Checkpoint = {
    session_id: "dungeon-42",
    epoch: 7,
    previous_checkpoint: @bft.Digest("previous"),
    manifest_digest: @bft.Digest("manifest"),
    event_root: @bft.Digest("events"),
    public_state_root: @bft.Digest("state"),
    asset_delta_root: @bft.Digest("items"),
    hidden_state_commitment: Some(@bft.Digest("fog-of-war")),
  }
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(sign_checkpoint(hasher, authority, checkpoint))
    }
  })
}

///|
/// Verify 1000 already-signed checkpoint summaries.
test "bench: verify 1000 checkpoints" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("authority")
  let checkpoint : Checkpoint = {
    session_id: "dungeon-42",
    epoch: 7,
    previous_checkpoint: @bft.Digest("previous"),
    manifest_digest: @bft.Digest("manifest"),
    event_root: @bft.Digest("events"),
    public_state_root: @bft.Digest("state"),
    asset_delta_root: @bft.Digest("items"),
    hidden_state_commitment: Some(@bft.Digest("fog-of-war")),
  }
  let signed = sign_checkpoint(hasher, authority, checkpoint)
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        verify_checkpoint(hasher, verifier, authority.public_key(), signed),
      )
    }
  })
}
