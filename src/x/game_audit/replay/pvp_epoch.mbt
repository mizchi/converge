///|
let pvp_command_table : String = "converge.pvp.command.v1"

///|
let pvp_receipt_table : String = "converge.pvp.command-receipt.v1"

///|
let max_pvp_players : Int = 64

///|
let max_pvp_ticks : Int = 256

///|
let max_pvp_commands : Int = 4096

///|
let max_pvp_coordinate : Int = 1000000

///|
let max_pvp_score : Int = 1000000

///|
let max_pvp_text_length : Int = 256

///|
fn pvp_abs(value : Int) -> Int {
  if value >= 0 {
    value
  } else {
    -value
  }
}

///|
fn serialize_optional_target(buffer : StringBuilder, target : String?) -> Unit {
  match target {
    None => buffer.write_char('0')
    Some(value) => {
      buffer.write_char('1')
      append_field(buffer, value)
    }
  }
}

///|
pub fn serialize_pvp_command(intent : PvpCommandIntent) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "pvp-command-v1")
  append_field(buffer, intent.match_id)
  append_int_field(buffer, intent.epoch)
  append_field(buffer, intent.base_checkpoint_digest.0)
  append_int_field(buffer, intent.tick)
  append_field(buffer, intent.player_id)
  append_int_field(buffer, intent.move_to_x)
  serialize_optional_target(buffer, intent.attack_target_id)
  buffer.to_string()
}

///|
pub fn serialize_pvp_command_receipt(receipt : PvpCommandReceipt) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "pvp-command-receipt-v1")
  append_field(buffer, receipt.command_digest.0)
  append_int_field(buffer, receipt.received_tick)
  buffer.to_string()
}

