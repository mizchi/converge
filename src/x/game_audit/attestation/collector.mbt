///|
/// Construct a collector from an authenticated session roster.
///
/// Duplicate participant ids, empty ids, or a public key shared by multiple
/// participant ids invalidate the whole roster and therefore fail closed.
fn evidence_collector_for_purpose(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  checkpoint : @checkpoint.PreparedCheckpoint,
  participants : Array[Participant],
  purpose : AttestationPurpose,
) -> EvidenceCollector {
  let members : Array[@quorum.QuorumMember] = participants.map(fn(participant) {
    { member_id: participant.id, member_key: participant.key }
  })
  EvidenceCollector::{
    inner: @quorum.VoteCollector::new(
      hasher,
      verifier,
      checkpoint.digest(),
      purpose.quorum_domain(),
      members,
    ),
  }
}

///|
/// Construct a collector from an authenticated session roster.
///
/// Duplicate participant ids, empty ids, or a public key shared by multiple
/// participant ids invalidate the whole roster and therefore fail closed.
pub fn EvidenceCollector::new(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  checkpoint : @checkpoint.PreparedCheckpoint,
  participants : Array[Participant],
) -> EvidenceCollector {
  evidence_collector_for_purpose(
    hasher,
    verifier,
    checkpoint,
    participants,
    AttestationPurpose::CheckpointApproval,
  )
}

///|
pub fn EvidenceCollector::is_roster_valid(self : EvidenceCollector) -> Bool {
  self.inner.is_roster_valid()
}

///|
/// Digest of the checkpoint whose signed participant evidence is collected.
///
/// Higher-level protocol gates use this to reject evidence accidentally or
/// maliciously supplied for another encounter before applying its challenge
/// state.
pub fn EvidenceCollector::checkpoint_digest(
  self : EvidenceCollector,
) -> @bft.Digest {
  self.inner.subject_digest()
}

///|
fn AttestationPurpose::quorum_domain(self : AttestationPurpose) -> String {
  match self {
    CheckpointApproval => "checkpoint-approval"
    ReplayWitness => "replay-witness"
  }
}

///|
fn AttestationChoice::quorum_choice(
  self : AttestationChoice,
) -> @quorum.VoteChoice {
  match self {
    Approve => @quorum.VoteChoice::ApproveChoice
    Challenge => @quorum.VoteChoice::ChallengeChoice
  }
}

///|
fn SignedAttestation::quorum_vote(
  self : SignedAttestation,
) -> @quorum.SignedVote {
  {
    statement: {
      subject_digest: self.attestation.checkpoint_digest,
      member_id: self.attestation.participant_id,
      domain: self.attestation.purpose.quorum_domain(),
      choice: self.attestation.choice.quorum_choice(),
    },
    digest: self.digest,
    signature: self.signature,
    signer_key: self.signer_key,
  }
}

///|
fn quorum_alert_kind(kind : @quorum.VoteAlertKind) -> EvidenceAlertKind {
  match kind {
    VoteInvalidRoster => InvalidRoster
    VoteHashMismatch => HashMismatch
    VoteUnknownMember => UnknownParticipant
    VoteSignerKeyMismatch => SignerKeyMismatch
    VoteInvalidSignature => InvalidSignature
    VoteWrongSubject => WrongCheckpoint
    VoteWrongDomain => WrongPurpose
    VoteEquivocation => Equivocation
  }
}

///|
/// Authenticate and merge one participant statement into the evidence state.
pub fn EvidenceCollector::deliver(
  self : EvidenceCollector,
  signed : SignedAttestation,
) -> EvidenceDeliveryResult {
  match self.inner.deliver(signed.quorum_vote()) {
    @quorum.VoteDeliveryResult::VoteAccepted => Accepted
    @quorum.VoteDeliveryResult::VoteDuplicate => Duplicate
    @quorum.VoteDeliveryResult::VoteRejected(alert) =>
      Rejected({
        kind: quorum_alert_kind(alert.kind),
        participant_id: alert.member_id,
        digest: alert.digest,
        detail: alert.detail,
      })
  }
}

