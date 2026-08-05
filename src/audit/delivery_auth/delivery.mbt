///|
/// Exact destination-specific checkpoint bytes authenticated before an
/// authority receiver may classify or persist them.
pub(all) struct CheckpointDeliveryStatement {
  boundary : @audit_runtime.AuditBoundary
  destination_id : String
  epoch : Int
  previous_checkpoint : @bft.Digest
  checkpoint_digest : @bft.Digest
  canonical_envelope : String
} derive(Eq, Debug)

///|
pub(all) struct DeliveryWitness {
  witness_id : String
  witness_key : @bft.PublicKey
} derive(Eq, Debug)

///|
/// Provisioned policy. The producer is deliberately excluded from the witness
/// roster so its own signature cannot also satisfy an independent approval.
pub(all) struct DeliveryAuthenticationPolicy {
  producer_id : String
  producer_key : @bft.PublicKey
  witnesses : Array[DeliveryWitness]
  required_approvals : Int
} derive(Eq, Debug)

///|
pub(all) struct SignedCheckpointDelivery {
  statement : CheckpointDeliveryStatement
  digest : @bft.Digest
  signature : @bft.Signature
  producer_id : String
  producer_key : @bft.PublicKey
} derive(Eq, Debug)

///|
pub(all) struct SignedCheckpointDeliveryApproval {
  statement_digest : @bft.Digest
  witness_id : String
  digest : @bft.Digest
  signature : @bft.Signature
  witness_key : @bft.PublicKey
} derive(Eq, Debug)

///|
pub(all) enum DeliveryAuthenticationRefusal {
  DeliveryInvalidStatement
  DeliveryInvalidPolicy
  DeliveryProducerIdentityMismatch
  DeliveryStatementDigestMismatch
  DeliveryInvalidProducerSignature
  DeliveryApprovalStatementMismatch
  DeliveryUnknownWitness
  DeliveryWitnessKeyMismatch
  DeliveryApprovalDigestMismatch
  DeliveryInvalidWitnessSignature
  DeliveryDuplicateWitness
  DeliveryUnderQuorum(Int, Int)
} derive(Eq, Debug)

///|
/// Opaque capability: only complete producer authentication plus a provisioned
/// witness quorum can construct this value.
pub struct AuthenticatedCheckpointDelivery {
  statement_value : CheckpointDeliveryStatement
  producer_id_value : String
  approval_count_value : Int
} derive(Eq, Debug)

///|
pub(all) enum DeliveryAuthenticationResult {
  DeliveryAuthenticated(AuthenticatedCheckpointDelivery)
  DeliveryAuthenticationRefused(DeliveryAuthenticationRefusal)
} derive(Eq, Debug)

///|
pub fn AuthenticatedCheckpointDelivery::statement(
  self : AuthenticatedCheckpointDelivery,
) -> CheckpointDeliveryStatement {
  self.statement_value
}

///|
pub fn AuthenticatedCheckpointDelivery::producer_id(
  self : AuthenticatedCheckpointDelivery,
) -> String {
  self.producer_id_value
}

///|
pub fn AuthenticatedCheckpointDelivery::approval_count(
  self : AuthenticatedCheckpointDelivery,
) -> Int {
  self.approval_count_value
}

///|
fn delivery_append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
pub fn serialize_checkpoint_delivery_statement(
  statement : CheckpointDeliveryStatement,
) -> String {
  let buffer = StringBuilder::new()
  let boundary = statement.boundary
  delivery_append_field(buffer, "checkpoint-delivery-auth-v1")
  delivery_append_field(buffer, boundary.protocol_version.to_string())
  delivery_append_field(buffer, boundary.purpose)
  delivery_append_field(buffer, boundary.manifest_digest.0)
  delivery_append_field(buffer, boundary.scope_id)
  delivery_append_field(buffer, boundary.unit_id)
  delivery_append_field(buffer, statement.destination_id)
  delivery_append_field(buffer, statement.epoch.to_string())
  delivery_append_field(buffer, statement.previous_checkpoint.0)
  delivery_append_field(buffer, statement.checkpoint_digest.0)
  delivery_append_field(buffer, statement.canonical_envelope)
  buffer.to_string()
}

///|
fn serialize_checkpoint_delivery_approval(
  statement_digest : @bft.Digest,
  witness_id : String,
) -> String {
  let buffer = StringBuilder::new()
  delivery_append_field(buffer, "checkpoint-delivery-approval-v1")
  delivery_append_field(buffer, statement_digest.0)
  delivery_append_field(buffer, witness_id)
  buffer.to_string()
}

///|
pub fn sign_checkpoint_delivery(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  producer_id : String,
  statement : CheckpointDeliveryStatement,
) -> SignedCheckpointDelivery {
  let digest = hasher.hash_string(
    serialize_checkpoint_delivery_statement(statement),
  )
  {
    statement,
    digest,
    signature: signer.sign(digest),
    producer_id,
    producer_key: signer.public_key(),
  }
}

///|
pub fn sign_checkpoint_delivery_approval(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  witness_id : String,
  statement_digest : @bft.Digest,
) -> SignedCheckpointDeliveryApproval {
  let digest = hasher.hash_string(
    serialize_checkpoint_delivery_approval(statement_digest, witness_id),
  )
  {
    statement_digest,
    witness_id,
    digest,
    signature: signer.sign(digest),
    witness_key: signer.public_key(),
  }
}

