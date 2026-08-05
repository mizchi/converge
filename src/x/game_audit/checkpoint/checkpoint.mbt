///|
/// A compact, authenticated summary of a session epoch.
pub(all) struct Checkpoint {
  session_id : String
  epoch : Int
  previous_checkpoint : @bft.Digest
  manifest_digest : @bft.Digest
  event_root : @bft.Digest
  public_state_root : @bft.Digest
  asset_delta_root : @bft.Digest
  hidden_state_commitment : @bft.Digest?
} derive(Eq, Debug)

///|
fn audit_digest(digest : @bft.Digest) -> @commitment.AuditDigest {
  @commitment.AuditDigest(digest.0)
}

///|
/// The game checkpoint keeps its domain-specific field names and wire format,
/// while exposing the stable converge audit projection to generic tooling.
pub impl @commitment.CheckpointAdapter for Checkpoint with fn checkpoint_commitment(
  self : Checkpoint,
) -> @commitment.CheckpointCommitment {
  {
    scope_id: self.session_id,
    epoch: self.epoch,
    previous_checkpoint: audit_digest(self.previous_checkpoint),
    manifest_digest: audit_digest(self.manifest_digest),
    event_root: audit_digest(self.event_root),
    state_root: audit_digest(self.public_state_root),
    effect_root: audit_digest(self.asset_delta_root),
    sealed_state_commitment: self.hidden_state_commitment.map(audit_digest),
  }
}

///|
/// Construct the game-specific state/effect checkpoint around one locally
/// sealed generic event-history macro. The layered package owns event windowing
/// and roots; the game owns manifest, public state, effects, and hidden state.
pub fn checkpoint_from_layered_macro(
  sealed_macro : @layered.SealedMacroCheckpoint,
  manifest_digest~ : @bft.Digest,
  public_state_root~ : @bft.Digest,
  asset_delta_root~ : @bft.Digest,
  hidden_state_commitment~ : @bft.Digest?,
) -> Checkpoint {
  let event_history = sealed_macro.checkpoint()
  {
    session_id: event_history.scope_id,
    epoch: event_history.epoch,
    previous_checkpoint: event_history.previous_macro_digest,
    manifest_digest,
    event_root: event_history.micro_root,
    public_state_root,
    asset_delta_root,
    hidden_state_commitment,
  }
}

///|
/// Check the structural event-history binding after the caller has separately
/// authenticated the remote macro and the game checkpoint.
pub fn Checkpoint::matches_layered_macro(
  self : Checkpoint,
  event_history : @layered.MacroCheckpoint,
) -> Bool {
  self.session_id == event_history.scope_id &&
  self.epoch == event_history.epoch &&
  self.previous_checkpoint == event_history.previous_macro_digest &&
  self.event_root == event_history.micro_root
}

///|
/// A checkpoint together with the authority signature over its digest.
pub(all) struct SignedCheckpoint {
  checkpoint : Checkpoint
  digest : @bft.Digest
  signature : @bft.Signature
  authority_key : @bft.PublicKey
} derive(Eq, Debug)

///|
/// Canonically hashed checkpoint candidate shared by participant attestations
/// and the authority signature path. This does not imply game validity.
pub struct PreparedCheckpoint {
  checkpoint : Checkpoint
  digest : @bft.Digest
}

///|
/// The result of checking a signed checkpoint against the expected authority.
pub(all) enum CheckpointVerification {
  Verified
  WrongAuthority
  HashMismatch
  InvalidSignature
} derive(Eq, Debug)

///|
/// Capability produced only after all checkpoint verification checks pass.
/// Its private field prevents other packages from constructing one directly.
pub struct VerifiedCheckpoint {
  signed : SignedCheckpoint
}

///|
/// Result of attempting to obtain a verified checkpoint capability.
pub(all) enum CheckpointOpenResult {
  Opened(VerifiedCheckpoint)
  Refused(CheckpointVerification)
}

///|
pub fn CheckpointVerification::is_verified(
  self : CheckpointVerification,
) -> Bool {
  self == Verified
}