///|
/// Export sanitized evidence. An invalid roster exports no approvals and a
/// challenge so it cannot activate the participant fast path.
pub fn EvidenceCollector::evidence(self : EvidenceCollector) -> AuditEvidence {
  let evidence = self.inner.evidence()
  AuditEvidence::{
    approvals: evidence.approvals,
    challenged: evidence.challenged,
  }
}

///|
fn EvidenceCollector::decide_with_replay_matches(
  self : EvidenceCollector,
  required_approvals : Int,
  authority~ : @audit.AuthorityVerdict,
  replay_matches~ : Bool,
) -> @audit.CheckpointDecision {
  let evidence = self.evidence()
  @audit.decide_checkpoint(
    evidence.approvals,
    required_approvals,
    challenged=evidence.challenged,
    authority~,
    replay_matches~,
  )
}

///|
/// Evaluate the collector through the proof-checked audit decision function.
/// This advisory method checks checkpoint identity; capability issuance in
/// `finalize` additionally checks the verified authority key.
pub fn EvidenceCollector::decide(
  self : EvidenceCollector,
  required_approvals : Int,
  authority~ : @audit.AuthorityVerdict,
  authority_key~ : @bft.PublicKey,
  replay_match~ : @replay.CheckpointReplayMatch?,
) -> @audit.CheckpointDecision {
  let replay_matches = match replay_match {
    Some(capability) =>
      @audit.checkpoint_replay_capability_matches(
        capability_present=true,
        checkpoint_digest_matches=capability.checkpoint_digest() ==
          self.checkpoint_digest(),
        authority_key_matches=capability.authority_key() == authority_key,
      )
    None =>
      @audit.checkpoint_replay_capability_matches(
        capability_present=false,
        checkpoint_digest_matches=false,
        authority_key_matches=false,
      )
  }
  self.decide_with_replay_matches(
    required_approvals,
    authority~,
    replay_matches~,
  )
}

///|
pub fn FinalizedCheckpoint::digest(self : FinalizedCheckpoint) -> @bft.Digest {
  self.verified.digest()
}

///|
pub fn FinalizedCheckpoint::checkpoint(
  self : FinalizedCheckpoint,
) -> @checkpoint.Checkpoint {
  self.verified.checkpoint()
}

///|
/// Combine verified authority authentication with participant evidence.
/// A capability is produced only for the exact checkpoint this collector tracks.
pub fn EvidenceCollector::finalize(
  self : EvidenceCollector,
  verified : @checkpoint.VerifiedCheckpoint,
  required_approvals : Int,
  replay_match~ : @replay.CheckpointReplayMatch?,
  witness_certificate? : WitnessReplayCertificate,
) -> CheckpointFinalizationResult {
  if verified.digest() != self.checkpoint_digest() {
    return CheckpointMismatch
  }
  let encounter_replay_matches = match replay_match {
    Some(capability) =>
      @audit.checkpoint_replay_capability_matches(
        capability_present=true,
        checkpoint_digest_matches=capability.checkpoint_digest() ==
          verified.digest(),
        authority_key_matches=capability.authority_key() ==
          verified.authority_key(),
      )
    None => false
  }
  let witness_replay_matches = match witness_certificate {
    Some(certificate) =>
      @audit.checkpoint_replay_capability_matches(
        capability_present=true,
        checkpoint_digest_matches=certificate.checkpoint_digest() ==
          verified.digest(),
        authority_key_matches=certificate.referee_key() ==
          verified.authority_key(),
      )
    None => false
  }
  let decision = self.decide_with_replay_matches(
    required_approvals,
    authority=@audit.AuthorityVerdict::Accept,
    replay_matches=encounter_replay_matches || witness_replay_matches,
  )
  match decision {
    @audit.CheckpointDecision::Finalized =>
      Ready(FinalizedCheckpoint::{ verified, })
    other => Deferred(other)
  }
}
