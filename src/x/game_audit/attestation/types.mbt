///|
/// Participant intent for one prepared checkpoint.
pub(all) enum AttestationChoice {
  Approve
  Challenge
} derive(Eq, Debug)

///|
/// Domain separation for signatures over the same checkpoint digest.
/// A general checkpoint approval cannot be replayed as a claim that the
/// signer executed the deterministic game replay.
pub(all) enum AttestationPurpose {
  CheckpointApproval
  ReplayWitness
} derive(Eq, Debug)

///|
/// Statement authenticated by a participant signature.
pub(all) struct Attestation {
  checkpoint_digest : @bft.Digest
  participant_id : String
  purpose : AttestationPurpose
  choice : AttestationChoice
} derive(Eq, Debug)

///|
/// Signed participant statement and its canonical digest.
pub(all) struct SignedAttestation {
  attestation : Attestation
  digest : @bft.Digest
  signature : @bft.Signature
  signer_key : @bft.PublicKey
} derive(Eq, Debug)

///|
/// Trusted participant roster entry.
pub(all) struct Participant {
  id : String
  key : @bft.PublicKey
} derive(Eq, Debug)

///|
/// Reason a participant record could not contribute to audit evidence.
pub(all) enum EvidenceAlertKind {
  InvalidRoster
  HashMismatch
  UnknownParticipant
  SignerKeyMismatch
  InvalidSignature
  WrongCheckpoint
  WrongPurpose
  Equivocation
} derive(Eq, Debug)

///|
pub(all) struct EvidenceAlert {
  kind : EvidenceAlertKind
  participant_id : String
  digest : @bft.Digest
  detail : String
} derive(Eq, Debug)

///|
pub(all) enum EvidenceDeliveryResult {
  Accepted
  Duplicate
  Rejected(EvidenceAlert)
} derive(Eq, Debug)

///|
/// Sanitized input accepted by the proof-checked audit policy.
pub(all) struct AuditEvidence {
  approvals : FixedArray[Bool]
  challenged : Bool
}

///|
/// Per-checkpoint collector. Internal maps and vote states are private so only
/// verified signed records can mutate quorum evidence.
pub struct EvidenceCollector {
  inner : @quorum.VoteCollector
}

///|
/// Collector for a replay-witness roster whose policy is committed by the
/// checkpoint session manifest.
pub struct ReplayWitnessCollector {
  evidence : EvidenceCollector
  witness_count : Int
  max_faults : Int
  referee_key : @bft.PublicKey
}

///|
pub(all) enum ReplayWitnessCollectorBuildResult {
  WitnessCollectorReady(ReplayWitnessCollector)
  InvalidGameManifest
  InvalidRefereeKey
  InvalidWitnessPolicy
  InvalidWitnessRoster
  RefereeIsWitness
  WitnessManifestMismatch
}

///|
/// Opaque certificate issued only after an `n - f` quorum of authenticated
/// replay-witness signatures over a referee-verified checkpoint.
pub struct WitnessReplayCertificate {
  checkpoint_digest : @bft.Digest
  referee_key : @bft.PublicKey
  witness_count : Int
  max_faults : Int
  approval_count : Int
} derive(Eq, Debug)

///|
pub(all) enum ReplayWitnessCertificationResult {
  WitnessCertified(WitnessReplayCertificate)
  WitnessCheckpointMismatch
  WitnessRefereeMismatch
  WitnessQuorumPending(Int, Int)
} derive(Eq, Debug)

///|
/// Capability proving that the authority-signed checkpoint and the collector's
/// evidence jointly reached the proof-checked Finalized state.
pub struct FinalizedCheckpoint {
  verified : @checkpoint.VerifiedCheckpoint
}

///|
pub(all) enum CheckpointFinalizationResult {
  Ready(FinalizedCheckpoint)
  Deferred(@audit.CheckpointDecision)
  CheckpointMismatch
}
