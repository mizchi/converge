///|
fn generic_delivery_statement() -> CheckpointDeliveryStatement {
  {
    boundary: {
      protocol_version: 1,
      purpose: "replicated-log-checkpoint",
      manifest_digest: @commitment.AuditDigest("manifest-1"),
      scope_id: "scope-1",
      unit_id: "unit-1",
    },
    destination_id: "receiver-1",
    epoch: 7,
    previous_checkpoint: @bft.Digest("checkpoint-6"),
    checkpoint_digest: @bft.Digest("checkpoint-7"),
    canonical_envelope: "opaque-envelope-7",
  }
}

///|
test "delivery authentication is independent of application payload semantics" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let producer = @bft.MockSigner::new("producer")
  let witness = @bft.MockSigner::new("witness")
  let statement = generic_delivery_statement()
  let signed = sign_checkpoint_delivery(
    hasher, producer, "producer-1", statement,
  )
  let approval = sign_checkpoint_delivery_approval(
    hasher,
    witness,
    "witness-1",
    signed.digest,
  )
  match
    open_authenticated_checkpoint_delivery(
      hasher,
      verifier,
      {
        producer_id: "producer-1",
        producer_key: producer.public_key(),
        witnesses: [
          { witness_id: "witness-1", witness_key: witness.public_key() },
        ],
        required_approvals: 1,
      },
      signed,
      [approval],
    ) {
    DeliveryAuthenticated(capability) =>
      assert_eq(capability.statement(), statement)
    DeliveryAuthenticationRefused(_) => fail("expected authenticated delivery")
  }
}
