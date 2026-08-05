///|
/// Versioned, length-prefixed serialization for participant signatures.
pub fn serialize_attestation(attestation : Attestation) -> String {
  @quorum.serialize_vote_statement({
    subject_digest: attestation.checkpoint_digest,
    member_id: attestation.participant_id,
    domain: attestation.purpose.quorum_domain(),
    choice: attestation.choice.quorum_choice(),
  })
}

///|
fn sign_attestation_for_purpose(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  checkpoint : @checkpoint.PreparedCheckpoint,
  participant_id : String,
  purpose : AttestationPurpose,
  choice : AttestationChoice,
) -> SignedAttestation {
  let attestation = Attestation::{
    checkpoint_digest: checkpoint.digest(),
    participant_id,
    purpose,
    choice,
  }
  let signed = @quorum.sign_vote(
    hasher,
    signer,
    checkpoint.digest(),
    participant_id,
    purpose.quorum_domain(),
    choice.quorum_choice(),
  )
  SignedAttestation::{
    attestation,
    digest: signed.digest,
    signature: signed.signature,
    signer_key: signed.signer_key,
  }
}

///|
/// Sign a choice over the exact prepared checkpoint digest.
pub fn sign_attestation(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  checkpoint : @checkpoint.PreparedCheckpoint,
  participant_id : String,
  choice : AttestationChoice,
) -> SignedAttestation {
  sign_attestation_for_purpose(
    hasher,
    signer,
    checkpoint,
    participant_id,
    AttestationPurpose::CheckpointApproval,
    choice,
  )
}

///|
/// Sign a claim that this participant replayed and matched the exact prepared
/// checkpoint under its committed game and witness policy manifest.
pub fn sign_replay_witness_attestation(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  checkpoint : @checkpoint.PreparedCheckpoint,
  witness_id : String,
  choice : AttestationChoice,
) -> SignedAttestation {
  sign_attestation_for_purpose(
    hasher,
    signer,
    checkpoint,
    witness_id,
    AttestationPurpose::ReplayWitness,
    choice,
  )
}
