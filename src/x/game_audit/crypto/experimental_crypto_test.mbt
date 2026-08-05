///|
fn hex_nibble_for_test(char : UInt16) -> Int {
  let code = char.to_int()
  if code >= '0'.to_int() && code <= '9'.to_int() {
    code - '0'.to_int()
  } else if code >= 'a'.to_int() && code <= 'f'.to_int() {
    code - 'a'.to_int() + 10
  } else {
    abort("invalid test hex")
  }
}

///|
fn bytes_from_hex_for_test(value : String) -> Bytes {
  Bytes::makei(value.length() / 2, fn(index) {
    let high = hex_nibble_for_test(value[index * 2])
    let low = hex_nibble_for_test(value[index * 2 + 1])
    ((high << 4) | low).to_byte()
  })
}

///|
test "experimental SHA-256 adapter matches the standard abc vector" {
  let hasher = ExperimentalSha256Hasher::new()
  assert_eq(
    hasher.hash_string("abc"),
    @bft.Digest(
      "ba7816bf8f01cfea414140de5dae2223" + "b00361a396177a9cb410ff61f20015ad",
    ),
  )
}

///|
test "experimental Ed25519 adapter matches RFC 8032 empty-message vector" {
  let signer = ExperimentalEd25519Signer::new(
    bytes_from_hex_for_test(
      "9d61b19deffd5a60ba844af492ec2cc4" + "4449c5697b326919703bac031cae7f60",
    ),
  )
  let verifier = ExperimentalEd25519Verifier::new()
  assert_eq(
    signer.public_key(),
    @bft.PublicKey(
      "d75a980182b10ab7d54bfed3c964073a" + "0ee172f3daa62325af021a68f707511a",
    ),
  )
  let signature = signer.sign(@bft.Digest(""))
  assert_eq(
    signature,
    @bft.Signature(
      "e5564300c360ac729086e2cc806e828a" +
      "84877f1eb8e5d974d873e06522490155" +
      "5fb8821590a33bacc61e39701cf9b46b" +
      "d25bf5f0595bbe24655141438e7a100b",
    ),
  )
  assert_true(verifier.verify(signer.public_key(), @bft.Digest(""), signature))
  assert_false(
    verifier.verify(signer.public_key(), @bft.Digest("tampered"), signature),
  )
  assert_false(
    verifier.verify(
      signer.public_key(),
      @bft.Digest(""),
      @bft.Signature("not-hex"),
    ),
  )
}

///|
test "real-hash signed anchor survives wire decode and capability opening" {
  let hasher = ExperimentalSha256Hasher::new()
  let signer = ExperimentalEd25519Signer::new(
    bytes_from_hex_for_test(
      "000102030405060708090a0b0c0d0e0f" + "101112131415161718191a1b1c1d1e1f",
    ),
  )
  let verifier = ExperimentalEd25519Verifier::new()
  let session = "world-1:real-crypto-wire"
  let anchor = @open_world.OpenWorldObserverSigningAnchor::{
    observer_id: "real-crypto-observer",
    signer_key: @bft.PublicKey("observer-key"),
    root: hasher.hash_string("observer-store-root"),
    size: 12,
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
    epoch: 12,
    previous_checkpoint: hasher.hash_string("checkpoint-11"),
    manifest_digest: @open_world.open_world_observer_signing_anchor_log_manifest(
      hasher,
      log_session_id=session,
    ),
    event_root: hasher.hash_string("events"),
    public_state_root: anchor_map.root(),
    asset_delta_root: hasher.hash_string("no-assets"),
    hidden_state_commitment: None,
  })
  let proof = match anchor_map.proof(key) {
    Some(proof) => proof
    None => fail("expected real-crypto anchor proof")
  }
  let envelope = @open_world.OpenWorldObserverSigningAnchorEnvelope::{
    signed_checkpoint,
    anchor,
    membership_proof: proof,
  }
  let encoded = @wire.encode_open_world_observer_signing_anchor_envelope(
    envelope,
  )
  inspect(
    encoded.length(),
    content=(
      #|1064
    ),
  )
  let decoded = match
    @wire.decode_open_world_observer_signing_anchor_envelope(
      encoded,
      limits=@wire.OpenWorldAuditWireLimits::default(),
    ) {
    Ok(envelope) => envelope
    Err(_) => fail("expected real crypto envelope decode")
  }
  match
    @open_world.open_open_world_observer_signing_anchor_envelope(
      hasher,
      verifier,
      signer.public_key(),
      log_session_id=session,
      decoded,
    ) {
    ObserverSigningAnchorEnvelopeOpened(published) => {
      assert_eq(published.anchor(), anchor)
      assert_eq(published.log_epoch(), 12)
    }
    ObserverSigningAnchorEnvelopeRefused(_) =>
      fail("real crypto wire envelope was refused")
  }
}
