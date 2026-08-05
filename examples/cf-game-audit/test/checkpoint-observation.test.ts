import { describe, expect, it } from "vitest";

import {
  observeSingleCheckpointDelivery,
} from "../src/checkpoint-observation";

const expected = {
  destinationId: "authority-1",
  epoch: 0,
  checkpointDigest: "checkpoint-0",
};

function checkpointState(
  state: "pending" | "in_flight" | "acknowledged",
  accepted = 0,
  duplicate = 0,
): unknown {
  return {
    ok: true,
    outbox: {
      entries: [{
        destination_id: expected.destinationId,
        epoch: expected.epoch,
        checkpoint_digest: expected.checkpointDigest,
        state,
      }],
      ack_decisions: { accepted, duplicate },
    },
  };
}

describe("checkpoint delivery observation", () => {
  it("keeps an exact in-flight delivery pending", () => {
    expect(observeSingleCheckpointDelivery(
      checkpointState("in_flight"),
      expected,
    )).toEqual({ state: "in_flight" });
  });

  it("returns the authority ACK decision for the exact delivery", () => {
    expect(observeSingleCheckpointDelivery(
      checkpointState("acknowledged", 1),
      expected,
    )).toEqual({ state: "acknowledged", decision: "accepted" });
    expect(observeSingleCheckpointDelivery(
      checkpointState("acknowledged", 0, 1),
      expected,
    )).toEqual({ state: "acknowledged", decision: "duplicate" });
  });

  it("does not accept an aggregate ACK for a different checkpoint", () => {
    const value = checkpointState("acknowledged", 1) as {
      outbox: { entries: Array<Record<string, unknown>> };
    };
    value.outbox.entries[0].checkpoint_digest = "checkpoint-other";
    expect(() => observeSingleCheckpointDelivery(value, expected))
      .toThrow("expected checkpoint delivery");
  });

  it("rejects ambiguous or malformed acknowledged state", () => {
    expect(() => observeSingleCheckpointDelivery(
      checkpointState("acknowledged", 1, 1),
      expected,
    )).toThrow("ACK decision");
    expect(() => observeSingleCheckpointDelivery({ ok: true }, expected))
      .toThrow("outbox");
  });
});
