///|
fn bench_signing_anchor_envelope_chain(
  hasher : &@bft.Hasher,
  authority : &@bft.Signer,
  session : String,
  envelope_count : Int,
) -> Array[OpenWorldObserverSigningAnchorEnvelope] {
  let envelopes : Array[OpenWorldObserverSigningAnchorEnvelope] = []
  let mut previous = @bft.Digest("benchmark-wire-head-genesis")
  for epoch in 0..<envelope_count {
    let anchor = OpenWorldObserverSigningAnchor::{
      observer_id: "benchmark-wire-observer",
      signer_key: @bft.PublicKey("benchmark-wire-observer-key"),
      root: @bft.Digest("benchmark-wire-root-" + epoch.to_string()),
      size: epoch + 1,
    }
    let anchor_map = @authmap.AuthenticatedMap::new(hasher)
    let key = open_world_observer_signing_anchor_key(anchor)
    ignore(
      anchor_map.put(key, open_world_observer_signing_anchor_value(anchor)),
    )
    let signed_checkpoint = @checkpoint.sign_checkpoint(hasher, authority, {
      session_id: session,
      epoch,
      previous_checkpoint: previous,
      manifest_digest: open_world_observer_signing_anchor_log_manifest(
        hasher,
        log_session_id=session,
      ),
      event_root: @bft.Digest("benchmark-wire-events"),
      public_state_root: anchor_map.root(),
      asset_delta_root: @bft.Digest("benchmark-wire-no-assets"),
      hidden_state_commitment: None,
    })
    let membership_proof = match anchor_map.proof(key) {
      Some(proof) => proof
      None => abort("benchmark wire anchor proof missing")
    }
    envelopes.push({ signed_checkpoint, anchor, membership_proof })
    previous = signed_checkpoint.digest
  }
  envelopes
}

///|
fn bench_open_signing_anchor_envelope(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  session : String,
  envelope : OpenWorldObserverSigningAnchorEnvelope,
) -> PublishedOpenWorldObserverSigningAnchor {
  match
    open_open_world_observer_signing_anchor_envelope(
      hasher,
      verifier,
      authority.public_key(),
      log_session_id=session,
      envelope,
    ) {
    ObserverSigningAnchorEnvelopeOpened(published) => published
    ObserverSigningAnchorEnvelopeRefused(_) =>
      abort("benchmark wire anchor envelope failed")
  }
}

///|
test "bench: fetch authenticate and recover 1000 wire anchor heads" (
  b : @bench.T,
) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("benchmark-wire-authority")
  let session = "benchmark-world:wire-anchor-gap"
  let envelopes = bench_signing_anchor_envelope_chain(
    hasher, authority, session, 1001,
  )
  let initial = bench_open_signing_anchor_envelope(
    hasher,
    verifier,
    authority,
    session,
    envelopes[0],
  )
  let transport = OpenWorldInMemoryObserverSigningAnchorGapTransport::new(
    envelopes,
  )
  b.bench(fn() {
    let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(initial)
    b.keep(
      tracker.recover_gap(
        hasher,
        verifier,
        transport,
        target_epoch=1000,
        max_items=1000,
      ),
    )
  })
}
