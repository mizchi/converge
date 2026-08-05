///|
/// Fail-closed reasons emitted before a replay-match capability is produced.
pub(all) enum PveCentralReplayRefusal {
  WireReplayRefused(@wire.PveReplayWireError)
  ExpectedSessionMismatch
  ExpectedAuthorityMismatch
  ExpectedCheckpointMismatch
  InvalidAuthorityPeer
  InvalidRosterBoundary
  DuplicateEventDigest(String)
  EventAuthenticationRefused(String)
  IncompleteEventGraph
  CheckpointAuthenticationRefused(@checkpoint.CheckpointVerification)
  EncounterReplayRefused(@replay.DungeonEncounterRefusal)
  AssetEffectReplayRefused(Int, @replay.ReplayRefusal)
  AssetReceiptBatchRefused(@market.ReceiptBatchError)
  AssetDeltaRootMismatch
} derive(Eq, Debug)

///|
/// Summary available only after the signed checkpoint and complete event graph
/// have passed deterministic replay together.
pub struct PveCentralReplayVerified {
  session_id : String
  checkpoint_digest : @bft.Digest
  authority_key : @bft.PublicKey
  epoch : Int
  cleared : Bool
  accepted_dodges : Int
  survivors : Array[String]
  defeated : Array[String]
  player_states : Array[@replay.DungeonEncounterPlayerState]
  replayed_assets : Int
} derive(Eq, Debug)

///|
pub(all) enum PveCentralReplayResult {
  ReplayVerified(PveCentralReplayVerified)
  ReplayRefused(PveCentralReplayRefusal)
} derive(Eq, Debug)

///|
pub fn PveCentralReplayVerified::session_id(
  self : PveCentralReplayVerified,
) -> String {
  self.session_id
}

///|
pub fn PveCentralReplayVerified::checkpoint_digest(
  self : PveCentralReplayVerified,
) -> @bft.Digest {
  self.checkpoint_digest
}

///|
pub fn PveCentralReplayVerified::authority_key(
  self : PveCentralReplayVerified,
) -> @bft.PublicKey {
  self.authority_key
}

///|
pub fn PveCentralReplayVerified::epoch(self : PveCentralReplayVerified) -> Int {
  self.epoch
}

///|
pub fn PveCentralReplayVerified::cleared(
  self : PveCentralReplayVerified,
) -> Bool {
  self.cleared
}

///|
pub fn PveCentralReplayVerified::accepted_dodge_count(
  self : PveCentralReplayVerified,
) -> Int {
  self.accepted_dodges
}

///|
pub fn PveCentralReplayVerified::survivor_ids(
  self : PveCentralReplayVerified,
) -> Array[String] {
  self.survivors.copy()
}

///|
pub fn PveCentralReplayVerified::defeated_ids(
  self : PveCentralReplayVerified,
) -> Array[String] {
  self.defeated.copy()
}

///|
pub fn PveCentralReplayVerified::player_states(
  self : PveCentralReplayVerified,
) -> Array[@replay.DungeonEncounterPlayerState] {
  self.player_states.copy()
}

///|
/// Number of authority-signed asset creations accepted by the encounter loot
/// kernel and committed under the checkpoint asset-delta root.
pub fn PveCentralReplayVerified::replayed_asset_count(
  self : PveCentralReplayVerified,
) -> Int {
  self.replayed_assets
}

///|
fn pve_signed_events(bundle : @wire.PveReplayBundle) -> Array[@bft.SignedEvent] {
  let events : Array[@bft.SignedEvent] = []
  for transcript in bundle.transcripts {
    events.push(transcript.telegraph)
    for evidence in transcript.dodge_evidence {
      events.push(evidence.input)
      events.push(evidence.receipt)
    }
  }
  for evidence in bundle.asset_effects {
    events.push(evidence.source)
  }
  events
}

///|
fn pve_roster_boundary_valid(
  adapter : @bft.BFTAdapter,
  bundle : @wire.PveReplayBundle,
  expected_authority_key : @bft.PublicKey,
) -> Bool {
  if bundle.authority_peer_id == "" ||
    !adapter.register_peer(
      @types.PeerId(bundle.authority_peer_id),
      expected_authority_key,
    ) {
    return false
  }
  for player in bundle.players {
    if player.player_id == "" ||
      player.player_id == bundle.authority_peer_id ||
      player.public_key == expected_authority_key ||
      !adapter.register_peer(@types.PeerId(player.player_id), player.public_key) {
      return false
    }
  }
  true
}

///|
fn remember_authenticated_event(
  authenticated : Map[String, @bft.AuthenticatedEvent],
  source : @bft.AuthenticatedEvent,
) -> Unit {
  authenticated[source.digest().0] = source
}

