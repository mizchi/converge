///|
/// Pure acceptance boundary for one dodge in a telegraphed attack.
pub fn telegraph_dodge_allowed(
  telegraph_valid~ : Bool,
  player_evidence_valid~ : Bool,
  causally_bound~ : Bool,
  reaction_window~ : Bool,
  receipt_bound~ : Bool,
  movement_legal~ : Bool,
) -> Bool where {
  proof_ensure: result => {
    telegraph_dodge_allowed_post(
      telegraph_valid, player_evidence_valid, causally_bound, reaction_window, receipt_bound,
      movement_legal, result,
    )
  },
} {
  let result = telegraph_valid &&
    player_evidence_valid &&
    causally_bound &&
    reaction_window &&
    receipt_bound &&
    movement_legal
  proof_assert telegraph_dodge_allowed_post(
    telegraph_valid, player_evidence_valid, causally_bound, reaction_window, receipt_bound,
    movement_legal, result,
  )
  result
}

///|
/// Verified integer-tick reaction window used by the executable replay kernel.
pub fn dodge_reaction_window_allowed(
  visible_tick : Int,
  resolve_tick : Int,
  min_reaction_ticks : Int,
  client_tick : Int,
) -> Bool where {
  proof_ensure: result => {
    dodge_reaction_window_post(
      visible_tick, resolve_tick, min_reaction_ticks, client_tick, result,
    )
  },
} {
  let result = min_reaction_ticks >= 0 &&
    client_tick >= visible_tick + min_reaction_ticks &&
    client_tick < resolve_tick
  proof_assert dodge_reaction_window_post(
    visible_tick, resolve_tick, min_reaction_ticks, client_tick, result,
  )
  result
}

///|
/// Verified bound between a player-signed client tick and an authority-signed
/// receipt tick. The player cannot claim a future tick or backdate unboundedly.
pub fn dodge_receipt_bound_allowed(
  client_tick : Int,
  received_tick : Int,
  max_backdate_ticks : Int,
) -> Bool where {
  proof_ensure: result => {
    dodge_receipt_bound_post(
      client_tick, received_tick, max_backdate_ticks, result,
    )
  },
} {
  let result = max_backdate_ticks >= 0 &&
    received_tick >= client_tick &&
    received_tick - client_tick <= max_backdate_ticks
  proof_assert dodge_receipt_bound_post(
    client_tick, received_tick, max_backdate_ticks, result,
  )
  result
}