///|
fn checkpoint_delivery_statement_valid(
  statement : CheckpointDeliveryStatement,
) -> Bool {
  let boundary = statement.boundary
  boundary.protocol_version > 0 &&
  boundary.purpose != "" &&
  boundary.manifest_digest.0 != "" &&
  boundary.scope_id != "" &&
  boundary.unit_id != "" &&
  statement.destination_id != "" &&
  statement.epoch >= 0 &&
  statement.previous_checkpoint.0 != "" &&
  statement.checkpoint_digest.0 != "" &&
  statement.canonical_envelope != ""
}

///|
fn checkpoint_delivery_policy_valid(
  policy : DeliveryAuthenticationPolicy,
) -> Bool {
  if policy.producer_id == "" ||
    policy.producer_key.0 == "" ||
    policy.witnesses.length() == 0 ||
    policy.required_approvals <= 0 ||
    policy.required_approvals > policy.witnesses.length() {
    return false
  }
  let ids : Map[String, Bool] = Map([])
  let keys : Map[String, Bool] = Map([])
  for witness in policy.witnesses {
    if witness.witness_id == "" ||
      witness.witness_key.0 == "" ||
      witness.witness_id == policy.producer_id ||
      witness.witness_key == policy.producer_key ||
      ids.contains(witness.witness_id) ||
      keys.contains(witness.witness_key.0) {
      return false
    }
    ids[witness.witness_id] = true
    keys[witness.witness_key.0] = true
  }
  true
}

///|
/// Authenticate exact destination bytes, a provisioned producer, and a
/// provisioned independent witness quorum before minting a delivery capability.
pub fn open_authenticated_checkpoint_delivery(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  policy : DeliveryAuthenticationPolicy,
  signed : SignedCheckpointDelivery,
  approvals : Array[SignedCheckpointDeliveryApproval],
) -> DeliveryAuthenticationResult {
  let statement_valid = checkpoint_delivery_statement_valid(signed.statement)
  if !statement_valid {
    return DeliveryAuthenticationRefused(DeliveryInvalidStatement)
  }
  let policy_valid = checkpoint_delivery_policy_valid(policy)
  if !policy_valid {
    return DeliveryAuthenticationRefused(DeliveryInvalidPolicy)
  }
  let producer_identity_matches = signed.producer_id == policy.producer_id &&
    signed.producer_key == policy.producer_key
  if !producer_identity_matches {
    return DeliveryAuthenticationRefused(DeliveryProducerIdentityMismatch)
  }
  let expected_digest = hasher.hash_string(
    serialize_checkpoint_delivery_statement(signed.statement),
  )
  if expected_digest != signed.digest {
    return DeliveryAuthenticationRefused(DeliveryStatementDigestMismatch)
  }
  let producer_signature_valid = verifier.verify(
    signed.producer_key,
    signed.digest,
    signed.signature,
  )
  if !producer_signature_valid {
    return DeliveryAuthenticationRefused(DeliveryInvalidProducerSignature)
  }
  let witness_keys : Map[String, @bft.PublicKey] = Map([])
  for witness in policy.witnesses {
    witness_keys[witness.witness_id] = witness.witness_key
  }
  let approved : Map[String, Bool] = Map([])
  for approval in approvals {
    if approval.statement_digest != signed.digest {
      return DeliveryAuthenticationRefused(DeliveryApprovalStatementMismatch)
    }
    if approved.contains(approval.witness_id) {
      return DeliveryAuthenticationRefused(DeliveryDuplicateWitness)
    }
    let expected_key = match witness_keys.get(approval.witness_id) {
      Some(key) => key
      None => return DeliveryAuthenticationRefused(DeliveryUnknownWitness)
    }
    if approval.witness_key != expected_key {
      return DeliveryAuthenticationRefused(DeliveryWitnessKeyMismatch)
    }
    let expected_approval_digest = hasher.hash_string(
      serialize_checkpoint_delivery_approval(
        approval.statement_digest,
        approval.witness_id,
      ),
    )
    if approval.digest != expected_approval_digest {
      return DeliveryAuthenticationRefused(DeliveryApprovalDigestMismatch)
    }
    if !verifier.verify(
        approval.witness_key,
        approval.digest,
        approval.signature,
      ) {
      return DeliveryAuthenticationRefused(DeliveryInvalidWitnessSignature)
    }
    approved[approval.witness_id] = true
  }
  let approval_count = approved.length()
  let quorum_satisfied = approval_count >= policy.required_approvals
  if !quorum_satisfied {
    return DeliveryAuthenticationRefused(
      DeliveryUnderQuorum(approval_count, policy.required_approvals),
    )
  }
  if !@audit.runtime_checkpoint_delivery_authentication_allowed(
      statement_valid, policy_valid, producer_identity_matches, producer_signature_valid,
      true, quorum_satisfied,
    ) {
    abort("checkpoint delivery authentication gate diverged")
  }
  DeliveryAuthenticated(AuthenticatedCheckpointDelivery::{
    statement_value: signed.statement,
    producer_id_value: signed.producer_id,
    approval_count_value: approval_count,
  })
}