///|
fn authenticate_pve_event_graph(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  bundle : @wire.PveReplayBundle,
  expected_session_id : String,
  expected_authority_key : @bft.PublicKey,
) -> Result[Map[String, @bft.AuthenticatedEvent], PveCentralReplayRefusal] {
  let adapter = @bft.BFTAdapter::new(
    hasher,
    verifier,
    session_id=expected_session_id,
  )
  if !pve_roster_boundary_valid(adapter, bundle, expected_authority_key) {
    return Err(InvalidRosterBoundary)
  }
  let events = pve_signed_events(bundle)
  let seen : Map[String, Bool] = Map([])
  let authenticated : Map[String, @bft.AuthenticatedEvent] = Map([])
  for signed in events {
    if seen.contains(signed.digest.0) {
      return Err(DuplicateEventDigest(signed.digest.0))
    }
    seen[signed.digest.0] = true
    match adapter.deliver(signed) {
      Accepted(source) => remember_authenticated_event(authenticated, source)
      Buffered => ()
      Rejected(_) => return Err(EventAuthenticationRefused(signed.digest.0))
    }
    for source in adapter.take_flushed() {
      remember_authenticated_event(authenticated, source)
    }
    let alerts = adapter.take_flushed_alerts()
    if alerts.length() > 0 {
      return Err(EventAuthenticationRefused(alerts[0].digest.0))
    }
  }
  if authenticated.length() != events.length() {
    return Err(IncompleteEventGraph)
  }
  Ok(authenticated)
}

///|
fn authenticated_pve_transcripts(
  bundle : @wire.PveReplayBundle,
  authenticated : Map[String, @bft.AuthenticatedEvent],
) -> Result[Array[@replay.DungeonAttackTranscript], PveCentralReplayRefusal] {
  let transcripts : Array[@replay.DungeonAttackTranscript] = []
  for wire_transcript in bundle.transcripts {
    let telegraph = match
      authenticated.get(wire_transcript.telegraph.digest.0) {
      Some(source) => source
      None => return Err(IncompleteEventGraph)
    }
    let evidence : Array[@replay.DodgeEvidence] = []
    for wire_evidence in wire_transcript.dodge_evidence {
      let input = match authenticated.get(wire_evidence.input.digest.0) {
        Some(source) => source
        None => return Err(IncompleteEventGraph)
      }
      let receipt = match authenticated.get(wire_evidence.receipt.digest.0) {
        Some(source) => source
        None => return Err(IncompleteEventGraph)
      }
      evidence.push({
        input,
        receipt,
        intent: wire_evidence.intent,
        observed: wire_evidence.observed,
      })
    }
    transcripts.push({
      attack_id: wire_transcript.attack_id,
      telegraph,
      dodge_evidence: evidence,
    })
  }
  Ok(transcripts)
}

///|
/// Package-private capability pair reused by the open-world wrapper. Neither
/// field can be constructed from wire values without passing this verifier.
priv struct OpenedPveCentralReplay {
  checkpoint : @checkpoint.VerifiedCheckpoint
  resolution : @replay.DungeonEncounterResolution
  asset_receipts : Array[OpenedPveAssetReceipt]
}

///|
/// Internal pairing of an inclusion proof and the opaque replay capability
/// for the exact same asset effect.
priv struct OpenedPveAssetReceipt {
  proof : @market.ItemReceiptProof
  replayed : @replay.ReplayedAssetEffect
}

///|
fn pve_item_receipt(
  effect : @replay.AssetEffect,
  source_digest : @bft.Digest,
) -> @market.ItemReceipt? {
  match effect {
    Create(asset_id~, recipient_id~, item_type~, quantity~, output_index~) =>
      Some({
        asset_id,
        recipient_id,
        item_type,
        quantity,
        source_event: source_digest,
        output_index,
      })
    Transfer(..) => None
  }
}

///|
fn open_pve_asset_receipts(
  hasher : &@bft.Hasher,
  bundle : @wire.PveReplayBundle,
  authenticated : Map[String, @bft.AuthenticatedEvent],
  checkpoint : @checkpoint.VerifiedCheckpoint,
  resolution : @replay.DungeonEncounterResolution,
  expected_session_id : String,
) -> Result[Array[OpenedPveAssetReceipt], PveCentralReplayRefusal] {
  let receipts : Array[@market.ItemReceipt] = []
  let replayed_effects : Array[@replay.ReplayedAssetEffect] = []
  let kernel = resolution.loot_kernel()
  let engine = @replay.ReplayEngine::new(kernel, session_id=expected_session_id)
  for index, evidence in bundle.asset_effects {
    let source = match authenticated.get(evidence.source.digest.0) {
      Some(value) => value
      None => return Err(IncompleteEventGraph)
    }
    let replayed = match engine.replay(source, evidence.effect) {
      Replayed(value) => value
      Refused(reason) => return Err(AssetEffectReplayRefused(index, reason))
    }
    let receipt = match
      pve_item_receipt(evidence.effect, replayed.source_digest()) {
      Some(value) => value
      None =>
        return Err(
          AssetEffectReplayRefused(index, @replay.ReplayRefusal::KernelRejected),
        )
    }
    receipts.push(receipt)
    replayed_effects.push(replayed)
  }
  let batch = match @market.build_receipt_batch(hasher, receipts) {
    Built(value) => value
    BatchRejected(reason) => return Err(AssetReceiptBatchRefused(reason))
  }
  if batch.root() != checkpoint.checkpoint().asset_delta_root {
    return Err(AssetDeltaRootMismatch)
  }
  let opened : Array[OpenedPveAssetReceipt] = []
  for index, receipt in batch.receipts() {
    let proof = match batch.proof_for(receipt.asset_id) {
      Some(value) => value
      None => return Err(AssetDeltaRootMismatch)
    }
    opened.push({ proof, replayed: replayed_effects[index] })
  }
  Ok(opened)
}

