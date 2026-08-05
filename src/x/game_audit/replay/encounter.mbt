///|
fn valid_encounter_config(config : DungeonEncounterConfig) -> Bool {
  config.encounter_id != "" &&
  config.player_max_hp > 0 &&
  valid_config(config.attack_rules)
}

///|
fn sort_encounter_attacks(
  attacks : Array[DungeonEncounterAttack],
) -> Array[DungeonEncounterAttack] {
  let sorted = attacks.copy()
  sorted.sort_by(fn(a, b) {
    if a.attack.visible_tick != b.attack.visible_tick {
      a.attack.visible_tick.compare(b.attack.visible_tick)
    } else if a.attack.resolve_tick != b.attack.resolve_tick {
      a.attack.resolve_tick.compare(b.attack.resolve_tick)
    } else {
      b.attack.attack_id.compare(a.attack.attack_id)
    }
  })
  sorted
}

///|
/// The first encounter kernel deliberately requires non-overlapping attacks.
/// This makes the position committed before each dodge unambiguous.
fn canonical_attack_plan(
  rules : TelegraphDungeonConfig,
  attacks : Array[DungeonEncounterAttack],
) -> Array[DungeonEncounterAttack]? {
  if attacks.length() == 0 {
    return None
  }
  let sorted = sort_encounter_attacks(attacks)
  let seen : Map[String, Bool] = Map([])
  let mut previous_resolve = -1
  let mut first = true
  for spec in sorted {
    let attack = spec.attack
    if spec.damage <= 0 ||
      !valid_attack(rules, attack) ||
      seen.contains(attack.attack_id) ||
      (!first && attack.visible_tick < previous_resolve) {
      return None
    }
    seen[attack.attack_id] = true
    previous_resolve = attack.resolve_tick
    first = false
  }
  Some(sorted)
}

///|
pub fn telegraph_dungeon_encounter_manifest(
  hasher : &@bft.Hasher,
  authority_key : @bft.PublicKey,
  config : DungeonEncounterConfig,
  players : Array[DungeonPlayer],
  attacks : Array[DungeonEncounterAttack],
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "telegraph-dungeon-encounter-kernel-v1")
  append_field(buffer, config.encounter_id)
  append_int_field(buffer, config.player_max_hp)
  append_field(
    buffer,
    telegraph_dungeon_manifest(
      hasher,
      authority_key,
      config.attack_rules,
      players,
    ).0,
  )
  let sorted = sort_encounter_attacks(attacks)
  append_int_field(buffer, sorted.length())
  for spec in sorted {
    append_field(buffer, serialize_telegraphed_attack(spec.attack))
    append_int_field(buffer, spec.damage)
  }
  hasher.hash_string(buffer.to_string())
}

///|
pub fn dungeon_encounter_transcript_root(
  hasher : &@bft.Hasher,
  transcripts : Array[DungeonAttackTranscript],
) -> @bft.Digest {
  let seen : Map[String, Bool] = Map([])
  let payloads : Array[String] = []
  let add = fn(digest : @bft.Digest) {
    if !seen.contains(digest.0) {
      seen[digest.0] = true
      payloads.push(digest.0)
    }
  }
  for transcript in transcripts {
    add(transcript.telegraph.digest())
    for evidence in transcript.dodge_evidence {
      add(evidence.input.digest())
      add(evidence.receipt.digest())
    }
  }
  payloads.sort_by(fn(a, b) { b.compare(a) })
  @merkle.MerkleTree::build(hasher, payloads).root()
}

///|
fn encounter_public_state_root(
  hasher : &@bft.Hasher,
  session_id : String,
  encounter_id : String,
  states : Array[DungeonEncounterPlayerState],
  cleared : Bool,
  accepted_dodges : Int,
  equivocators : Array[String],
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "telegraph-dungeon-public-state-v1")
  append_field(buffer, session_id)
  append_field(buffer, encounter_id)
  append_field(buffer, if cleared { "cleared" } else { "failed" })
  append_int_field(buffer, accepted_dodges)
  let sorted_states = states.copy()
  sorted_states.sort_by(fn(a, b) { b.player_id.compare(a.player_id) })
  append_int_field(buffer, sorted_states.length())
  for state in sorted_states {
    append_field(buffer, state.player_id)
    append_int_field(buffer, state.position_x)
    append_int_field(buffer, state.hp)
  }
  let sorted_equivocators = equivocators.copy()
  sorted_equivocators.sort_by(fn(a, b) { b.compare(a) })
  append_int_field(buffer, sorted_equivocators.length())
  for player_id in sorted_equivocators {
    append_field(buffer, player_id)
  }
  hasher.hash_string(buffer.to_string())
}