///|
pub fn make_pvp_command_event(
  peer~ : @types.PeerId,
  counter~ : Int,
  lamport~ : Int,
  deps~ : Array[@types.EventId],
  intent~ : PvpCommandIntent,
) -> @types.Event {
  {
    id: { peer, counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(
      tbl=pvp_command_table,
      row_id=intent.match_id +
        ":" +
        intent.epoch.to_string() +
        ":" +
        intent.tick.to_string() +
        ":" +
        intent.player_id,
      values=[("command", @types.Value::Str(serialize_pvp_command(intent)))],
    ),
  }
}

///|
pub fn make_pvp_command_receipt_event(
  peer~ : @types.PeerId,
  counter~ : Int,
  lamport~ : Int,
  deps~ : Array[@types.EventId],
  receipt~ : PvpCommandReceipt,
) -> @types.Event {
  {
    id: { peer, counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(
      tbl=pvp_receipt_table,
      row_id=receipt.command_digest.0,
      values=[
        ("receipt", @types.Value::Str(serialize_pvp_command_receipt(receipt))),
      ],
    ),
  }
}

///|
fn pvp_config_valid(config : PvpEpochConfig) -> Bool {
  config.match_id != "" &&
  config.match_id.length() <= max_pvp_text_length &&
  config.epoch >= 0 &&
  config.previous_checkpoint.0 != "" &&
  config.player_max_hp > 0 &&
  config.player_max_hp <= 1000000 &&
  config.ticks_per_epoch > 0 &&
  config.ticks_per_epoch <= max_pvp_ticks &&
  config.max_late_ticks >= 0 &&
  config.max_late_ticks <= max_pvp_ticks &&
  config.max_move_distance >= 0 &&
  config.max_move_distance <= max_pvp_coordinate &&
  config.arena_min_x >= -max_pvp_coordinate &&
  config.arena_max_x <= max_pvp_coordinate &&
  config.arena_min_x <= config.arena_max_x &&
  config.attack_range >= 0 &&
  config.attack_range <= max_pvp_coordinate &&
  config.attack_damage > 0 &&
  config.attack_damage <= config.player_max_hp &&
  config.score_per_elimination > 0 &&
  config.score_per_elimination <= 1000
}

///|
fn pvp_team_map(teams : Array[PvpTeam]) -> Map[String, PvpTeam]? {
  if teams.length() != 2 {
    return None
  }
  let by_id : Map[String, PvpTeam] = Map([])
  for team in teams {
    if team.team_id == "" ||
      team.team_id.length() > max_pvp_text_length ||
      team.initial_score < 0 ||
      team.initial_score > max_pvp_score ||
      by_id.contains(team.team_id) {
      return None
    }
    by_id[team.team_id] = team
  }
  Some(by_id)
}

///|
fn pvp_player_map(
  config : PvpEpochConfig,
  teams : Map[String, PvpTeam],
  players : Array[PvpPlayer],
) -> Map[String, PvpPlayer]? {
  if players.length() < 2 || players.length() > max_pvp_players {
    return None
  }
  let by_id : Map[String, PvpPlayer] = Map([])
  let keys : Map[String, Bool] = Map([])
  let represented_teams : Map[String, Bool] = Map([])
  for player in players {
    if player.player_id == "" ||
      player.player_id.length() > max_pvp_text_length ||
      player.public_key.0 == "" ||
      player.public_key.0.length() > max_pvp_text_length ||
      !teams.contains(player.team_id) ||
      player.initial_x < config.arena_min_x ||
      player.initial_x > config.arena_max_x ||
      player.initial_hp < 0 ||
      player.initial_hp > config.player_max_hp ||
      by_id.contains(player.player_id) ||
      keys.contains(player.public_key.0) {
      return None
    }
    by_id[player.player_id] = player
    keys[player.public_key.0] = true
    represented_teams[player.team_id] = true
  }
  if represented_teams.length() != 2 {
    return None
  }
  Some(by_id)
}

///|
fn pvp_witness_roster_valid(
  referee_key : @bft.PublicKey,
  witnesses : Array[@witness_manifest.ReplayWitnessIdentity],
  max_faults : Int,
) -> Bool {
  if witnesses.length() > max_pvp_players ||
    !@audit.replay_witness_policy_valid(witnesses.length(), max_faults) {
    return false
  }
  let ids : Map[String, Bool] = Map([])
  let keys : Map[String, Bool] = Map([])
  for witness in witnesses {
    if witness.id == "" ||
      witness.id.length() > max_pvp_text_length ||
      witness.key.0 == "" ||
      witness.key.0.length() > max_pvp_text_length ||
      witness.key == referee_key ||
      ids.contains(witness.id) ||
      keys.contains(witness.key.0) {
      return false
    }
    ids[witness.id] = true
    keys[witness.key.0] = true
  }
  true
}

///|
pub fn pvp_epoch_game_manifest(
  hasher : &@bft.Hasher,
  session_id : String,
  referee_key : @bft.PublicKey,
  config : PvpEpochConfig,
  teams : Array[PvpTeam],
  players : Array[PvpPlayer],
  attack_cooldown_ticks? : Int = 0,
  objective_rule? : PvpObjectiveRule? = None,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  let extended_rules = attack_cooldown_ticks > 0 || objective_rule is Some(_)
  append_field(
    buffer,
    if extended_rules {
      "public-pvp-epoch-kernel-v2"
    } else {
      "public-pvp-epoch-kernel-v1"
    },
  )
  append_field(buffer, session_id)
  append_field(buffer, referee_key.0)
  append_field(buffer, config.match_id)
  append_int_field(buffer, config.epoch)
  append_field(buffer, config.previous_checkpoint.0)
  append_int_field(buffer, config.player_max_hp)
  append_int_field(buffer, config.ticks_per_epoch)
  append_int_field(buffer, config.max_late_ticks)
  append_int_field(buffer, config.max_move_distance)
  append_int_field(buffer, config.arena_min_x)
  append_int_field(buffer, config.arena_max_x)
  append_int_field(buffer, config.attack_range)
  append_int_field(buffer, config.attack_damage)
  append_int_field(buffer, config.score_per_elimination)
  if extended_rules {
    append_int_field(buffer, attack_cooldown_ticks)
    match objective_rule {
      None => append_field(buffer, "no-objective")
      Some(rule) => {
        append_field(buffer, "objective")
        append_int_field(buffer, rule.center_x)
        append_int_field(buffer, rule.radius)
        append_int_field(buffer, rule.score_per_tick)
      }
    }
  }
  let sorted_teams = teams.copy()
  sorted_teams.sort_by(fn(left, right) { right.team_id.compare(left.team_id) })
  append_int_field(buffer, sorted_teams.length())
  for team in sorted_teams {
    append_field(buffer, team.team_id)
    append_int_field(buffer, team.initial_score)
  }
  let sorted_players = players.copy()
  sorted_players.sort_by(fn(left, right) {
    right.player_id.compare(left.player_id)
  })
  append_int_field(buffer, sorted_players.length())
  for player in sorted_players {
    append_field(buffer, player.player_id)
    append_field(buffer, player.public_key.0)
    append_field(buffer, player.team_id)
    append_int_field(buffer, player.initial_x)
    append_int_field(buffer, player.initial_hp)
  }
  hasher.hash_string(buffer.to_string())
}

///|
pub fn pvp_epoch_transcript_root(
  hasher : &@bft.Hasher,
  transcript : Array[PvpCommandEvidence],
) -> @bft.Digest {
  let seen : Map[String, Bool] = Map([])
  let payloads : Array[String] = []
  for evidence in transcript {
    let input = evidence.input.digest().0
    if !seen.contains(input) {
      seen[input] = true
      payloads.push(input)
    }
    let receipt = evidence.receipt.digest().0
    if !seen.contains(receipt) {
      seen[receipt] = true
      payloads.push(receipt)
    }
  }
  payloads.sort_by(fn(left, right) { right.compare(left) })
  @merkle.MerkleTree::build(hasher, payloads).root()
}

///|
fn pvp_command_row_id(intent : PvpCommandIntent) -> String {
  intent.match_id +
  ":" +
  intent.epoch.to_string() +
  ":" +
  intent.tick.to_string() +
  ":" +
  intent.player_id
}

///|
fn pvp_command_evidence_valid(
  session_id : String,
  referee_key : @bft.PublicKey,
  config : PvpEpochConfig,
  player : PvpPlayer,
  evidence : PvpCommandEvidence,
) -> Bool {
  let input = evidence.input
  let receipt = evidence.receipt
  let intent = evidence.intent
  let observed = evidence.observed
  let target_id_valid = match intent.attack_target_id {
    None => true
    Some(target_id) => target_id.length() <= max_pvp_text_length
  }
  intent.match_id == config.match_id &&
  intent.epoch == config.epoch &&
  intent.base_checkpoint_digest == config.previous_checkpoint &&
  intent.player_id == player.player_id &&
  target_id_valid &&
  input.session_id() == session_id &&
  input.author_key() == player.public_key &&
  input.event().id.peer.0 == player.player_id &&
  exact_insert(
    input,
    pvp_command_table,
    pvp_command_row_id(intent),
    "command",
    serialize_pvp_command(intent),
  ) &&
  observed.command_digest == input.digest() &&
  receipt.session_id() == session_id &&
  receipt.author_key() == referee_key &&
  exact_insert(
    receipt,
    pvp_receipt_table,
    input.digest().0,
    "receipt",
    serialize_pvp_command_receipt(observed),
  ) &&
  one_dependency(receipt, input.event().id)
}

///|
fn pvp_slot_key(intent : PvpCommandIntent) -> String {
  intent.tick.to_string() + ":" + intent.player_id
}

///|
fn pvp_public_state_root(
  hasher : &@bft.Hasher,
  session_id : String,
  config : PvpEpochConfig,
  player_states : Array[PvpPlayerState],
  team_states : Array[PvpTeamState],
  equivocators : Array[String],
  cooldown_violators : Array[String],
  accepted_commands : Int,
  attack_cooldown_ticks : Int,
  objective_rule : PvpObjectiveRule?,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  let extended_rules = attack_cooldown_ticks > 0 || objective_rule is Some(_)
  append_field(
    buffer,
    if extended_rules {
      "public-pvp-epoch-state-v2"
    } else {
      "public-pvp-epoch-state-v1"
    },
  )
  append_field(buffer, session_id)
  append_field(buffer, config.match_id)
  append_int_field(buffer, config.epoch)
  append_int_field(buffer, accepted_commands)
  let sorted_players = player_states.copy()
  sorted_players.sort_by(fn(left, right) {
    right.player_id.compare(left.player_id)
  })
  append_int_field(buffer, sorted_players.length())
  for player in sorted_players {
    append_field(buffer, player.player_id)
    append_field(buffer, player.team_id)
    append_int_field(buffer, player.position_x)
    append_int_field(buffer, player.hp)
  }
  let sorted_teams = team_states.copy()
  sorted_teams.sort_by(fn(left, right) { right.team_id.compare(left.team_id) })
  append_int_field(buffer, sorted_teams.length())
  for team in sorted_teams {
    append_field(buffer, team.team_id)
    append_int_field(buffer, team.score)
  }
  let sorted_equivocators = equivocators.copy()
  sorted_equivocators.sort_by(fn(left, right) { right.compare(left) })
  append_int_field(buffer, sorted_equivocators.length())
  for player_id in sorted_equivocators {
    append_field(buffer, player_id)
  }
  if extended_rules {
    append_int_field(buffer, attack_cooldown_ticks)
    let sorted_violators = cooldown_violators.copy()
    sorted_violators.sort_by(fn(left, right) { right.compare(left) })
    append_int_field(buffer, sorted_violators.length())
    for player_id in sorted_violators {
      append_field(buffer, player_id)
    }
    match objective_rule {
      None => append_field(buffer, "no-objective")
      Some(rule) => {
        append_field(buffer, "objective")
        append_int_field(buffer, rule.center_x)
        append_int_field(buffer, rule.radius)
        append_int_field(buffer, rule.score_per_tick)
      }
    }
  }
  hasher.hash_string(buffer.to_string())
}

///|
fn pvp_extended_rules_valid(
  config : PvpEpochConfig,
  attack_cooldown_ticks : Int,
  objective_rule : PvpObjectiveRule?,
) -> Bool {
  if attack_cooldown_ticks < 0 || attack_cooldown_ticks > config.ticks_per_epoch {
    return false
  }
  match objective_rule {
    None => true
    Some(rule) =>
      rule.center_x >= config.arena_min_x &&
      rule.center_x <= config.arena_max_x &&
      rule.radius >= 0 &&
      rule.radius <= max_pvp_coordinate &&
      rule.score_per_tick > 0 &&
      rule.score_per_tick <= 1000
  }
}

///|
fn pvp_no_asset_delta_root(
  hasher : &@bft.Hasher,
  session_id : String,
  config : PvpEpochConfig,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "public-pvp-no-asset-delta-v1")
  append_field(buffer, session_id)
  append_field(buffer, config.match_id)
  append_int_field(buffer, config.epoch)
  hasher.hash_string(buffer.to_string())
}

///|
fn pvp_other_team(sorted_teams : Array[PvpTeam], team_id : String) -> String {
  if sorted_teams[0].team_id == team_id {
    sorted_teams[1].team_id
  } else {
    sorted_teams[0].team_id
  }
}

///|
pub fn prepare_pvp_epoch(
  hasher : &@bft.Hasher,
  session_id~ : String,
  referee_key~ : @bft.PublicKey,
  config~ : PvpEpochConfig,
  teams~ : Array[PvpTeam],
  players~ : Array[PvpPlayer],
  transcript~ : Array[PvpCommandEvidence],
  witnesses~ : Array[@witness_manifest.ReplayWitnessIdentity],
  max_faults~ : Int,
  attack_cooldown_ticks? : Int = 0,
  objective_rule? : PvpObjectiveRule? = None,
) -> PvpEpochCandidateResult {
  if session_id == "" ||
    session_id.length() > max_pvp_text_length ||
    referee_key.0 == "" ||
    referee_key.0.length() > max_pvp_text_length ||
    !pvp_config_valid(config) ||
    !pvp_extended_rules_valid(config, attack_cooldown_ticks, objective_rule) {
    return PvpCandidateRefused(InvalidEpochConfiguration)
  }
  let teams_by_id = match pvp_team_map(teams) {
    Some(value) => value
    None => return PvpCandidateRefused(InvalidTeamRoster)
  }
  let players_by_id = match pvp_player_map(config, teams_by_id, players) {
    Some(value) => value
    None => return PvpCandidateRefused(InvalidPlayerRoster)
  }
  if !pvp_witness_roster_valid(referee_key, witnesses, max_faults) {
    return PvpCandidateRefused(InvalidWitnessRoster)
  }
  if transcript.length() > max_pvp_commands {
    return PvpCandidateRefused(TooManyCommands)
  }
  let commands_by_slot : Map[String, PvpCommandEvidence] = Map([])
  let seen_pairs : Map[String, Bool] = Map([])
  let equivocators : Map[String, Bool] = Map([])
  for index, evidence in transcript {
    let player = match players_by_id.get(evidence.intent.player_id) {
      Some(value) => value
      None => return PvpCandidateRefused(InvalidCommandEvidence(index))
    }
    if !pvp_command_evidence_valid(
        session_id, referee_key, config, player, evidence,
      ) {
      return PvpCandidateRefused(InvalidCommandEvidence(index))
    }
    let input_digest = evidence.input.digest().0
    let receipt_digest = evidence.receipt.digest().0
    let pair_key = input_digest.length().to_string() +
      ":" +
      input_digest +
      receipt_digest.length().to_string() +
      ":" +
      receipt_digest
    if !seen_pairs.contains(pair_key) {
      seen_pairs[pair_key] = true
      let slot = pvp_slot_key(evidence.intent)
      match commands_by_slot.get(slot) {
        None => commands_by_slot[slot] = evidence
        Some(previous) =>
          if previous.input.digest() == evidence.input.digest() {
            if previous.receipt.digest() != evidence.receipt.digest() {
              return PvpCandidateRefused(
                ConflictingCommandReceipt(evidence.input.digest()),
              )
            }
          } else {
            equivocators[evidence.intent.player_id] = true
          }
      }
    }
  }
  let game_manifest = pvp_epoch_game_manifest(
    hasher,
    session_id,
    referee_key,
    config,
    teams,
    players,
    attack_cooldown_ticks~,
    objective_rule~,
  )
  if game_manifest.0 == "" {
    return PvpCandidateRefused(EmptyGameManifest)
  }
  let manifest = @witness_manifest.replay_witness_session_manifest(
    hasher,
    game_manifest_digest=game_manifest,
    referee_key~,
    witnesses~,
    max_faults~,
  )
  let sorted_players = players.copy()
  sorted_players.sort_by(fn(left, right) {
    right.player_id.compare(left.player_id)
  })
  let sorted_teams = teams.copy()
  sorted_teams.sort_by(fn(left, right) { right.team_id.compare(left.team_id) })
  let positions : Map[String, Int] = Map([])
  let hit_points : Map[String, Int] = Map([])
  let scores : Map[String, Int] = Map([])
  let last_attack_ticks : Map[String, Int] = Map([])
  let cooldown_violators : Map[String, Bool] = Map([])
  for player in sorted_players {
    positions[player.player_id] = player.initial_x
    hit_points[player.player_id] = player.initial_hp
  }
  for team in sorted_teams {
    scores[team.team_id] = team.initial_score
  }
  let mut accepted_commands = 0
  for tick in 0..<config.ticks_per_epoch {
    let accepted : Map[String, PvpCommandEvidence] = Map([])
    for player in sorted_players {
      let slot = tick.to_string() + ":" + player.player_id
      match commands_by_slot.get(slot) {
        None => ()
        Some(evidence) => {
          let intent = evidence.intent
          let target_valid = match intent.attack_target_id {
            None => true
            Some(target_id) =>
              match players_by_id.get(target_id) {
                Some(target) => target.team_id != player.team_id
                None => false
              }
          }
          let destination_in_arena = intent.move_to_x >= config.arena_min_x &&
            intent.move_to_x <= config.arena_max_x
          let current_x = positions
            .get(player.player_id)
            .unwrap_or(player.initial_x)
          let move_distance = if destination_in_arena {
            pvp_abs(intent.move_to_x - current_x)
          } else {
            config.max_move_distance + 1
          }
          if target_valid &&
            @audit.pvp_command_allowed(
              actor_hp=hit_points.get(player.player_id).unwrap_or(0),
              equivocated=equivocators.contains(player.player_id),
              tick~,
              ticks_per_epoch=config.ticks_per_epoch,
              receipt_tick=evidence.observed.received_tick,
              max_late_ticks=config.max_late_ticks,
              move_distance~,
              max_move_distance=config.max_move_distance,
              destination_in_arena~,
            ) {
            accepted[player.player_id] = evidence
            accepted_commands += 1
          }
        }
      }
    }
    // Movement is simultaneous: every accepted destination is derived from
    // the state at the beginning of this tick.
    for player in sorted_players {
      match accepted.get(player.player_id) {
        Some(evidence) =>
          positions[player.player_id] = evidence.intent.move_to_x
        None => ()
      }
    }
    let damage_by_target : Map[String, Int] = Map([])
    let enemy_damage : Map[String, Bool] = Map([])
    for player in sorted_players {
      match accepted.get(player.player_id) {
        Some(evidence) =>
          match evidence.intent.attack_target_id {
            None => ()
            Some(target_id) => {
              let previous_tick = last_attack_ticks
                .get(player.player_id)
                .unwrap_or(0)
              let cooldown_ready = @audit.pvp_attack_cooldown_allowed(
                previous_tick~,
                has_previous=last_attack_ticks.contains(player.player_id),
                tick~,
                cooldown_ticks=attack_cooldown_ticks,
              )
              if !cooldown_ready {
                cooldown_violators[player.player_id] = true
                continue
              }
              last_attack_ticks[player.player_id] = tick
              let actor_hp = hit_points.get(player.player_id).unwrap_or(0)
              let target_hp = hit_points.get(target_id).unwrap_or(0)
              let actor_x = positions.get(player.player_id).unwrap_or(0)
              let target_x = positions.get(target_id).unwrap_or(0)
              if actor_hp > 0 &&
                target_hp > 0 &&
                pvp_abs(actor_x - target_x) <= config.attack_range {
                let accumulated = damage_by_target.get(target_id).unwrap_or(0)
                let remaining = target_hp - accumulated
                if remaining > 0 {
                  damage_by_target[target_id] = if config.attack_damage >=
                    remaining {
                    target_hp
                  } else {
                    accumulated + config.attack_damage
                  }
                }
                enemy_damage[target_id] = true
              }
            }
          }
        None => ()
      }
    }
    // Damage and scores are also simultaneous. A double KO therefore grants
    // one point to each opposing team without choosing an arrival-order winner.
    for player in sorted_players {
      let before = hit_points.get(player.player_id).unwrap_or(0)
      let damage = damage_by_target.get(player.player_id).unwrap_or(0)
      let after = @audit.hp_after_encounter_damage(
        before,
        damage,
        was_hit=damage > 0,
      )
      hit_points[player.player_id] = after
      let delta = @audit.pvp_elimination_score_delta(
        target_hp_before=before,
        target_hp_after=after,
        enemy_damage=enemy_damage.contains(player.player_id),
        score_per_elimination=config.score_per_elimination,
      )
      if delta > 0 {
        let scoring_team = pvp_other_team(sorted_teams, player.team_id)
        scores[scoring_team] = scores.get(scoring_team).unwrap_or(0) + delta
      }
    }
    match objective_rule {
      None => ()
      Some(rule) => {
        let occupying_teams : Map[String, Bool] = Map([])
        for player in sorted_players {
          if hit_points.get(player.player_id).unwrap_or(0) > 0 &&
            pvp_abs(
              positions.get(player.player_id).unwrap_or(player.initial_x) -
              rule.center_x,
            ) <=
            rule.radius {
            occupying_teams[player.team_id] = true
          }
        }
        for team in sorted_teams {
          let delta = @audit.pvp_objective_score_delta(
            occupying_team_count=occupying_teams.length(),
            team_occupies=occupying_teams.contains(team.team_id),
            score_per_tick=rule.score_per_tick,
          )
          if delta > 0 {
            scores[team.team_id] = scores
              .get(team.team_id)
              .unwrap_or(team.initial_score) +
              delta
          }
        }
      }
    }
  }
  let player_states : Array[PvpPlayerState] = []
  let equivocator_ids : Array[String] = []
  let cooldown_violator_ids : Array[String] = []
  for player in sorted_players {
    player_states.push({
      player_id: player.player_id,
      team_id: player.team_id,
      position_x: positions.get(player.player_id).unwrap_or(player.initial_x),
      hp: hit_points.get(player.player_id).unwrap_or(0),
    })
    if equivocators.contains(player.player_id) {
      equivocator_ids.push(player.player_id)
    }
    if cooldown_violators.contains(player.player_id) {
      cooldown_violator_ids.push(player.player_id)
    }
  }
  let team_states : Array[PvpTeamState] = []
  for team in sorted_teams {
    team_states.push({
      team_id: team.team_id,
      score: scores.get(team.team_id).unwrap_or(team.initial_score),
    })
  }
  let event_root = pvp_epoch_transcript_root(hasher, transcript)
  let public_state_root = pvp_public_state_root(
    hasher, session_id, config, player_states, team_states, equivocator_ids, cooldown_violator_ids,
    accepted_commands, attack_cooldown_ticks, objective_rule,
  )
  let asset_delta_root = pvp_no_asset_delta_root(hasher, session_id, config)
  PvpCandidateReady(PvpEpochCandidate::{
    session: session_id,
    referee: referee_key,
    config,
    game_manifest,
    manifest,
    event_root,
    public_state_root,
    asset_delta_root,
    player_states,
    team_states,
    equivocators: equivocator_ids,
    cooldown_violators: cooldown_violator_ids,
    accepted_commands,
  })
}

///|
pub fn PvpEpochCandidate::game_manifest_digest(
  self : PvpEpochCandidate,
) -> @bft.Digest {
  self.game_manifest
}

///|
pub fn PvpEpochCandidate::manifest_digest(
  self : PvpEpochCandidate,
) -> @bft.Digest {
  self.manifest
}

///|
pub fn PvpEpochCandidate::event_root(self : PvpEpochCandidate) -> @bft.Digest {
  self.event_root
}

///|
pub fn PvpEpochCandidate::public_state_root(
  self : PvpEpochCandidate,
) -> @bft.Digest {
  self.public_state_root
}

///|
pub fn PvpEpochCandidate::asset_delta_root(
  self : PvpEpochCandidate,
) -> @bft.Digest {
  self.asset_delta_root
}

///|
pub fn finalize_pvp_epoch(
  candidate : PvpEpochCandidate,
  checkpoint : @checkpoint.VerifiedCheckpoint,
) -> PvpEpochFinalizeResult {
  let committed = checkpoint.checkpoint()
  if checkpoint.authority_key() != candidate.referee {
    return PvpFinalizeRefused(CheckpointRefereeMismatch)
  }
  if committed.session_id != candidate.session {
    return PvpFinalizeRefused(CheckpointSessionMismatch)
  }
  if committed.epoch != candidate.config.epoch {
    return PvpFinalizeRefused(CheckpointEpochMismatch)
  }
  if committed.previous_checkpoint != candidate.config.previous_checkpoint {
    return PvpFinalizeRefused(CheckpointParentMismatch)
  }
  if committed.manifest_digest != candidate.manifest {
    return PvpFinalizeRefused(CheckpointManifestMismatch)
  }
  if committed.event_root != candidate.event_root {
    return PvpFinalizeRefused(CheckpointEventRootMismatch)
  }
  if committed.public_state_root != candidate.public_state_root {
    return PvpFinalizeRefused(CheckpointPublicStateRootMismatch)
  }
  if committed.asset_delta_root != candidate.asset_delta_root {
    return PvpFinalizeRefused(CheckpointAssetDeltaRootMismatch)
  }
  if committed.hidden_state_commitment is Some(_) {
    return PvpFinalizeRefused(CheckpointHiddenStatePresent)
  }
  PvpEpochFinalized(PvpEpochResolution::{
    candidate,
    checkpoint_digest: checkpoint.digest(),
  })
}

///|
pub fn PvpEpochResolution::replay_match(
  self : PvpEpochResolution,
) -> CheckpointReplayMatch {
  CheckpointReplayMatch::{
    checkpoint_digest: self.checkpoint_digest,
    authority_key: self.candidate.referee,
  }
}

///|
pub fn PvpEpochResolution::player_states(
  self : PvpEpochResolution,
) -> Array[PvpPlayerState] {
  self.candidate.player_states.copy()
}

///|
pub fn PvpEpochResolution::team_states(
  self : PvpEpochResolution,
) -> Array[PvpTeamState] {
  self.candidate.team_states.copy()
}

///|
pub fn PvpEpochResolution::equivocator_ids(
  self : PvpEpochResolution,
) -> Array[String] {
  self.candidate.equivocators.copy()
}

///|
pub fn PvpEpochResolution::cooldown_violator_ids(
  self : PvpEpochResolution,
) -> Array[String] {
  self.candidate.cooldown_violators.copy()
}

///|
pub fn PvpEpochResolution::accepted_command_count(
  self : PvpEpochResolution,
) -> Int {
  self.candidate.accepted_commands
}

///|
pub fn PvpEpochResolution::game_manifest_digest(
  self : PvpEpochResolution,
) -> @bft.Digest {
  self.candidate.game_manifest
}
