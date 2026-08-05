import {
  approveCheckpointWitnessCollection,
  type AuditMode,
} from "../src/witness-client";

const [modeValue, unit, collectionId, witnessId] = process.argv.slice(2);
const witnessSeedHex = process.env.AUDIT_WITNESS_SEED_HEX;
const baseUrl = process.env.AUDIT_BASE_URL ?? "http://127.0.0.1:8787";

if (!isAuditMode(modeValue) || !unit || !collectionId || !witnessId) {
  throw new Error(
    "usage: pnpm witness -- <pve|pvp|open> <unit> <collection-id> <witness-id>",
  );
}
if (!witnessSeedHex) {
  throw new Error("AUDIT_WITNESS_SEED_HEX is required");
}

const started = performance.now();
const result = await approveCheckpointWitnessCollection({
  baseUrl,
  mode: modeValue,
  unit,
  collectionId,
  witnessId,
  witnessSeedHex,
});

console.log(JSON.stringify({
  ok: result.httpStatus < 400,
  collection_id: collectionId,
  witness_id: result.witnessId,
  witness_key: result.witnessKey,
  approval_bytes: result.approvalBytes,
  http_status: result.httpStatus,
  retry_after_seconds: result.retryAfterSeconds,
  elapsed_ms: Math.round((performance.now() - started) * 1_000) / 1_000,
  response: result.response,
}, null, 2));

if (result.httpStatus >= 400) process.exitCode = 1;

function isAuditMode(value: string | undefined): value is AuditMode {
  return value === "pve" || value === "pvp" || value === "open";
}