///|
/// Deterministically replay a full planned encounter without granting loot.
/// The returned candidate exposes only roots needed for checkpoint signing.
pub fn prepare_dungeon_encounter(
  hasher : &@bft.Hasher,
  session_id~ : String,
  authority_key~ : @bft.PublicKey,
  config~ : DungeonEncounterConfig,
  players~ : Array[DungeonPlayer],
  attacks~ : Array[DungeonEncounterAttack],
  transcripts~ : Array[DungeonAttackTranscript],
) -> DungeonEncounterCandidateResult {
  if session_id == "" ||
    authority_key.0 == "" ||
    !valid_encounter_config(config) {
    return Refused(InvalidEncounterConfiguration)
  }
  match roster_map(config.attack_rules, players) {
    Some(_) => ()
    None => return Refused(InvalidEncounterConfiguration)
  }
  let plan = match canonical_attack_plan(config.attack_rules, attacks) {
    Some(plan) => plan
    None => return Refused(InvalidAttackPlan)
  }
  let planned_ids : Map[String, Bool] = Map([])
  for spec in plan {
    planned_ids[spec.attack.attack_id] = true
  }
  let transcript_by_id : Map[String, DungeonAttackTranscript] = Map([])
  for transcript in transcripts {
    if !planned_ids.contains(transcript.attack_id) {
      return Refused(UnknownAttackTranscript(transcript.attack_id))
    }
    if transcript_by_id.contains(transcript.attack_id) {
      return Refused(DuplicateAttackTranscript(transcript.attack_id))
    }
    transcript_by_id[transcript.attack_id] = transcript
  }
  for spec in plan {
    if !transcript_by_id.contains(spec.attack.attack_id) {
      return Refused(MissingAttackTranscript(spec.attack.attack_id))
    }
  }
  let manifest = telegraph_dungeon_encounter_manifest(
    hasher, authority_key, config, players, plan,
  )
  if manifest.0 == "" {
    return Refused(EmptyEncounterManifest)
  }
  let positions : Map[String, Int] = Map([])
  let hit_points : Map[String, Int] = Map([])
  for player in players {
    positions[player.player_id] = player.initial_x
    hit_points[player.player_id] = config.player_max_hp
  }
  let all_equivocators : Map[String, Bool] = Map([])
  let mut accepted_dodges = 0
  for spec in plan {
    let attack = spec.attack
    let transcript = match transcript_by_id.get(attack.attack_id) {
      Some(value) => value
      None => return Refused(MissingAttackTranscript(attack.attack_id))
    }
    if !telegraph_source_valid(
        session_id,
        authority_key,
        transcript.telegraph,
        attack,
      ) {
      return Refused(InvalidAttackTelegraph(attack.attack_id))
    }
    let active_players : Array[DungeonPlayer] = []
    let active_by_id : Map[String, DungeonPlayer] = Map([])
    for player in players {
      let hp = hit_points.get(player.player_id).unwrap_or(0)
      if hp > 0 {
        let current = DungeonPlayer::{
          ..player,
          initial_x: positions.get(player.player_id).unwrap_or(player.initial_x),
        }
        active_players.push(current)
        active_by_id[player.player_id] = current
      }
    }
    let step = replay_attack_step(
      session_id,
      authority_key,
      config.attack_rules,
      active_by_id,
      active_players,
      transcript.telegraph,
      attack,
      transcript.dodge_evidence,
    )
    accepted_dodges += step.accepted_dodges
    for player in active_players {
      match step.positions.get(player.player_id) {
        Some(position) => positions[player.player_id] = position
        None => ()
      }
    }
    for player_id in step.hit {
      hit_points[player_id] = @audit.hp_after_encounter_damage(
        hit_points.get(player_id).unwrap_or(0),
        spec.damage,
        was_hit=true,
      )
    }
    for player_id in step.equivocators {
      all_equivocators[player_id] = true
    }
  }
  // Keep output stable even if callers provide roster or transcript arrays in
  // different orders.
  let sorted_players = players.copy()
  sorted_players.sort_by(fn(a, b) { b.player_id.compare(a.player_id) })
  let player_states : Array[DungeonEncounterPlayerState] = []
  let survivors : Array[String] = []
  let defeated : Array[String] = []
  let equivocators : Array[String] = []
  for player in sorted_players {
    let hp = hit_points.get(player.player_id).unwrap_or(0)
    player_states.push({
      player_id: player.player_id,
      position_x: positions.get(player.player_id).unwrap_or(player.initial_x),
      hp,
    })
    if hp > 0 {
      survivors.push(player.player_id)
    } else {
      defeated.push(player.player_id)
    }
    if all_equivocators.contains(player.player_id) {
      equivocators.push(player.player_id)
    }
  }
  let cleared = @audit.encounter_clear_allowed(
    schedule_complete=true,
    survivor_count=survivors.length(),
  )
  let event_root = dungeon_encounter_transcript_root(hasher, transcripts)
  let public_state_root = encounter_public_state_root(
    hasher,
    session_id,
    config.encounter_id,
    player_states,
    cleared,
    accepted_dodges,
    equivocators,
  )
  CandidateReady(DungeonEncounterCandidate::{
    session: session_id,
    authority: authority_key,
    encounter_id: config.encounter_id,
    loot_item_type: config.attack_rules.loot_item_type,
    manifest,
    event_root,
    public_state_root,
    player_states,
    survivors,
    defeated,
    equivocators,
    accepted_dodges,
    cleared,
  })
}

