///|
fn benchmark_experimental_signer() -> ExperimentalEd25519Signer {
  ExperimentalEd25519Signer::new(
    Bytes::makei(32, fn(index) { index.to_byte() }),
  ) catch {
    _ => abort("benchmark Ed25519 seed was rejected")
  }
}

///|
test "bench: hash 1000 checkpoint-sized strings with experimental SHA-256" (
  b : @bench.T,
) {
  let hasher = ExperimentalSha256Hasher::new()
  let payload = "checkpoint-v1:benchmark-session:manifest:events:public-state:assets"
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(hasher.hash_string(payload))
    }
  })
}

///|
test "bench: sign one digest with experimental Ed25519" (b : @bench.T) {
  let signer = benchmark_experimental_signer()
  let digest = @bft.Digest(
    "0123456789abcdef0123456789abcdef" + "0123456789abcdef0123456789abcdef",
  )
  b.bench(fn() { b.keep(signer.sign(digest)) })
}

///|
test "bench: verify one digest with experimental Ed25519" (b : @bench.T) {
  let signer = benchmark_experimental_signer()
  let verifier = ExperimentalEd25519Verifier::new()
  let digest = @bft.Digest(
    "0123456789abcdef0123456789abcdef" + "0123456789abcdef0123456789abcdef",
  )
  let signature = signer.sign(digest)
  b.bench(fn() {
    b.keep(verifier.verify(signer.public_key(), digest, signature))
  })
}

///|
fn benchmark_real_crypto_wire_envelope(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  session : String,
) -> Bytes {
  let anchor = @open_world.OpenWorldObserverSigningAnchor::{
    observer_id: "benchmark-real-crypto-observer",
    signer_key: @bft.PublicKey("benchmark-observer-key"),
    root: hasher.hash_string("benchmark-store-root"),
    size: 42,
  }
  let anchor_map = @authmap.AuthenticatedMap::new(hasher)
  let key = @open_world.open_world_observer_signing_anchor_key(anchor)
  ignore(
    anchor_map.put(
      key,
      @open_world.open_world_observer_signing_anchor_value(anchor),
    ),
  )
  let signed_checkpoint = @checkpoint.sign_checkpoint(hasher, signer, {
    session_id: session,
    epoch: 42,
    previous_checkpoint: hasher.hash_string("benchmark-checkpoint-41"),
    manifest_digest: @open_world.open_world_observer_signing_anchor_log_manifest(
      hasher,
      log_session_id=session,
    ),
    event_root: hasher.hash_string("benchmark-events"),
    public_state_root: anchor_map.root(),
    asset_delta_root: hasher.hash_string("benchmark-no-assets"),
    hidden_state_commitment: None,
  })
  let proof = match anchor_map.proof(key) {
    Some(proof) => proof
    None => abort("benchmark anchor proof missing")
  }
  @wire.encode_open_world_observer_signing_anchor_envelope({
    signed_checkpoint,
    anchor,
    membership_proof: proof,
  })
}

///|
test "bench: decode and open one real-crypto wire anchor envelope" (
  b : @bench.T,
) {
  let hasher = ExperimentalSha256Hasher::new()
  let signer = benchmark_experimental_signer()
  let verifier = ExperimentalEd25519Verifier::new()
  let session = "benchmark-world:real-crypto-wire"
  let encoded = benchmark_real_crypto_wire_envelope(hasher, signer, session)
  let limits = @wire.OpenWorldAuditWireLimits::default()
  b.bench(fn() {
    let decoded = match
      @wire.decode_open_world_observer_signing_anchor_envelope(encoded, limits~) {
      Ok(envelope) => envelope
      Err(_) => abort("benchmark wire decode failed")
    }
    b.keep(
      @open_world.open_open_world_observer_signing_anchor_envelope(
        hasher,
        verifier,
        signer.public_key(),
        log_session_id=session,
        decoded,
      ),
    )
  })
}
