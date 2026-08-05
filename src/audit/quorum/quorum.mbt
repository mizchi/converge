///|
/// Application-neutral choice over one opaque subject digest.
pub(all) enum VoteChoice {
  ApproveChoice
  ChallengeChoice
} derive(Eq, Debug)

///|
/// Domain-separated statement. `domain` is owned by the application protocol;
/// the collector only requires exact equality with its configured domain.
pub(all) struct VoteStatement {
  subject_digest : @bft.Digest
  member_id : String
  domain : String
  choice : VoteChoice
} derive(Eq, Debug)

///|
pub(all) struct SignedVote {
  statement : VoteStatement
  digest : @bft.Digest
  signature : @bft.Signature
  signer_key : @bft.PublicKey
} derive(Eq, Debug)

///|
pub(all) struct QuorumMember {
  member_id : String
  member_key : @bft.PublicKey
} derive(Eq, Debug)

///|
pub(all) enum VoteAlertKind {
  VoteInvalidRoster
  VoteHashMismatch
  VoteUnknownMember
  VoteSignerKeyMismatch
  VoteInvalidSignature
  VoteWrongSubject
  VoteWrongDomain
  VoteEquivocation
} derive(Eq, Debug)

///|
pub(all) struct VoteAlert {
  kind : VoteAlertKind
  member_id : String
  digest : @bft.Digest
  detail : String
} derive(Eq, Debug)

///|
pub(all) enum VoteDeliveryResult {
  VoteAccepted
  VoteDuplicate
  VoteRejected(VoteAlert)
} derive(Eq, Debug)

///|
/// Sanitized evidence produced only from authenticated, roster-bound votes.
pub(all) struct QuorumEvidence {
  approvals : FixedArray[Bool]
  challenged : Bool
}

///|
/// A per-subject authenticated vote collector. It does not interpret the
/// subject or domain and therefore cannot decide application finality.
pub struct VoteCollector {
  hasher : &@bft.Hasher
  verifier : &@bft.Verifier
  subject_digest_value : @bft.Digest
  domain_value : String
  member_keys : Map[String, @bft.PublicKey]
  member_indices : Map[String, Int]
  votes : Array[@quorum_vote.ParticipantVote]
  roster_valid_value : Bool
}

///|
fn quorum_append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
/// Stable serialization retained from the original attestation-v2 wire
/// contract so extracting this mechanism does not invalidate signatures.
pub fn serialize_vote_statement(statement : VoteStatement) -> String {
  let buffer = StringBuilder::new()
  quorum_append_field(buffer, "attestation-v2")
  quorum_append_field(buffer, statement.subject_digest.0)
  quorum_append_field(buffer, statement.member_id)
  quorum_append_field(buffer, statement.domain)
  buffer.write_char(
    match statement.choice {
      ApproveChoice => 'A'
      ChallengeChoice => 'C'
    },
  )
  buffer.to_string()
}

///|
pub fn sign_vote(
  hasher : &@bft.Hasher,
  signer : &@bft.Signer,
  subject_digest : @bft.Digest,
  member_id : String,
  domain : String,
  choice : VoteChoice,
) -> SignedVote {
  let statement = VoteStatement::{ subject_digest, member_id, domain, choice }
  let digest = hasher.hash_string(serialize_vote_statement(statement))
  {
    statement,
    digest,
    signature: signer.sign(digest),
    signer_key: signer.public_key(),
  }
}

///|
pub fn VoteCollector::new(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  subject_digest : @bft.Digest,
  domain : String,
  members : Array[QuorumMember],
) -> VoteCollector {
  let member_keys : Map[String, @bft.PublicKey] = Map([])
  let member_indices : Map[String, Int] = Map([])
  let used_keys : Map[String, Bool] = Map([])
  let mut roster_valid = subject_digest.0 != "" && domain != ""
  for index, roster_entry in members {
    if roster_entry.member_id == "" ||
      roster_entry.member_key.0 == "" ||
      member_keys.contains(roster_entry.member_id) ||
      used_keys.contains(roster_entry.member_key.0) {
      roster_valid = false
    } else {
      member_keys[roster_entry.member_id] = roster_entry.member_key
      member_indices[roster_entry.member_id] = index
      used_keys[roster_entry.member_key.0] = true
    }
  }
  VoteCollector::{
    hasher,
    verifier,
    subject_digest_value: subject_digest,
    domain_value: domain,
    member_keys,
    member_indices,
    votes: Array::make(members.length(), @quorum_vote.ParticipantVote::NoVote),
    roster_valid_value: roster_valid,
  }
}

