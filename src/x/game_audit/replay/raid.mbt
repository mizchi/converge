///|
let dungeon_player_attack_table : String = "converge.dungeon.player-attack.v1"

///|
let dungeon_player_attack_receipt_table : String = "converge.dungeon.player-attack-receipt.v1"

///|
pub fn serialize_dungeon_player_attack(
  intent : DungeonPlayerAttackIntent,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "dungeon-player-attack-v1")
  append_field(buffer, intent.encounter_id)
  append_field(buffer, intent.player_id)
  append_int_field(buffer, intent.tick)
  buffer.to_string()
}

///|
pub fn serialize_dungeon_player_attack_receipt(
  receipt : DungeonPlayerAttackReceipt,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "dungeon-player-attack-receipt-v1")
  append_field(buffer, receipt.input_digest.0)
  append_int_field(buffer, receipt.received_tick)
  buffer.to_string()
}

///|
pub fn make_dungeon_player_attack_event(
  peer~ : @types.PeerId,
  counter~ : Int,
  lamport~ : Int,
  deps~ : Array[@types.EventId],
  intent~ : DungeonPlayerAttackIntent,
) -> @types.Event {
  {
    id: { peer, counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(
      tbl=dungeon_player_attack_table,
      row_id=intent.encounter_id +
        ":" +
        intent.tick.to_string() +
        ":" +
        intent.player_id,
      values=[
        ("attack", @types.Value::Str(serialize_dungeon_player_attack(intent))),
      ],
    ),
  }
}

///|
pub fn make_dungeon_player_attack_receipt_event(
  peer~ : @types.PeerId,
  counter~ : Int,
  lamport~ : Int,
  deps~ : Array[@types.EventId],
  receipt~ : DungeonPlayerAttackReceipt,
) -> @types.Event {
  {
    id: { peer, counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(
      tbl=dungeon_player_attack_receipt_table,
      row_id=receipt.input_digest.0,
      values=[
        (
          "receipt",
          @types.Value::Str(serialize_dungeon_player_attack_receipt(receipt)),
        ),
      ],
    ),
  }
}

///|
fn raid_rules_valid(
  rules : DungeonRaidRules,
  attacks : Array[DungeonEncounterAttack],
) -> Bool {
  if rules.boss_max_hp <= 0 ||
    rules.boss_max_hp > 1000000 ||
    rules.player_attack_damage <= 0 ||
    rules.player_attack_damage > rules.boss_max_hp ||
    rules.player_attack_cooldown_ticks < 0 ||
    rules.damage_phase_start_tick < 0 ||
    rules.enrage_tick < rules.damage_phase_start_tick ||
    rules.enrage_tick > 1000000 {
    return false
  }
  for attack in attacks {
    if attack.attack.resolve_tick >= rules.damage_phase_start_tick {
      return false
    }
  }
  true
}

///|
fn dungeon_player_attack_evidence_valid(
  session_id : String,
  authority_key : @bft.PublicKey,
  encounter_id : String,
  player : DungeonPlayer,
  rules : DungeonRaidRules,
  max_late_ticks : Int,
  evidence : DungeonPlayerAttackEvidence,
) -> Bool {
  let intent = evidence.intent
  let observed = evidence.observed
  let input = evidence.input
  let receipt = evidence.receipt
  intent.encounter_id == encounter_id &&
  intent.player_id == player.player_id &&
  intent.tick >= rules.damage_phase_start_tick &&
  intent.tick <= rules.enrage_tick &&
  input.session_id() == session_id &&
  input.author_key() == player.public_key &&
  input.event().id.peer.0 == player.player_id &&
  exact_insert(
    input,
    dungeon_player_attack_table,
    intent.encounter_id + ":" + intent.tick.to_string() + ":" + intent.player_id,
    "attack",
    serialize_dungeon_player_attack(intent),
  ) &&
  observed.input_digest == input.digest() &&
  observed.received_tick >= intent.tick &&
  observed.received_tick - intent.tick <= max_late_ticks &&
  receipt.session_id() == session_id &&
  receipt.author_key() == authority_key &&
  exact_insert(
    receipt,
    dungeon_player_attack_receipt_table,
    input.digest().0,
    "receipt",
    serialize_dungeon_player_attack_receipt(observed),
  ) &&
  one_dependency(receipt, input.event().id)
}

///|
fn dungeon_raid_manifest(
  hasher : &@bft.Hasher,
  defense_manifest : @bft.Digest,
  rules : DungeonRaidRules,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "telegraph-dungeon-raid-kernel-v1")
  append_field(buffer, defense_manifest.0)
  append_int_field(buffer, rules.boss_max_hp)
  append_int_field(buffer, rules.player_attack_damage)
  append_int_field(buffer, rules.player_attack_cooldown_ticks)
  append_int_field(buffer, rules.damage_phase_start_tick)
  append_int_field(buffer, rules.enrage_tick)
  hasher.hash_string(buffer.to_string())
}

///|
fn dungeon_raid_event_root(
  hasher : &@bft.Hasher,
  defense_root : @bft.Digest,
  attacks : Array[DungeonPlayerAttackEvidence],
) -> @bft.Digest {
  let seen : Map[String, Bool] = Map([])
  let leaves : Array[String] = [defense_root.0]
  seen[defense_root.0] = true
  for evidence in attacks {
    let input = evidence.input.digest().0
    if !seen.contains(input) {
      seen[input] = true
      leaves.push(input)
    }
    let receipt = evidence.receipt.digest().0
    if !seen.contains(receipt) {
      seen[receipt] = true
      leaves.push(receipt)
    }
  }
  leaves.sort_by(fn(left, right) { right.compare(left) })
  @merkle.MerkleTree::build(hasher, leaves).root()
}

///|
fn dungeon_raid_public_state_root(
  hasher : &@bft.Hasher,
  defense_root : @bft.Digest,
  boss_hp : Int,
  accepted_player_attacks : Int,
  cooldown_violators : Array[String],
  cleared : Bool,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "telegraph-dungeon-raid-state-v1")
  append_field(buffer, defense_root.0)
  append_int_field(buffer, boss_hp)
  append_int_field(buffer, accepted_player_attacks)
  append_field(buffer, if cleared { "cleared" } else { "failed" })
  let sorted = cooldown_violators.copy()
  sorted.sort_by(fn(left, right) { right.compare(left) })
  append_int_field(buffer, sorted.length())
  for player_id in sorted {
    append_field(buffer, player_id)
  }
  hasher.hash_string(buffer.to_string())
}

