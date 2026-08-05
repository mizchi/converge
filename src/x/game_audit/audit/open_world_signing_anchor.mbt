///|
pub(all) enum OpenWorldSigningAnchorPublicationDecision {
  PublishSigningAnchor
  RejectInvalidSigningAnchor
  RejectSigningAnchorLogSession
  RejectSigningAnchorLogManifest
  RejectSigningAnchorMembership
} derive(Eq, Debug)

///|
/// Classify whether a verified checkpoint can publish one signing-store anchor.
pub fn classify_open_world_signing_anchor_publication(
  anchor_valid~ : Bool,
  log_session_matches~ : Bool,
  log_manifest_matches~ : Bool,
  membership_proof_valid~ : Bool,
) -> OpenWorldSigningAnchorPublicationDecision where {
  proof_ensure: decision => {
    open_world_signing_anchor_publication_post(
      anchor_valid, log_session_matches, log_manifest_matches, membership_proof_valid,
      decision,
    )
  },
} {
  let decision = if !anchor_valid {
    OpenWorldSigningAnchorPublicationDecision::RejectInvalidSigningAnchor
  } else if !log_session_matches {
    OpenWorldSigningAnchorPublicationDecision::RejectSigningAnchorLogSession
  } else if !log_manifest_matches {
    OpenWorldSigningAnchorPublicationDecision::RejectSigningAnchorLogManifest
  } else if !membership_proof_valid {
    OpenWorldSigningAnchorPublicationDecision::RejectSigningAnchorMembership
  } else {
    OpenWorldSigningAnchorPublicationDecision::PublishSigningAnchor
  }
  proof_assert open_world_signing_anchor_publication_post(
    anchor_valid, log_session_matches, log_manifest_matches, membership_proof_valid,
    decision,
  )
  decision
}
