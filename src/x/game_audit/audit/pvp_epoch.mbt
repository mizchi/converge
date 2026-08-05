///|
/// Public command gate used by the deterministic PvP replay kernel.
pub fn pvp_command_allowed(
  actor_hp~ : Int,
  equivocated~ : Bool,
  tick~ : Int,
  ticks_per_epoch~ : Int,
  receipt_tick~ : Int,
  max_late_ticks~ : Int,
  move_distance~ : Int,
  max_move_distance~ : Int,
  destination_in_arena~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    pvp_command_allowed_post(
      actor_hp, equivocated, tick, ticks_per_epoch, receipt_tick, max_late_ticks,
      move_distance, max_move_distance, destination_in_arena, result,
    )
  },
} {
  let result = actor_hp > 0 &&
    !equivocated &&
    tick >= 0 &&
    tick < ticks_per_epoch &&
    max_late_ticks >= 0 &&
    receipt_tick >= tick &&
    receipt_tick <= tick + max_late_ticks &&
    move_distance >= 0 &&
    max_move_distance >= 0 &&
    move_distance <= max_move_distance &&
    destination_in_arena
  proof_assert pvp_command_allowed_post(
    actor_hp, equivocated, tick, ticks_per_epoch, receipt_tick, max_late_ticks, move_distance,
    max_move_distance, destination_in_arena, result,
  )
  result
}

///|
/// Award a team score exactly once for an enemy-caused alive-to-defeated
/// transition. Invalid score configuration fails closed.
pub fn pvp_elimination_score_delta(
  target_hp_before~ : Int,
  target_hp_after~ : Int,
  enemy_damage~ : Bool,
  score_per_elimination~ : Int,
) -> Int where {
  proof_ensure: result => {
    pvp_elimination_score_delta_post(
      target_hp_before, target_hp_after, enemy_damage, score_per_elimination, result,
    )
  },
} {
  let result = if target_hp_before > 0 &&
    target_hp_after == 0 &&
    enemy_damage &&
    score_per_elimination > 0 {
    score_per_elimination
  } else {
    0
  }
  proof_assert pvp_elimination_score_delta_post(
    target_hp_before, target_hp_after, enemy_damage, score_per_elimination, result,
  )
  result
}

///|
/// Public cooldown gate. A first attack is allowed, while later attacks must
/// be monotonically timed and separated by the manifest-bound cooldown.
pub fn pvp_attack_cooldown_allowed(
  previous_tick~ : Int,
  has_previous~ : Bool,
  tick~ : Int,
  cooldown_ticks~ : Int,
) -> Bool where {
  proof_ensure: result => {
    pvp_attack_cooldown_allowed_post(
      previous_tick, has_previous, tick, cooldown_ticks, result,
    )
  },
} {
  let result = tick >= 0 &&
    cooldown_ticks >= 0 &&
    (
      !has_previous ||
      (
        previous_tick >= 0 &&
        tick >= previous_tick &&
        tick - previous_tick >= cooldown_ticks
      )
    )
  proof_assert pvp_attack_cooldown_allowed_post(
    previous_tick, has_previous, tick, cooldown_ticks, result,
  )
  result
}

///|
/// Score a public objective only for exactly one occupying team. The caller
/// evaluates this once per tick after simultaneous movement and damage.
pub fn pvp_objective_score_delta(
  occupying_team_count~ : Int,
  team_occupies~ : Bool,
  score_per_tick~ : Int,
) -> Int where {
  proof_ensure: result => {
    pvp_objective_score_delta_post(
      occupying_team_count, team_occupies, score_per_tick, result,
    )
  },
} {
  let result = if occupying_team_count == 1 &&
    team_occupies &&
    score_per_tick > 0 {
    score_per_tick
  } else {
    0
  }
  proof_assert pvp_objective_score_delta_post(
    occupying_team_count, team_occupies, score_per_tick, result,
  )
  result
}