///|
pub fn prepare_dungeon_raid(
  hasher : &@bft.Hasher,
  session_id~ : String,
  authority_key~ : @bft.PublicKey,
  encounter_config~ : DungeonEncounterConfig,
  raid_rules~ : DungeonRaidRules,
  players~ : Array[DungeonPlayer],
  attacks~ : Array[DungeonEncounterAttack],
  defense_transcripts~ : Array[DungeonAttackTranscript],
  player_attacks~ : Array[DungeonPlayerAttackEvidence],
) -> DungeonRaidCandidateResult {
  if !raid_rules_valid(raid_rules, attacks) {
    return RaidCandidateRefused(InvalidRaidRules)
  }
  let players_by_id = match roster_map(encounter_config.attack_rules, players) {
    Some(roster) => roster
    None => return RaidCandidateRefused(InvalidRaidRules)
  }
  let defense = match
    prepare_dungeon_encounter(
      hasher,
      session_id~,
      authority_key~,
      config=encounter_config,
      players~,
      attacks~,
      transcripts=defense_transcripts,
    ) {
    CandidateReady(candidate) => candidate
    Refused(reason) => return RaidCandidateRefused(DefensePhaseRefused(reason))
  }
  let by_slot : Map[String, DungeonPlayerAttackEvidence] = Map([])
  let conflicting_slots : Map[String, Bool] = Map([])
  let seen_pairs : Map[String, Bool] = Map([])
  for index, evidence in player_attacks {
    let player = match players_by_id.get(evidence.intent.player_id) {
      Some(value) => value
      None => return RaidCandidateRefused(InvalidPlayerAttackEvidence(index))
    }
    if !dungeon_player_attack_evidence_valid(
        session_id,
        authority_key,
        encounter_config.encounter_id,
        player,
        raid_rules,
        encounter_config.attack_rules.max_backdate_ticks,
        evidence,
      ) {
      return RaidCandidateRefused(InvalidPlayerAttackEvidence(index))
    }
    let pair_key = evidence.input.digest().0 + ":" + evidence.receipt.digest().0
    if !seen_pairs.contains(pair_key) {
      seen_pairs[pair_key] = true
      let slot = evidence.intent.tick.to_string() +
        ":" +
        evidence.intent.player_id
      match by_slot.get(slot) {
        None => by_slot[slot] = evidence
        Some(previous) =>
          if previous.input.digest() == evidence.input.digest() {
            if previous.receipt.digest() != evidence.receipt.digest() {
              return RaidCandidateRefused(
                ConflictingPlayerAttackReceipt(evidence.input.digest()),
              )
            }
          } else {
            conflicting_slots[slot] = true
          }
      }
    }
  }
  let survivors : Map[String, Bool] = Map([])
  for player_id in defense.survivors {
    survivors[player_id] = true
  }
  let sorted_players = players.copy()
  sorted_players.sort_by(fn(left, right) {
    right.player_id.compare(left.player_id)
  })
  let last_attack_tick : Map[String, Int] = Map([])
  let cooldown_violators : Map[String, Bool] = Map([])
  let mut boss_hp = raid_rules.boss_max_hp
  let mut accepted_player_attacks = 0
  for tick in raid_rules.damage_phase_start_tick..<=raid_rules.enrage_tick {
    for player in sorted_players {
      let slot = tick.to_string() + ":" + player.player_id
      if conflicting_slots.contains(slot) {
        cooldown_violators[player.player_id] = true
        continue
      }
      match by_slot.get(slot) {
        None => ()
        Some(_) => {
          if boss_hp <= 0 || !survivors.contains(player.player_id) {
            continue
          }
          let previous_tick = last_attack_tick
            .get(player.player_id)
            .unwrap_or(0)
          let cooldown_ready = @audit.pvp_attack_cooldown_allowed(
            previous_tick~,
            has_previous=last_attack_tick.contains(player.player_id),
            tick~,
            cooldown_ticks=raid_rules.player_attack_cooldown_ticks,
          )
          if !cooldown_ready {
            cooldown_violators[player.player_id] = true
            continue
          }
          last_attack_tick[player.player_id] = tick
          boss_hp = @audit.hp_after_encounter_damage(
            boss_hp,
            raid_rules.player_attack_damage,
            was_hit=true,
          )
          accepted_player_attacks += 1
        }
      }
    }
  }
  let violator_ids : Array[String] = []
  for player in sorted_players {
    if cooldown_violators.contains(player.player_id) {
      violator_ids.push(player.player_id)
    }
  }
  let cleared = @audit.raid_boss_clear_allowed(
    defense_phase_cleared=defense.cleared,
    boss_hp~,
  )
  let manifest = dungeon_raid_manifest(hasher, defense.manifest, raid_rules)
  if manifest.0 == "" {
    return RaidCandidateRefused(EmptyRaidManifest)
  }
  let event_root = dungeon_raid_event_root(
    hasher,
    defense.event_root,
    player_attacks,
  )
  let public_state_root = dungeon_raid_public_state_root(
    hasher,
    defense.public_state_root,
    boss_hp,
    accepted_player_attacks,
    violator_ids,
    cleared,
  )
  RaidCandidateReady(DungeonRaidCandidate::{
    defense,
    manifest,
    event_root,
    public_state_root,
    boss_hp_value: boss_hp,
    accepted_player_attacks_value: accepted_player_attacks,
    cooldown_violators_value: violator_ids,
    cleared_value: cleared,
  })
}

