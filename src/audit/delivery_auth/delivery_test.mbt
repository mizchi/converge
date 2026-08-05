///|
fn delivery_statement() -> CheckpointDeliveryStatement {
  {
    boundary: {
      protocol_version: 1,
      purpose: "checkpoint-delivery-v1",
      manifest_digest: @commitment.AuditDigest("manifest-1"),
      scope_id: "match-1",
      unit_id: "unit-1",
    },
    destination_id: "authority-1",
    epoch: 7,
    previous_checkpoint: @bft.Digest("checkpoint-6"),
    checkpoint_digest: @bft.Digest("checkpoint-7"),
    canonical_envelope: "canonical-envelope-7",
  }
}

///|
fn witness_entry(id : String, signer : &@bft.Signer) -> DeliveryWitness {
  { witness_id: id, witness_key: signer.public_key() }
}

///|
test "producer signature and n-f witness quorum mint an authenticated delivery" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let producer = @bft.MockSigner::new("producer")
  let witnesses = [
    @bft.MockSigner::new("witness-0"),
    @bft.MockSigner::new("witness-1"),
    @bft.MockSigner::new("witness-2"),
    @bft.MockSigner::new("witness-3"),
  ]
  let roster = witnesses.map(fn(signer) {
    witness_entry(signer.public_key().0, signer)
  })
  let policy = DeliveryAuthenticationPolicy::{
    producer_id: "producer-1",
    producer_key: producer.public_key(),
    witnesses: roster,
    required_approvals: 3,
  }
  let statement = delivery_statement()
  let signed = sign_checkpoint_delivery(
    hasher, producer, "producer-1", statement,
  )
  let approvals = witnesses[:3].map(fn(signer) {
    sign_checkpoint_delivery_approval(
      hasher,
      signer,
      signer.public_key().0,
      signed.digest,
    )
  })
  match
    open_authenticated_checkpoint_delivery(
      hasher, verifier, policy, signed, approvals,
    ) {
    DeliveryAuthenticated(capability) => {
      assert_eq(capability.statement(), statement)
      assert_eq(capability.approval_count(), 3)
    }
    DeliveryAuthenticationRefused(_) => fail("expected authenticated delivery")
  }
}

///|
test "under-quorum, foreign witnesses, and tampering fail closed" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let producer = @bft.MockSigner::new("producer")
  let alice = @bft.MockSigner::new("alice")
  let bob = @bft.MockSigner::new("bob")
  let carol = @bft.MockSigner::new("carol")
  let intruder = @bft.MockSigner::new("intruder")
  let policy = DeliveryAuthenticationPolicy::{
    producer_id: "producer-1",
    producer_key: producer.public_key(),
    witnesses: [
      witness_entry("alice", alice),
      witness_entry("bob", bob),
      witness_entry("carol", carol),
    ],
    required_approvals: 2,
  }
  let statement = delivery_statement()
  let signed = sign_checkpoint_delivery(
    hasher, producer, "producer-1", statement,
  )
  let alice_approval = sign_checkpoint_delivery_approval(
    hasher,
    alice,
    "alice",
    signed.digest,
  )
  assert_eq(
    open_authenticated_checkpoint_delivery(hasher, verifier, policy, signed, [
      alice_approval,
    ]),
    DeliveryAuthenticationResult::DeliveryAuthenticationRefused(
      DeliveryAuthenticationRefusal::DeliveryUnderQuorum(1, 2),
    ),
  )
  let foreign = sign_checkpoint_delivery_approval(
    hasher,
    intruder,
    "mallory",
    signed.digest,
  )
  assert_eq(
    open_authenticated_checkpoint_delivery(hasher, verifier, policy, signed, [
      alice_approval, foreign,
    ]),
    DeliveryAuthenticationResult::DeliveryAuthenticationRefused(
      DeliveryAuthenticationRefusal::DeliveryUnknownWitness,
    ),
  )
  let tampered : SignedCheckpointDelivery = {
    ..signed,
    statement: { ..statement, destination_id: "authority-2" },
  }
  assert_eq(
    open_authenticated_checkpoint_delivery(hasher, verifier, policy, tampered, []),
    DeliveryAuthenticationResult::DeliveryAuthenticationRefused(
      DeliveryAuthenticationRefusal::DeliveryStatementDigestMismatch,
    ),
  )
}
