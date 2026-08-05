export interface ExpectedCheckpointDelivery {
  destinationId: string;
  epoch: number;
  checkpointDigest: string;
}

export type CheckpointDeliveryObservation =
  | { state: "pending" | "in_flight" }
  | {
    state: "acknowledged";
    decision: "accepted" | "duplicate";
  };

export function observeSingleCheckpointDelivery(
  value: unknown,
  expected: ExpectedCheckpointDelivery,
): CheckpointDeliveryObservation {
  const response = objectValue(value, "checkpoint state response");
  const outbox = objectValue(response.outbox, "checkpoint state outbox");
  if (!Array.isArray(outbox.entries) || outbox.entries.length !== 1) {
    throw new Error("checkpoint state must contain one outbox entry");
  }
  const entry = objectValue(outbox.entries[0], "checkpoint outbox entry");
  if (
    entry.destination_id !== expected.destinationId ||
    entry.epoch !== expected.epoch ||
    entry.checkpoint_digest !== expected.checkpointDigest
  ) {
    throw new Error("checkpoint state omitted the expected checkpoint delivery");
  }
  if (
    entry.state !== "pending" &&
    entry.state !== "in_flight" &&
    entry.state !== "acknowledged"
  ) {
    throw new Error("checkpoint delivery has an invalid state");
  }
  const decisions = objectValue(
    outbox.ack_decisions,
    "checkpoint state ACK decisions",
  );
  const accepted = countValue(decisions.accepted, "accepted ACK count");
  const duplicate = countValue(decisions.duplicate, "duplicate ACK count");
  if (entry.state !== "acknowledged") {
    if (accepted !== 0 || duplicate !== 0) {
      throw new Error("pending checkpoint delivery has an ACK decision");
    }
    return { state: entry.state };
  }
  if (accepted + duplicate !== 1) {
    throw new Error("acknowledged checkpoint delivery has an ambiguous ACK decision");
  }
  return {
    state: "acknowledged",
    decision: accepted === 1 ? "accepted" : "duplicate",
  };
}

function objectValue(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function countValue(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new Error(`${label} must be a non-negative integer`);
  }
  return value as number;
}
