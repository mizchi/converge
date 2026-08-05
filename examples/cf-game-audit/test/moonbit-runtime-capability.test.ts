import { describe, expect, it } from "vitest";
import {
  audit_benchmark_make_checkpoint_delivery_authentication,
} from "../../../target/js/release/build/mizchi/converge/x/game_audit/worker/worker.js";
import {
  acknowledgeCheckpointOutboxSync,
  loadCheckpointRuntime,
  prepareCheckpointSealSync,
  verifyCheckpointDeliveryAuthenticationSync,
  type CheckpointDeliveryAuthentication,
  type LoadedCheckpointRuntime,
} from "../src/moonbit";

const PRODUCER_SEED =
  "000102030405060708090a0b0c0d0e0f" +
  "101112131415161718191a1b1c1d1e1f";
const WITNESS_SEEDS = [
  "404142434445464748494a4b4c4d4e4f" +
  "505152535455565758595a5b5c5d5e5f",
  "606162636465666768696a6b6c6d6e6f" +
  "707172737475767778797a7b7c7d7e7f",
  "808182838485868788898a8b8c8d8e8f" +
  "909192939495969798999a9b9c9d9e9f",
];
const WITNESS_IDS = ["witness-0", "witness-1", "witness-2"];

interface Fixture {
  ok: true;
  policy: {
    producer_id: string;
    producer_key: string;
    witnesses: Array<{ witness_id: string; witness_key: string }>;
    required_approvals: number;
  };
  authentication: CheckpointDeliveryAuthentication;
}

describe("loaded MoonBit checkpoint runtime capability", () => {
  it("admits a valid authentication only with the loaded capability", async () => {
    const fixture = JSON.parse(
      audit_benchmark_make_checkpoint_delivery_authentication(
        PRODUCER_SEED,
        "producer",
        WITNESS_SEEDS,
        WITNESS_IDS,
        3,
        3,
        1,
        "checkpoint-v1",
        "manifest-1",
        "scope-1",
        "unit-1",
        "authority-1",
        0,
        "genesis",
        "checkpoint-0",
        "canonical-envelope-0",
      ),
    ) as Fixture;
    const runtime = await loadCheckpointRuntime();
    expect(verifyCheckpointDeliveryAuthenticationSync(runtime, {
      boundary: {
        protocol_version: 1,
        purpose: "checkpoint-v1",
        manifest_digest: "manifest-1",
        scope_id: "scope-1",
        unit_id: "unit-1",
      },
      destinationId: "authority-1",
      epoch: 0,
      previousCheckpoint: "genesis",
      checkpointDigest: "checkpoint-0",
      canonicalEnvelope: "canonical-envelope-0",
      policy: fixture.policy,
      authentication: fixture.authentication,
    })).toEqual({ ok: true, producer_id: "producer", approval_count: 3 });
  });

  it("rejects a forged capability before every synchronous transaction gate", () => {
    const forged = {} as LoadedCheckpointRuntime;
    expect(() => verifyCheckpointDeliveryAuthenticationSync(
      forged,
      {} as Parameters<typeof verifyCheckpointDeliveryAuthenticationSync>[1],
    )).toThrow("MoonBit checkpoint runtime must be loaded before authentication");
    expect(() => prepareCheckpointSealSync(
      forged,
      {} as Parameters<typeof prepareCheckpointSealSync>[1],
    )).toThrow("MoonBit checkpoint runtime must be loaded before transaction");
    expect(() => acknowledgeCheckpointOutboxSync(
      forged,
      {} as Parameters<typeof acknowledgeCheckpointOutboxSync>[1],
    )).toThrow("MoonBit checkpoint runtime must be loaded before transaction");
  });
});
