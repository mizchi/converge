import { describe, expect, it } from "vitest";

import { decodeAuditQueueBody } from "../src/queue-wire";

describe("audit Queue wire", () => {
  it("keeps native Queue objects unchanged", () => {
    const value = { version: 1, reason: "dispute" };
    expect(decodeAuditQueueBody(value)).toEqual({ ok: true, value });
  });

  it("decodes a bounded JSON text checkpoint message", () => {
    expect(decodeAuditQueueBody(JSON.stringify({
      kind: "checkpoint-delivery-v1",
      version: 1,
      epoch: 0,
    }))).toEqual({
      ok: true,
      value: {
        kind: "checkpoint-delivery-v1",
        version: 1,
        epoch: 0,
      },
    });
  });

  it("fails closed for invalid or oversized JSON text", () => {
    expect(decodeAuditQueueBody("{"))
      .toEqual({ ok: false, reason: "invalid_json" });
    expect(decodeAuditQueueBody(`"${"x".repeat(128 * 1_024)}"`))
      .toEqual({ ok: false, reason: "message_too_large" });
  });
});