///|
fn open_decoded_pve_replay_bundle(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  bundle : @wire.PveReplayBundle,
  expected_session_id~ : String,
  expected_authority_key~ : @bft.PublicKey,
  expected_checkpoint_digest~ : @bft.Digest,
) -> Result[OpenedPveCentralReplay, PveCentralReplayRefusal] {
  let signed_checkpoint = bundle.signed_checkpoint
  if signed_checkpoint.checkpoint.session_id != expected_session_id {
    return Err(ExpectedSessionMismatch)
  }
  if signed_checkpoint.authority_key != expected_authority_key {
    return Err(ExpectedAuthorityMismatch)
  }
  if signed_checkpoint.digest != expected_checkpoint_digest {
    return Err(ExpectedCheckpointMismatch)
  }
  if bundle.authority_peer_id == "" {
    return Err(InvalidAuthorityPeer)
  }
  let checkpoint = match
    @checkpoint.open_checkpoint(
      hasher, verifier, expected_authority_key, signed_checkpoint,
    ) {
    Opened(checkpoint) => checkpoint
    Refused(reason) => return Err(CheckpointAuthenticationRefused(reason))
  }
  let authenticated = match
    authenticate_pve_event_graph(
      hasher, verifier, bundle, expected_session_id, expected_authority_key,
    ) {
    Ok(events) => events
    Err(reason) => return Err(reason)
  }
  let transcripts = match authenticated_pve_transcripts(bundle, authenticated) {
    Ok(transcripts) => transcripts
    Err(reason) => return Err(reason)
  }
  let candidate = match
    @replay.prepare_dungeon_encounter(
      hasher,
      session_id=expected_session_id,
      authority_key=expected_authority_key,
      config=bundle.config,
      players=bundle.players,
      attacks=bundle.attacks,
      transcripts~,
    ) {
    CandidateReady(candidate) => candidate
    Refused(reason) => return Err(EncounterReplayRefused(reason))
  }
  match @replay.finalize_dungeon_encounter(candidate, checkpoint) {
    EncounterFinalized(resolution) => {
      let asset_receipts = match
        open_pve_asset_receipts(
          hasher, bundle, authenticated, checkpoint, resolution, expected_session_id,
        ) {
        Ok(value) => value
        Err(reason) => return Err(reason)
      }
      Ok({ checkpoint, resolution, asset_receipts })
    }
    Refused(reason) => Err(EncounterReplayRefused(reason))
  }
}

///|
/// Decode, authenticate and deterministically replay a complete PvE bundle.
/// The expected session, authority and game-checkpoint digest are supplied by
/// the trusted job boundary; none are inferred from the untrusted bundle.
pub fn verify_pve_replay_bundle(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  bundle_bytes : Bytes,
  expected_session_id~ : String,
  expected_authority_key~ : @bft.PublicKey,
  expected_checkpoint_digest~ : @bft.Digest,
  limits~ : @wire.PveReplayWireLimits,
) -> PveCentralReplayResult {
  let bundle = match @wire.decode_pve_replay_bundle(bundle_bytes, limits~) {
    Ok(bundle) => bundle
    Err(reason) => return ReplayRefused(WireReplayRefused(reason))
  }
  match
    open_decoded_pve_replay_bundle(
      hasher,
      verifier,
      bundle,
      expected_session_id~,
      expected_authority_key~,
      expected_checkpoint_digest~,
    ) {
    Err(reason) => ReplayRefused(reason)
    Ok(opened) => {
      let resolution = opened.resolution
      // Obtaining replay_match is the capability boundary: this call is only
      // reachable after every signed event and every checkpoint root matched.
      let replay_match = resolution.replay_match()
      ReplayVerified(PveCentralReplayVerified::{
        session_id: expected_session_id,
        checkpoint_digest: replay_match.checkpoint_digest(),
        authority_key: replay_match.authority_key(),
        epoch: opened.checkpoint.checkpoint().epoch,
        cleared: resolution.cleared(),
        accepted_dodges: resolution.accepted_dodge_count(),
        survivors: resolution.survivor_ids(),
        defeated: resolution.defeated_ids(),
        player_states: resolution.player_states(),
        replayed_assets: opened.asset_receipts.length(),
      })
    }
  }
}
