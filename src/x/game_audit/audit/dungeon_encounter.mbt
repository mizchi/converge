///|
/// Apply one encounter hit while normalizing invalid/non-positive HP to zero.
/// Negative damage is rejected by treating it as no damage.
pub fn hp_after_encounter_damage(
  hp : Int,
  damage : Int,
  was_hit~ : Bool,
) -> Int where {
  proof_ensure: result => {
    hp_after_encounter_damage_post(hp, damage, was_hit, result)
  },
} {
  let result = if hp <= 0 {
    0
  } else if !was_hit || damage <= 0 {
    hp
  } else if damage >= hp {
    0
  } else {
    hp - damage
  }
  proof_assert hp_after_encounter_damage_post(hp, damage, was_hit, result)
  result
}

///|
/// A completed schedule clears only while at least one rostered player lives.
pub fn encounter_clear_allowed(
  schedule_complete~ : Bool,
  survivor_count~ : Int,
) -> Bool where {
  proof_ensure: result => {
    encounter_clear_allowed_post(schedule_complete, survivor_count, result)
  },
} {
  let result = schedule_complete && survivor_count > 0
  proof_assert encounter_clear_allowed_post(
    schedule_complete, survivor_count, result,
  )
  result
}

///|
/// Loot entitlement is fail-closed on both encounter clear and player life.
pub fn encounter_loot_allowed(
  encounter_cleared~ : Bool,
  player_hp~ : Int,
) -> Bool where {
  proof_ensure: result => {
    encounter_loot_allowed_post(encounter_cleared, player_hp, result)
  },
} {
  let result = encounter_cleared && player_hp > 0
  proof_assert encounter_loot_allowed_post(encounter_cleared, player_hp, result)
  result
}

///|
/// The raid damage phase clears only after a valid defense phase and exact
/// zero boss HP. Negative/corrupt HP never grants completion.
pub fn raid_boss_clear_allowed(
  defense_phase_cleared~ : Bool,
  boss_hp~ : Int,
) -> Bool where {
  proof_ensure: result => {
    raid_boss_clear_allowed_post(defense_phase_cleared, boss_hp, result)
  },
} {
  let result = defense_phase_cleared && boss_hp == 0
  proof_assert raid_boss_clear_allowed_post(
    defense_phase_cleared, boss_hp, result,
  )
  result
}
