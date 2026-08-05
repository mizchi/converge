const MAX_QUEUE_MESSAGE_BYTES = 128 * 1_024;

export type AuditQueueBodyDecode =
  | { ok: true; value: unknown }
  | { ok: false; reason: "invalid_json" | "message_too_large" };

export function decodeAuditQueueBody(value: unknown): AuditQueueBodyDecode {
  if (typeof value !== "string") return { ok: true, value };
  if (new TextEncoder().encode(value).byteLength >= MAX_QUEUE_MESSAGE_BYTES) {
    return { ok: false, reason: "message_too_large" };
  }
  try {
    return { ok: true, value: JSON.parse(value) as unknown };
  } catch {
    return { ok: false, reason: "invalid_json" };
  }
}