///|
pub fn DungeonRaidCandidate::manifest_digest(
  self : DungeonRaidCandidate,
) -> @bft.Digest {
  self.manifest
}

///|
pub fn DungeonRaidCandidate::event_root(
  self : DungeonRaidCandidate,
) -> @bft.Digest {
  self.event_root
}

///|
pub fn DungeonRaidCandidate::public_state_root(
  self : DungeonRaidCandidate,
) -> @bft.Digest {
  self.public_state_root
}

///|
pub fn DungeonRaidCandidate::boss_hp(self : DungeonRaidCandidate) -> Int {
  self.boss_hp_value
}

///|
pub fn DungeonRaidCandidate::cleared(self : DungeonRaidCandidate) -> Bool {
  self.cleared_value
}

///|
pub fn DungeonRaidCandidate::accepted_player_attack_count(
  self : DungeonRaidCandidate,
) -> Int {
  self.accepted_player_attacks_value
}

///|
pub fn DungeonRaidCandidate::cooldown_violator_ids(
  self : DungeonRaidCandidate,
) -> Array[String] {
  self.cooldown_violators_value.copy()
}

///|
pub fn finalize_dungeon_raid(
  candidate : DungeonRaidCandidate,
  checkpoint : @checkpoint.VerifiedCheckpoint,
) -> DungeonRaidFinalizeResult {
  let committed = checkpoint.checkpoint()
  if checkpoint.authority_key() != candidate.defense.authority {
    return RaidFinalizeRefused(RaidCheckpointAuthorityMismatch)
  }
  if committed.session_id != candidate.defense.session {
    return RaidFinalizeRefused(RaidCheckpointSessionMismatch)
  }
  if committed.manifest_digest != candidate.manifest {
    return RaidFinalizeRefused(RaidCheckpointManifestMismatch)
  }
  if committed.event_root != candidate.event_root {
    return RaidFinalizeRefused(RaidCheckpointEventRootMismatch)
  }
  if committed.public_state_root != candidate.public_state_root {
    return RaidFinalizeRefused(RaidCheckpointPublicStateRootMismatch)
  }
  if committed.hidden_state_commitment is Some(_) {
    return RaidFinalizeRefused(RaidCheckpointHiddenStatePresent)
  }
  RaidFinalized(DungeonRaidResolution::{
    candidate,
    checkpoint_digest: checkpoint.digest(),
  })
}

///|
pub fn DungeonRaidResolution::boss_hp(self : DungeonRaidResolution) -> Int {
  self.candidate.boss_hp_value
}

///|
pub fn DungeonRaidResolution::cleared(self : DungeonRaidResolution) -> Bool {
  self.candidate.cleared_value
}

///|
pub fn DungeonRaidResolution::survivor_ids(
  self : DungeonRaidResolution,
) -> Array[String] {
  self.candidate.defense.survivors.copy()
}

///|
pub fn DungeonRaidResolution::checkpoint_digest(
  self : DungeonRaidResolution,
) -> @bft.Digest {
  self.checkpoint_digest
}
