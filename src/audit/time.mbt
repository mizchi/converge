///|
/// Admission decision for an application-assigned audit event time. The
/// watermark means all event times strictly below it have already been sealed.
pub(all) enum AuditEventTimeDecision {
  AuditEventTimeAccepted
  AuditEventBeforeOrigin
  AuditEventBehindWatermark
  InvalidAuditWatermark
} derive(Eq, Debug)

///|
/// Classify an authenticated audit time independently of storage and hashing.
/// An event exactly at the watermark remains admissible; only strictly earlier
/// events are late.
pub fn classify_audit_event_time(
  origin_ms~ : Int,
  watermark_ms~ : Int,
  event_time_ms~ : Int,
) -> AuditEventTimeDecision where {
  proof_ensure: decision => {
    audit_event_time_decision_post(
      origin_ms, watermark_ms, event_time_ms, decision,
    )
  },
} {
  let decision = if watermark_ms < origin_ms {
    InvalidAuditWatermark
  } else if event_time_ms < origin_ms {
    AuditEventBeforeOrigin
  } else if event_time_ms < watermark_ms {
    AuditEventBehindWatermark
  } else {
    AuditEventTimeAccepted
  }
  proof_assert audit_event_time_decision_post(
    origin_ms, watermark_ms, event_time_ms, decision,
  )
  decision
}
