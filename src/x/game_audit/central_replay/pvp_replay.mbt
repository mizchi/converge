///|
pub(all) enum PvpCentralReplayRefusal {
  PvpWireReplayRefused(@wire.PvpReplayWireError)
  PvpExpectedSessionMismatch
  PvpExpectedRefereeMismatch
  PvpExpectedCheckpointMismatch
  PvpInvalidRefereePeer
  PvpInvalidRosterBoundary
  PvpDuplicateEventDigest(String)
  PvpEventAuthenticationRefused(String)
  PvpIncompleteEventGraph
  PvpCheckpointAuthenticationRefused(@checkpoint.CheckpointVerification)
  PvpEpochReplayRefused(@replay.PvpEpochRefusal)
  PvpWitnessSessionRefused(@pvp_session.PvpReplayWitnessSessionRefusal)
  PvpWitnessEvidenceRefused(@attestation.EvidenceAlertKind)
  PvpWitnessCheckpointMismatch
  PvpWitnessRefereeMismatch
  PvpWitnessQuorumPending(Int, Int)
} derive(Eq, Debug)

///|
/// Summary produced only after event authentication, deterministic replay,
/// exact referee checkpoint matching, and an n-f witness certificate.
pub struct PvpCentralReplayVerified {
  session_id : String
  checkpoint_digest : @bft.Digest
  referee_key : @bft.PublicKey
  epoch : Int
  accepted_commands : Int
  approval_count : Int
  required_approvals : Int
  player_states : Array[@replay.PvpPlayerState]
  team_states : Array[@replay.PvpTeamState]
  equivocators : Array[String]
} derive(Eq, Debug)

///|
pub(all) enum PvpCentralReplayResult {
  PvpReplayVerified(PvpCentralReplayVerified)
  PvpReplayRefused(PvpCentralReplayRefusal)
} derive(Eq, Debug)

///|
pub fn PvpCentralReplayVerified::session_id(
  self : PvpCentralReplayVerified,
) -> String {
  self.session_id
}

///|
pub fn PvpCentralReplayVerified::checkpoint_digest(
  self : PvpCentralReplayVerified,
) -> @bft.Digest {
  self.checkpoint_digest
}

///|
pub fn PvpCentralReplayVerified::referee_key(
  self : PvpCentralReplayVerified,
) -> @bft.PublicKey {
  self.referee_key
}

///|
pub fn PvpCentralReplayVerified::epoch(self : PvpCentralReplayVerified) -> Int {
  self.epoch
}

///|
pub fn PvpCentralReplayVerified::accepted_command_count(
  self : PvpCentralReplayVerified,
) -> Int {
  self.accepted_commands
}

///|
pub fn PvpCentralReplayVerified::approval_count(
  self : PvpCentralReplayVerified,
) -> Int {
  self.approval_count
}

///|
pub fn PvpCentralReplayVerified::required_approvals(
  self : PvpCentralReplayVerified,
) -> Int {
  self.required_approvals
}

///|
pub fn PvpCentralReplayVerified::player_states(
  self : PvpCentralReplayVerified,
) -> Array[@replay.PvpPlayerState] {
  self.player_states.copy()
}

///|
pub fn PvpCentralReplayVerified::team_states(
  self : PvpCentralReplayVerified,
) -> Array[@replay.PvpTeamState] {
  self.team_states.copy()
}

///|
pub fn PvpCentralReplayVerified::equivocator_ids(
  self : PvpCentralReplayVerified,
) -> Array[String] {
  self.equivocators.copy()
}

///|
fn pvp_signed_events(bundle : @wire.PvpReplayBundle) -> Array[@bft.SignedEvent] {
  let events : Array[@bft.SignedEvent] = []
  for command in bundle.commands {
    events.push(command.input)
    events.push(command.receipt)
  }
  events
}