///|
pub fn VerifiedCheckpoint::digest(self : VerifiedCheckpoint) -> @bft.Digest {
  self.signed.digest
}

///|
pub fn VerifiedCheckpoint::checkpoint(self : VerifiedCheckpoint) -> Checkpoint {
  self.signed.checkpoint
}

///|
/// Authority key whose signature was verified when this capability was opened.
pub fn VerifiedCheckpoint::authority_key(
  self : VerifiedCheckpoint,
) -> @bft.PublicKey {
  self.signed.authority_key
}

///|
pub fn PreparedCheckpoint::digest(self : PreparedCheckpoint) -> @bft.Digest {
  self.digest
}

///|
pub fn PreparedCheckpoint::checkpoint(self : PreparedCheckpoint) -> Checkpoint {
  self.checkpoint
}

///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
fn append_digest(buffer : StringBuilder, digest : @bft.Digest) -> Unit {
  append_field(buffer, digest.0)
}

///|
/// Canonical serialization used by both the signer and verifier.
///
/// Every variable-width field is length-prefixed, and the optional commitment
/// has an explicit presence tag. The version prefix keeps future formats from
/// colliding with this one.
pub fn serialize_checkpoint(checkpoint : Checkpoint) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "checkpoint-v1")
  append_field(buffer, checkpoint.session_id)
  append_field(buffer, checkpoint.epoch.to_string())
  append_digest(buffer, checkpoint.previous_checkpoint)
  append_digest(buffer, checkpoint.manifest_digest)
  append_digest(buffer, checkpoint.event_root)
  append_digest(buffer, checkpoint.public_state_root)
  append_digest(buffer, checkpoint.asset_delta_root)
  match checkpoint.hidden_state_commitment {
    None => buffer.write_char('0')
    Some(digest) => {
      buffer.write_char('1')
      append_digest(buffer, digest)
    }
  }
  buffer.to_string()
}

///|
/// Prepare the canonical digest that participants and authority will sign.
pub fn prepare_checkpoint(
  hasher : &@bft.Hasher,
  checkpoint : Checkpoint,
) -> PreparedCheckpoint {
  PreparedCheckpoint::{
    checkpoint,
    digest: hasher.hash_string(serialize_checkpoint(checkpoint)),
  }
}

///|
/// Sign an already prepared checkpoint without hashing it again.
pub fn sign_prepared_checkpoint(
  signer : &@bft.Signer,
  prepared : PreparedCheckpoint,
) -> SignedCheckpoint {
  SignedCheckpoint::{
    checkpoint: prepared.checkpoint,
    digest: prepared.digest,
    signature: signer.sign(prepared.digest),
    authority_key: signer.public_key(),
  }
}

///|
/// Hashes and signs a checkpoint with the supplied authority signer.
pub fn sign_checkpoint(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  checkpoint : Checkpoint,
) -> SignedCheckpoint {
  sign_prepared_checkpoint(signer, prepare_checkpoint(hasher, checkpoint))
}

///|
/// Verifies authority identity, checkpoint integrity, and its signature.
pub fn verify_checkpoint(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  expected_authority : @bft.PublicKey,
  signed : SignedCheckpoint,
) -> CheckpointVerification {
  if signed.authority_key != expected_authority {
    return WrongAuthority
  }
  let actual_digest = hasher.hash_string(
    serialize_checkpoint(signed.checkpoint),
  )
  if actual_digest != signed.digest {
    return HashMismatch
  }
  if !verifier.verify(signed.authority_key, signed.digest, signed.signature) {
    return InvalidSignature
  }
  Verified
}

///|
/// Verify a checkpoint and expose it as a capability only on success.
pub fn open_checkpoint(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  expected_authority : @bft.PublicKey,
  signed : SignedCheckpoint,
) -> CheckpointOpenResult {
  let verification = verify_checkpoint(
    hasher, verifier, expected_authority, signed,
  )
  match verification {
    Verified => Opened(VerifiedCheckpoint::{ signed, })
    reason => Refused(reason)
  }
}
