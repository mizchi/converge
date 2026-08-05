import { describe, expect, it } from "vitest";

import {
  cleanWitnessAuthorityPathMs,
  cleanWitnessSealPathMs,
  summarizeLatency,
  witnessSettlementBudget,
} from "../src/benchmark-metrics";

describe("benchmark metrics", () => {
  it("excludes the deliberate hostile phase from the clean seal path", () => {
    expect(cleanWitnessSealPathMs({
      collectionStartMs: 529.645,
      quorumWallMs: 1_093.013,
      sealMs: 476.542,
    })).toBe(2_099.2);
  });

  it("maps a measured clean path onto a checkpoint cadence", () => {
    expect(witnessSettlementBudget({
      checkpointIntervalMs: 2_000,
      cleanPathMeanMs: 2_099.2,
      cleanPathTailMs: 8_215.307,
    })).toEqual({
      meanEventToSealMs: 3_099.2,
      conservativeEventToSealMs: 10_215.307,
    });
  });

  it("extends the clean path through the observed authority ACK", () => {
    expect(cleanWitnessAuthorityPathMs({
      collectionStartMs: 529.645,
      quorumWallMs: 1_093.013,
      authorityAckMs: 1_500,
    })).toBe(3_122.658);
  });

  it("rejects invalid timing inputs", () => {
    expect(() => cleanWitnessSealPathMs({
      collectionStartMs: 1,
      quorumWallMs: -1,
      sealMs: 1,
    })).toThrow("quorumWallMs");
    expect(() => witnessSettlementBudget({
      checkpointIntervalMs: 0,
      cleanPathMeanMs: 1,
      cleanPathTailMs: 1,
    })).toThrow("checkpointIntervalMs");
  });

  it("uses nearest-rank percentiles without treating p95 as max at n=20", () => {
    expect(summarizeLatency(Array.from({ length: 20 }, (_, index) => index + 1)))
      .toEqual({
        count: 20,
        mean_ms: 10.5,
        p50_ms: 10,
        p95_ms: 19,
        p99_ms: 20,
        max_ms: 20,
      });
  });
});