///|
pub fn DungeonEncounterCandidate::manifest_digest(
  self : DungeonEncounterCandidate,
) -> @bft.Digest {
  self.manifest
}

///|
pub fn DungeonEncounterCandidate::event_root(
  self : DungeonEncounterCandidate,
) -> @bft.Digest {
  self.event_root
}

///|
pub fn DungeonEncounterCandidate::public_state_root(
  self : DungeonEncounterCandidate,
) -> @bft.Digest {
  self.public_state_root
}

///|
/// Bind a deterministic candidate to a verified authority checkpoint before
/// exposing any gameplay or loot capability.
pub fn finalize_dungeon_encounter(
  candidate : DungeonEncounterCandidate,
  checkpoint : @checkpoint.VerifiedCheckpoint,
) -> DungeonEncounterFinalizeResult {
  let committed = checkpoint.checkpoint()
  if checkpoint.authority_key() != candidate.authority {
    return Refused(CheckpointAuthorityMismatch)
  }
  if committed.session_id != candidate.session {
    return Refused(CheckpointSessionMismatch)
  }
  if committed.manifest_digest != candidate.manifest {
    return Refused(CheckpointManifestMismatch)
  }
  if committed.event_root != candidate.event_root {
    return Refused(CheckpointEventRootMismatch)
  }
  if committed.public_state_root != candidate.public_state_root {
    return Refused(CheckpointPublicStateRootMismatch)
  }
  EncounterFinalized(DungeonEncounterResolution::{
    candidate,
    checkpoint_digest: checkpoint.digest(),
  })
}

///|
pub fn DungeonEncounterResolution::replay_match(
  self : DungeonEncounterResolution,
) -> CheckpointReplayMatch {
  CheckpointReplayMatch::{
    checkpoint_digest: self.checkpoint_digest,
    authority_key: self.candidate.authority,
  }
}

///|
pub fn CheckpointReplayMatch::checkpoint_digest(
  self : CheckpointReplayMatch,
) -> @bft.Digest {
  self.checkpoint_digest
}

///|
pub fn CheckpointReplayMatch::authority_key(
  self : CheckpointReplayMatch,
) -> @bft.PublicKey {
  self.authority_key
}

///|
pub fn DungeonEncounterResolution::cleared(
  self : DungeonEncounterResolution,
) -> Bool {
  self.candidate.cleared
}