///|
fn pvp_roster_boundary_valid(
  adapter : @bft.BFTAdapter,
  bundle : @wire.PvpReplayBundle,
  expected_referee_key : @bft.PublicKey,
) -> Bool {
  if bundle.referee_peer_id == "" ||
    !adapter.register_peer(
      @types.PeerId(bundle.referee_peer_id),
      expected_referee_key,
    ) {
    return false
  }
  for player in bundle.players {
    if player.player_id == "" ||
      player.player_id == bundle.referee_peer_id ||
      player.public_key == expected_referee_key ||
      !adapter.register_peer(@types.PeerId(player.player_id), player.public_key) {
      return false
    }
  }
  true
}

///|
fn authenticate_pvp_event_graph(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  bundle : @wire.PvpReplayBundle,
  expected_session_id : String,
  expected_referee_key : @bft.PublicKey,
) -> Result[Map[String, @bft.AuthenticatedEvent], PvpCentralReplayRefusal] {
  let adapter = @bft.BFTAdapter::new(
    hasher,
    verifier,
    session_id=expected_session_id,
  )
  if !pvp_roster_boundary_valid(adapter, bundle, expected_referee_key) {
    return Err(PvpInvalidRosterBoundary)
  }
  let events = pvp_signed_events(bundle)
  let seen : Map[String, Bool] = Map([])
  let authenticated : Map[String, @bft.AuthenticatedEvent] = Map([])
  for signed in events {
    if seen.contains(signed.digest.0) {
      return Err(PvpDuplicateEventDigest(signed.digest.0))
    }
    seen[signed.digest.0] = true
    match adapter.deliver(signed) {
      Accepted(source) => authenticated[source.digest().0] = source
      Buffered => ()
      Rejected(_) => return Err(PvpEventAuthenticationRefused(signed.digest.0))
    }
    for source in adapter.take_flushed() {
      authenticated[source.digest().0] = source
    }
    let alerts = adapter.take_flushed_alerts()
    if alerts.length() > 0 {
      return Err(PvpEventAuthenticationRefused(alerts[0].digest.0))
    }
  }
  if authenticated.length() != events.length() {
    return Err(PvpIncompleteEventGraph)
  }
  Ok(authenticated)
}

///|
fn authenticated_pvp_commands(
  bundle : @wire.PvpReplayBundle,
  authenticated : Map[String, @bft.AuthenticatedEvent],
) -> Result[Array[@replay.PvpCommandEvidence], PvpCentralReplayRefusal] {
  let commands : Array[@replay.PvpCommandEvidence] = []
  for wire_command in bundle.commands {
    let input = match authenticated.get(wire_command.input.digest.0) {
      Some(source) => source
      None => return Err(PvpIncompleteEventGraph)
    }
    let receipt = match authenticated.get(wire_command.receipt.digest.0) {
      Some(source) => source
      None => return Err(PvpIncompleteEventGraph)
    }
    commands.push({
      input,
      receipt,
      intent: wire_command.intent,
      observed: wire_command.observed,
    })
  }
  Ok(commands)
}

///|
fn pvp_witness_participants(
  bundle : @wire.PvpReplayBundle,
) -> Array[@attestation.Participant] {
  let participants : Array[@attestation.Participant] = []
  for witness in bundle.witnesses {
    participants.push({ id: witness.id, key: witness.key })
  }
  participants
}

