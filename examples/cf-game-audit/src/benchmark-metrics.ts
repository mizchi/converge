export interface CleanWitnessSealPath {
  collectionStartMs: number;
  quorumWallMs: number;
  sealMs: number;
}

export interface CleanWitnessAuthorityPath {
  collectionStartMs: number;
  quorumWallMs: number;
  authorityAckMs: number;
}

export interface WitnessSettlementBudgetInput {
  checkpointIntervalMs: number;
  cleanPathMeanMs: number;
  cleanPathTailMs: number;
}

export interface WitnessSettlementBudget {
  meanEventToSealMs: number;
  conservativeEventToSealMs: number;
}

export interface LatencySummary {
  count: number;
  mean_ms: number;
  p50_ms: number;
  p95_ms: number;
  p99_ms: number;
  max_ms: number;
}

export function summarizeLatency(values: number[]): LatencySummary {
  if (values.length === 0) {
    return { count: 0, mean_ms: 0, p50_ms: 0, p95_ms: 0, p99_ms: 0, max_ms: 0 };
  }
  const sorted = values.map((value) => nonNegative("latency", value))
    .sort((left, right) => left - right);
  const percentile = (fraction: number) => {
    const rank = Math.ceil(sorted.length * fraction);
    return sorted[Math.max(0, Math.min(sorted.length - 1, rank - 1))];
  };
  return {
    count: sorted.length,
    mean_ms: roundMs(
      sorted.reduce((sum, value) => sum + value, 0) / sorted.length,
    ),
    p50_ms: roundMs(percentile(0.5)),
    p95_ms: roundMs(percentile(0.95)),
    p99_ms: roundMs(percentile(0.99)),
    max_ms: roundMs(sorted.at(-1) ?? 0),
  };
}

export function cleanWitnessSealPathMs(path: CleanWitnessSealPath): number {
  const collectionStartMs = nonNegative("collectionStartMs", path.collectionStartMs);
  const quorumWallMs = nonNegative("quorumWallMs", path.quorumWallMs);
  const sealMs = nonNegative("sealMs", path.sealMs);
  return roundMs(collectionStartMs + quorumWallMs + sealMs);
}

export function cleanWitnessAuthorityPathMs(
  path: CleanWitnessAuthorityPath,
): number {
  const collectionStartMs = nonNegative("collectionStartMs", path.collectionStartMs);
  const quorumWallMs = nonNegative("quorumWallMs", path.quorumWallMs);
  const authorityAckMs = nonNegative("authorityAckMs", path.authorityAckMs);
  return roundMs(collectionStartMs + quorumWallMs + authorityAckMs);
}

export function witnessSettlementBudget(
  input: WitnessSettlementBudgetInput,
): WitnessSettlementBudget {
  const checkpointIntervalMs = positive(
    "checkpointIntervalMs",
    input.checkpointIntervalMs,
  );
  const cleanPathMeanMs = nonNegative(
    "cleanPathMeanMs",
    input.cleanPathMeanMs,
  );
  const cleanPathTailMs = nonNegative(
    "cleanPathTailMs",
    input.cleanPathTailMs,
  );
  if (cleanPathTailMs < cleanPathMeanMs) {
    throw new Error("cleanPathTailMs must be at least cleanPathMeanMs");
  }
  return {
    meanEventToSealMs: roundMs(checkpointIntervalMs / 2 + cleanPathMeanMs),
    conservativeEventToSealMs: roundMs(
      checkpointIntervalMs + cleanPathTailMs,
    ),
  };
}

function nonNegative(name: string, value: number): number {
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${name} must be a finite non-negative number`);
  }
  return value;
}

function positive(name: string, value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a finite positive number`);
  }
  return value;
}

function roundMs(value: number): number {
  return Math.round(value * 1_000) / 1_000;
}
