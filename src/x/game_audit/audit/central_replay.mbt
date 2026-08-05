///|
/// Pure deployment boundary for a central deterministic replay job.
/// Queue delivery and an authenticated anchor are necessary but never
/// sufficient: verification requires a complete transcript, an authenticated
/// link to the game checkpoint, and a matching kernel replay.
pub(all) enum CentralReplayArtifactDecision {
  RejectReplayBoundary
  AwaitReplayTranscript
  RejectReplayCheckpointLink
  RejectReplayIncomplete
  RejectReplayMismatch
  VerifyCentralReplay
} derive(Eq, Debug)

///|
pub fn classify_central_replay_artifacts(
  anchor_matches_job~ : Bool,
  transcript_present~ : Bool,
  checkpoint_link_valid~ : Bool,
  kernel_replay_complete~ : Bool,
  kernel_replay_matches~ : Bool,
) -> CentralReplayArtifactDecision where {
  proof_ensure: decision => {
    central_replay_artifact_post(
      anchor_matches_job, transcript_present, checkpoint_link_valid, kernel_replay_complete,
      kernel_replay_matches, decision,
    )
  },
} {
  let decision = if !anchor_matches_job {
    CentralReplayArtifactDecision::RejectReplayBoundary
  } else if !transcript_present {
    CentralReplayArtifactDecision::AwaitReplayTranscript
  } else if !checkpoint_link_valid {
    CentralReplayArtifactDecision::RejectReplayCheckpointLink
  } else if !kernel_replay_complete {
    CentralReplayArtifactDecision::RejectReplayIncomplete
  } else if !kernel_replay_matches {
    CentralReplayArtifactDecision::RejectReplayMismatch
  } else {
    CentralReplayArtifactDecision::VerifyCentralReplay
  }
  proof_assert central_replay_artifact_post(
    anchor_matches_job, transcript_present, checkpoint_link_valid, kernel_replay_complete,
    kernel_replay_matches, decision,
  )
  decision
}