///|
/// Decode and authenticate a complete adversarial PvP replay bundle. Success
/// requires both the public-state kernel replay and an n-f witness certificate.
pub fn verify_pvp_replay_bundle(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  bundle_bytes : Bytes,
  expected_session_id~ : String,
  expected_referee_key~ : @bft.PublicKey,
  expected_checkpoint_digest~ : @bft.Digest,
  limits~ : @wire.PvpReplayWireLimits,
) -> PvpCentralReplayResult {
  let bundle = match @wire.decode_pvp_replay_bundle(bundle_bytes, limits~) {
    Ok(value) => value
    Err(reason) => return PvpReplayRefused(PvpWireReplayRefused(reason))
  }
  let signed_checkpoint = bundle.signed_checkpoint
  if signed_checkpoint.checkpoint.session_id != expected_session_id {
    return PvpReplayRefused(PvpExpectedSessionMismatch)
  }
  if signed_checkpoint.authority_key != expected_referee_key {
    return PvpReplayRefused(PvpExpectedRefereeMismatch)
  }
  if signed_checkpoint.digest != expected_checkpoint_digest {
    return PvpReplayRefused(PvpExpectedCheckpointMismatch)
  }
  if bundle.referee_peer_id == "" {
    return PvpReplayRefused(PvpInvalidRefereePeer)
  }
  let checkpoint = match
    @checkpoint.open_checkpoint(
      hasher, verifier, expected_referee_key, signed_checkpoint,
    ) {
    Opened(value) => value
    Refused(reason) =>
      return PvpReplayRefused(PvpCheckpointAuthenticationRefused(reason))
  }
  let authenticated = match
    authenticate_pvp_event_graph(
      hasher, verifier, bundle, expected_session_id, expected_referee_key,
    ) {
    Ok(value) => value
    Err(reason) => return PvpReplayRefused(reason)
  }
  let commands = match authenticated_pvp_commands(bundle, authenticated) {
    Ok(value) => value
    Err(reason) => return PvpReplayRefused(reason)
  }
  let candidate = match
    @replay.prepare_pvp_epoch(
      hasher,
      session_id=expected_session_id,
      referee_key=expected_referee_key,
      config=bundle.config,
      teams=bundle.teams,
      players=bundle.players,
      transcript=commands,
      witnesses=bundle.witnesses,
      max_faults=bundle.max_faults,
    ) {
    PvpCandidateReady(value) => value
    PvpCandidateRefused(reason) =>
      return PvpReplayRefused(PvpEpochReplayRefused(reason))
  }
  let resolution = match @replay.finalize_pvp_epoch(candidate, checkpoint) {
    PvpEpochFinalized(value) => value
    PvpFinalizeRefused(reason) =>
      return PvpReplayRefused(PvpEpochReplayRefused(reason))
  }
  let prepared = @checkpoint.prepare_checkpoint(
    hasher,
    signed_checkpoint.checkpoint,
  )
  let witness_session = match
    @pvp_session.prepare_pvp_replay_witness_session(
      hasher,
      verifier,
      prepared,
      resolution,
      referee_key=expected_referee_key,
      witnesses=pvp_witness_participants(bundle),
      max_faults=bundle.max_faults,
    ) {
    PvpWitnessSessionReady(value) => value
    PvpWitnessSessionRefused(reason) =>
      return PvpReplayRefused(PvpWitnessSessionRefused(reason))
  }
  for signed in bundle.attestations {
    match witness_session.deliver(signed) {
      Accepted | Duplicate => ()
      Rejected(alert) =>
        return PvpReplayRefused(PvpWitnessEvidenceRefused(alert.kind))
    }
  }
  match witness_session.certify(checkpoint) {
    WitnessCertified(certificate) =>
      PvpReplayVerified(PvpCentralReplayVerified::{
        session_id: expected_session_id,
        checkpoint_digest: certificate.checkpoint_digest(),
        referee_key: certificate.referee_key(),
        epoch: signed_checkpoint.checkpoint.epoch,
        accepted_commands: resolution.accepted_command_count(),
        approval_count: certificate.approval_count(),
        required_approvals: certificate.required_approvals(),
        player_states: resolution.player_states(),
        team_states: resolution.team_states(),
        equivocators: resolution.equivocator_ids(),
      })
    WitnessCheckpointMismatch => PvpReplayRefused(PvpWitnessCheckpointMismatch)
    WitnessRefereeMismatch => PvpReplayRefused(PvpWitnessRefereeMismatch)
    WitnessQuorumPending(actual, required) =>
      PvpReplayRefused(PvpWitnessQuorumPending(actual, required))
  }
}
