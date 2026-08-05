///|
test "encounter damage is clamped and death is absorbing" {
  assert_eq(hp_after_encounter_damage(10, 4, was_hit=true), 6)
  assert_eq(hp_after_encounter_damage(3, 4, was_hit=true), 0)
  assert_eq(hp_after_encounter_damage(0, 4, was_hit=true), 0)
  assert_eq(hp_after_encounter_damage(-1, 4, was_hit=true), 0)
  assert_eq(hp_after_encounter_damage(10, 4, was_hit=false), 10)
  assert_eq(hp_after_encounter_damage(10, -1, was_hit=true), 10)
}

///|
test "encounter clear and loot fail closed" {
  assert_true(encounter_clear_allowed(schedule_complete=true, survivor_count=1))
  assert_false(
    encounter_clear_allowed(schedule_complete=false, survivor_count=1),
  )
  assert_false(
    encounter_clear_allowed(schedule_complete=true, survivor_count=0),
  )
  assert_true(encounter_loot_allowed(encounter_cleared=true, player_hp=1))
  assert_false(encounter_loot_allowed(encounter_cleared=false, player_hp=1))
  assert_false(encounter_loot_allowed(encounter_cleared=true, player_hp=0))
}