///|
pub fn VoteCollector::is_roster_valid(self : VoteCollector) -> Bool {
  self.roster_valid_value
}

///|
pub fn VoteCollector::subject_digest(self : VoteCollector) -> @bft.Digest {
  self.subject_digest_value
}

///|
pub fn VoteCollector::domain(self : VoteCollector) -> String {
  self.domain_value
}

///|
fn vote_rejection(
  kind : VoteAlertKind,
  signed : SignedVote,
  detail : String,
) -> VoteDeliveryResult {
  VoteRejected({
    kind,
    member_id: signed.statement.member_id,
    digest: signed.digest,
    detail,
  })
}

///|
/// Authenticate and monotonically merge one signed vote. A conflicting pair
/// converges to equivocation regardless of delivery order.
pub fn VoteCollector::deliver(
  self : VoteCollector,
  signed : SignedVote,
) -> VoteDeliveryResult {
  if !self.roster_valid_value {
    return vote_rejection(
      VoteInvalidRoster,
      signed,
      "quorum roster or collector subject is invalid",
    )
  }
  let recomputed = self.hasher.hash_string(
    serialize_vote_statement(signed.statement),
  )
  if recomputed != signed.digest {
    return vote_rejection(VoteHashMismatch, signed, "vote digest mismatch")
  }
  if signed.statement.domain != self.domain_value {
    return vote_rejection(
      VoteWrongDomain,
      signed,
      "vote belongs to a different protocol domain",
    )
  }
  let member_id = signed.statement.member_id
  let index = match self.member_indices.get(member_id) {
    None =>
      return vote_rejection(
        VoteUnknownMember,
        signed,
        "member is absent from the configured roster",
      )
    Some(index) => index
  }
  let expected_key = match self.member_keys.get(member_id) {
    None =>
      return vote_rejection(
        VoteInvalidRoster,
        signed,
        "member index has no signing key",
      )
    Some(key) => key
  }
  if expected_key != signed.signer_key {
    return vote_rejection(
      VoteSignerKeyMismatch,
      signed,
      "vote signer does not own the member id",
    )
  }
  if !self.verifier.verify(signed.signer_key, signed.digest, signed.signature) {
    return vote_rejection(
      VoteInvalidSignature,
      signed,
      "vote signature verification failed",
    )
  }
  if signed.statement.subject_digest != self.subject_digest_value {
    return vote_rejection(
      VoteWrongSubject,
      signed,
      "vote targets a different subject",
    )
  }
  let current = self.votes[index]
  let incoming = match signed.statement.choice {
    ApproveChoice => @quorum_vote.ParticipantVote::ApproveVote
    ChallengeChoice => @quorum_vote.ParticipantVote::ChallengeVote
  }
  let merged = @quorum_vote.merge_participant_votes(current, incoming)
  if merged == current {
    return VoteDuplicate
  }
  self.votes[index] = merged
  if merged == @quorum_vote.ParticipantVote::EquivocatedVote {
    return vote_rejection(
      VoteEquivocation,
      signed,
      "member signed conflicting choices",
    )
  }
  VoteAccepted
}

///|
pub fn VoteCollector::evidence(self : VoteCollector) -> QuorumEvidence {
  let approvals : Array[Bool] = []
  let mut challenged = !self.roster_valid_value
  for vote in self.votes {
    approvals.push(self.roster_valid_value && vote.is_approval())
    if vote.is_challenge() {
      challenged = true
    }
  }
  { approvals: FixedArray::from_array(approvals[:]), challenged }
}
