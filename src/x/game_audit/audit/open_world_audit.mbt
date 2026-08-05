///|
/// Consequence class for one irregular open-world encounter.
pub(all) enum OpenWorldOutcomeClass {
  /// Rendering and short-lived world feedback only.
  Ephemeral
  /// Durable account or world progress with no direct transferability.
  Durable
  /// Transferable economic output that peer finality may authorize.
  Tradable
  /// Rare or especially valuable output that always receives central replay.
  HighValue
} derive(Eq, Debug)

///|
pub(all) enum OpenWorldAuditDecision {
  PeerAccepted
  CentralAccepted
  Provisional
  CentralReplayRequired
  Rejected
} derive(Eq, Debug)

///|
/// Route an encounter after delayed audit sampling is known.
///
/// This is the small proof model. Capability-bearing integration code derives
/// the Boolean inputs and never accepts client-supplied success flags.
pub fn route_open_world_audit(
  outcome_class : OpenWorldOutcomeClass,
  peer_certificate_matches~ : Bool,
  challenge_present~ : Bool,
  sample_selected~ : Bool,
  central_replay_present~ : Bool,
  central_replay_matches~ : Bool,
) -> OpenWorldAuditDecision where {
  proof_ensure: result => {
    open_world_audit_post(
      outcome_class, peer_certificate_matches, challenge_present, sample_selected,
      central_replay_present, central_replay_matches, result,
    )
  },
} {
  let result = if central_replay_present {
    if central_replay_matches {
      OpenWorldAuditDecision::CentralAccepted
    } else {
      OpenWorldAuditDecision::Rejected
    }
  } else {
    let economic = match outcome_class {
      Ephemeral => false
      Durable | Tradable | HighValue => true
    }
    let mandatory = match outcome_class {
      HighValue => true
      Ephemeral | Durable | Tradable => false
    }
    let central_required = challenge_present ||
      sample_selected ||
      mandatory ||
      (economic && !peer_certificate_matches)
    if central_required {
      OpenWorldAuditDecision::CentralReplayRequired
    } else if peer_certificate_matches {
      OpenWorldAuditDecision::PeerAccepted
    } else {
      OpenWorldAuditDecision::Provisional
    }
  }
  proof_assert open_world_audit_post(
    outcome_class, peer_certificate_matches, challenge_present, sample_selected,
    central_replay_present, central_replay_matches, result,
  )
  result
}