///|
pub fn DungeonEncounterResolution::player_states(
  self : DungeonEncounterResolution,
) -> Array[DungeonEncounterPlayerState] {
  self.candidate.player_states.copy()
}

///|
pub fn DungeonEncounterResolution::survivor_ids(
  self : DungeonEncounterResolution,
) -> Array[String] {
  self.candidate.survivors.copy()
}

///|
pub fn DungeonEncounterResolution::defeated_ids(
  self : DungeonEncounterResolution,
) -> Array[String] {
  self.candidate.defeated.copy()
}

///|
pub fn DungeonEncounterResolution::equivocator_ids(
  self : DungeonEncounterResolution,
) -> Array[String] {
  self.candidate.equivocators.copy()
}

///|
pub fn DungeonEncounterResolution::accepted_dodge_count(
  self : DungeonEncounterResolution,
) -> Int {
  self.candidate.accepted_dodges
}

///|
pub fn DungeonEncounterResolution::manifest_digest(
  self : DungeonEncounterResolution,
) -> @bft.Digest {
  self.candidate.manifest
}

///|
pub fn DungeonEncounterResolution::public_state_root(
  self : DungeonEncounterResolution,
) -> @bft.Digest {
  self.candidate.public_state_root
}

///|
pub fn dungeon_encounter_loot_asset_id(
  session_id : String,
  encounter_id : String,
  recipient_id : String,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "dungeon-encounter-loot-v1")
  append_field(buffer, session_id)
  append_field(buffer, encounter_id)
  append_field(buffer, recipient_id)
  buffer.to_string()
}

///|
fn deterministic_encounter_loot_effect(
  candidate : DungeonEncounterCandidate,
  recipient_id : String,
) -> AssetEffect {
  AssetEffect::Create(
    asset_id=dungeon_encounter_loot_asset_id(
      candidate.session,
      candidate.encounter_id,
      recipient_id,
    ),
    recipient_id~,
    item_type=candidate.loot_item_type,
    quantity=1,
    output_index=0,
  )
}

///|
pub fn DungeonEncounterResolution::loot_effect(
  self : DungeonEncounterResolution,
  recipient_id : String,
) -> AssetEffect? {
  for state in self.candidate.player_states {
    if state.player_id == recipient_id &&
      @audit.encounter_loot_allowed(
        encounter_cleared=self.candidate.cleared,
        player_hp=state.hp,
      ) {
      return Some(
        deterministic_encounter_loot_effect(self.candidate, recipient_id),
      )
    }
  }
  None
}

///|
pub fn DungeonEncounterResolution::loot_kernel(
  self : DungeonEncounterResolution,
) -> DungeonEncounterLootKernel {
  let eligible : Map[String, Bool] = Map([])
  if self.candidate.cleared {
    for player_id in self.candidate.survivors {
      eligible[player_id] = true
    }
  }
  DungeonEncounterLootKernel::{
    session: self.candidate.session,
    authority: self.candidate.authority,
    encounter_id: self.candidate.encounter_id,
    loot_item_type: self.candidate.loot_item_type,
    manifest: self.candidate.manifest,
    eligible,
  }
}

///|
pub impl AssetReplayKernel for DungeonEncounterLootKernel with fn manifest_digest(
  self : DungeonEncounterLootKernel,
) -> @bft.Digest {
  self.manifest
}

///|
pub impl AssetReplayKernel for DungeonEncounterLootKernel with fn replay(
  self : DungeonEncounterLootKernel,
  source : @bft.AuthenticatedEvent,
  effect : AssetEffect,
) -> Bool {
  if source.session_id() != self.session ||
    source.author_key() != self.authority {
    return false
  }
  match effect {
    AssetEffect::Create(
      asset_id~,
      recipient_id~,
      item_type~,
      quantity~,
      output_index~
    ) =>
      self.eligible.contains(recipient_id) &&
      asset_id ==
      dungeon_encounter_loot_asset_id(
        self.session,
        self.encounter_id,
        recipient_id,
      ) &&
      item_type == self.loot_item_type &&
      quantity == 1 &&
      output_index == 0 &&
      exact_insert(
        source,
        "converge.asset-effect.v1",
        asset_id,
        "effect",
        serialize_asset_effect(effect),
      )
    _ => false
  }
}
