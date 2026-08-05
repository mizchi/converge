///|
fn benchmark_wire_envelope(
  proof_steps : Int,
) -> @open_world.OpenWorldObserverSigningAnchorEnvelope {
  let path : Array[@authmap.AuthMapStep] = []
  for index in 0..<proof_steps {
    if index % 2 == 0 {
      path.push(
        @authmap.AuthMapStep::DescendedLeft(
          "benchmark-key-" + index.to_string(),
          "benchmark-value-" + index.to_string(),
          @bft.Digest("benchmark-sibling-" + index.to_string()),
        ),
      )
    } else {
      path.push(
        @authmap.AuthMapStep::DescendedRight(
          "benchmark-key-" + index.to_string(),
          "benchmark-value-" + index.to_string(),
          @bft.Digest("benchmark-sibling-" + index.to_string()),
        ),
      )
    }
  }
  @open_world.OpenWorldObserverSigningAnchorEnvelope::{
    signed_checkpoint: {
      checkpoint: {
        session_id: "benchmark-world:wire-codec",
        epoch: 100,
        previous_checkpoint: @bft.Digest("benchmark-previous"),
        manifest_digest: @bft.Digest("benchmark-manifest"),
        event_root: @bft.Digest("benchmark-events"),
        public_state_root: @bft.Digest("benchmark-state"),
        asset_delta_root: @bft.Digest("benchmark-assets"),
        hidden_state_commitment: Some(@bft.Digest("benchmark-hidden")),
      },
      digest: @bft.Digest("benchmark-checkpoint"),
      signature: @bft.Signature("benchmark-signature"),
      authority_key: @bft.PublicKey("benchmark-authority"),
    },
    anchor: {
      observer_id: "benchmark-observer",
      signer_key: @bft.PublicKey("benchmark-observer-key"),
      root: @bft.Digest("benchmark-observer-root"),
      size: 100,
    },
    membership_proof: {
      key: "benchmark-proof-key",
      value: "benchmark-proof-value",
      left_digest: @bft.Digest("benchmark-left"),
      right_digest: @bft.Digest("benchmark-right"),
      entry_count: 65536,
      path,
    },
  }
}

///|
test "bench: encode 1000 sixteen-step wire envelopes" (b : @bench.T) {
  let envelope = benchmark_wire_envelope(16)
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(encode_open_world_observer_signing_anchor_envelope(envelope))
    }
  })
}

///|
test "bench: decode 1000 sixteen-step wire envelopes" (b : @bench.T) {
  let encoded = encode_open_world_observer_signing_anchor_envelope(
    benchmark_wire_envelope(16),
  )
  let limits = OpenWorldAuditWireLimits::default()
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        decode_open_world_observer_signing_anchor_envelope(encoded, limits~),
      )
    }
  })
}

///|
test "bench: decode a 64-envelope wire gap page" (b : @bench.T) {
  let envelope = benchmark_wire_envelope(16)
  let envelopes : Array[@open_world.OpenWorldObserverSigningAnchorEnvelope] = Array::make(
    64, envelope,
  )
  let encoded = encode_open_world_observer_signing_anchor_gap_response({
    envelopes,
  })
  let limits = OpenWorldAuditWireLimits::default()
  b.bench(fn() {
    b.keep(
      decode_open_world_observer_signing_anchor_gap_response(encoded, limits~),
    )
  })
}
