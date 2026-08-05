import {
  signExperimentalCheckpointDeliveryApproval,
  type CheckpointDeliveryApproval,
  type CheckpointDeliveryAuthentication,
  type CheckpointDeliveryAuthenticationPolicy,
  type CheckpointRuntimeBoundary,
} from "./moonbit";
import type { AuditMode } from "./contracts";

export type { AuditMode } from "./contracts";

export interface PublicCheckpointWitnessCollection {
  ok: true;
  collection_id: string;
  statement: {
    boundary: CheckpointRuntimeBoundary;
    destination_id: string;
    epoch: number;
    previous_checkpoint: string;
    checkpoint_digest: string;
    canonical_envelope: string;
  };
  producer_authentication: CheckpointDeliveryAuthentication;
  authentication_policy: CheckpointDeliveryAuthenticationPolicy;
  status: "collecting" | "ready" | "expired";
  approval_count: number;
  required_approvals: number;
  deadline_at: number;
  created_at: number;
  ready_at: number | null;
}

export interface ApproveCheckpointWitnessCollectionInput {
  baseUrl: string;
  mode: AuditMode;
  unit: string;
  collectionId: string;
  witnessId: string;
  witnessSeedHex: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
}

export interface CheckpointWitnessSubmission {
  httpStatus: number;
  retryAfterSeconds?: number;
  witnessId: string;
  witnessKey: string;
  approvalBytes: number;
  response: unknown;
}

export async function fetchCheckpointWitnessCollection(input: {
  baseUrl: string;
  mode: AuditMode;
  unit: string;
  collectionId: string;
  fetchImpl?: typeof fetch;
}): Promise<PublicCheckpointWitnessCollection> {
  const fetchImpl = input.fetchImpl ?? fetch;
  const url = checkpointWitnessEndpoint(
    input.baseUrl,
    input.mode,
    input.unit,
    "checkpoint-witness-collections",
  );
  url.searchParams.set("collection_id", input.collectionId);
  const response = await fetchImpl(url);
  const value = await responseJson(response);
  if (!response.ok) {
    throw new Error(`checkpoint_witness_collection_fetch_failed:${response.status}`);
  }
  if (!isPublicCheckpointWitnessCollection(value) ||
    value.collection_id !== input.collectionId) {
    throw new Error("invalid_checkpoint_witness_collection_response");
  }
  return value;
}

export async function signCheckpointWitnessApproval(input: {
  collection: PublicCheckpointWitnessCollection;
  witnessId: string;
  witnessSeedHex: string;
  now?: () => number;
}): Promise<CheckpointDeliveryApproval> {
  const now = (input.now ?? Date.now)();
  if (input.collection.status !== "collecting") {
    throw new Error(`checkpoint_witness_collection_${input.collection.status}`);
  }
  if (now >= input.collection.deadline_at) {
    throw new Error("checkpoint_witness_collection_expired");
  }
  if (input.collection.producer_authentication.approvals.length !== 0) {
    throw new Error("invalid_checkpoint_witness_producer_authentication");
  }
  const rosterEntry = input.collection.authentication_policy.witnesses.find(
    (witness) => witness.witness_id === input.witnessId,
  );
  if (!rosterEntry) throw new Error("unknown_checkpoint_witness");
  const signed = await signExperimentalCheckpointDeliveryApproval({
    witnessSeedHex: input.witnessSeedHex,
    witnessId: input.witnessId,
    statementDigest: input.collection.producer_authentication.statement_digest,
  });
  if (!signed.ok) {
    throw new Error(`checkpoint_witness_signing_failed:${signed.error}`);
  }
  if (signed.approval.witness_key !== rosterEntry.witness_key) {
    throw new Error("witness_seed_does_not_match_roster");
  }
  return signed.approval;
}

export async function submitCheckpointWitnessApproval(input: {
  baseUrl: string;
  mode: AuditMode;
  unit: string;
  collectionId: string;
  approval: CheckpointDeliveryApproval;
  fetchImpl?: typeof fetch;
}): Promise<CheckpointWitnessSubmission> {
  const fetchImpl = input.fetchImpl ?? fetch;
  const requestBody = JSON.stringify({
    collection_id: input.collectionId,
    approval: input.approval,
  });
  const response = await fetchImpl(
    checkpointWitnessEndpoint(
      input.baseUrl,
      input.mode,
      input.unit,
      "checkpoint-witness-approvals",
    ),
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: requestBody,
    },
  );
  const retryAfter = response.headers.get("retry-after");
  const retryAfterSeconds = retryAfter === null ? undefined : Number(retryAfter);
  const hasValidRetryAfter = retryAfterSeconds !== undefined &&
    Number.isFinite(retryAfterSeconds) && retryAfterSeconds >= 0;
  return {
    httpStatus: response.status,
    ...(hasValidRetryAfter
      ? { retryAfterSeconds }
      : {}),
    witnessId: input.approval.witness_id,
    witnessKey: input.approval.witness_key,
    approvalBytes: new TextEncoder().encode(requestBody).byteLength,
    response: await responseJson(response),
  };
}

export async function approveCheckpointWitnessCollection(
  input: ApproveCheckpointWitnessCollectionInput,
): Promise<CheckpointWitnessSubmission> {
  const collection = await fetchCheckpointWitnessCollection(input);
  const approval = await signCheckpointWitnessApproval({
    collection,
    witnessId: input.witnessId,
    witnessSeedHex: input.witnessSeedHex,
    now: input.now,
  });
  return submitCheckpointWitnessApproval({ ...input, approval });
}

function checkpointWitnessEndpoint(
  baseUrl: string,
  mode: AuditMode,
  unit: string,
  action: string,
): URL {
  const url = new URL(baseUrl);
  url.pathname = `/v1/${mode}/${encodeURIComponent(unit)}/${action}`;
  url.search = "";
  url.hash = "";
  return url;
}

async function responseJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text === "") return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return { error: "invalid_json_response", body: text.slice(0, 1_024) };
  }
}

function isPublicCheckpointWitnessCollection(
  value: unknown,
): value is PublicCheckpointWitnessCollection {
  if (!isRecord(value) || value.ok !== true ||
    !isNonEmptyString(value.collection_id) || !isRecord(value.statement) ||
    !isBoundary(value.statement.boundary) ||
    !isNonEmptyString(value.statement.destination_id) ||
    !isNonNegativeInteger(value.statement.epoch) ||
    !isNonEmptyString(value.statement.previous_checkpoint) ||
    !isNonEmptyString(value.statement.checkpoint_digest) ||
    !isNonEmptyString(value.statement.canonical_envelope) ||
    !isAuthentication(value.producer_authentication) ||
    !isPolicy(value.authentication_policy) ||
    (value.status !== "collecting" && value.status !== "ready" &&
      value.status !== "expired") ||
    !isNonNegativeInteger(value.approval_count) ||
    !isNonNegativeInteger(value.required_approvals) ||
    !isNonNegativeInteger(value.deadline_at) ||
    !isNonNegativeInteger(value.created_at) ||
    !(value.ready_at === null || isNonNegativeInteger(value.ready_at))) {
    return false;
  }
  return value.required_approvals ===
    value.authentication_policy.required_approvals;
}

function isBoundary(value: unknown): value is CheckpointRuntimeBoundary {
  return isRecord(value) && Number.isSafeInteger(value.protocol_version) &&
    (value.protocol_version as number) > 0 && isNonEmptyString(value.purpose) &&
    isNonEmptyString(value.manifest_digest) && isNonEmptyString(value.scope_id) &&
    isNonEmptyString(value.unit_id);
}

function isPolicy(
  value: unknown,
): value is CheckpointDeliveryAuthenticationPolicy {
  return isRecord(value) && isNonEmptyString(value.producer_id) &&
    isNonEmptyString(value.producer_key) &&
    Array.isArray(value.witnesses) && value.witnesses.length > 0 &&
    value.witnesses.every((witness) =>
      isRecord(witness) && isNonEmptyString(witness.witness_id) &&
      isNonEmptyString(witness.witness_key)
    ) && Number.isSafeInteger(value.required_approvals) &&
    (value.required_approvals as number) > 0 &&
    (value.required_approvals as number) <= value.witnesses.length;
}

function isAuthentication(
  value: unknown,
): value is CheckpointDeliveryAuthentication {
  return isRecord(value) && value.version === 1 &&
    isNonEmptyString(value.producer_id) && isNonEmptyString(value.producer_key) &&
    isNonEmptyString(value.statement_digest) &&
    isNonEmptyString(value.producer_signature) && Array.isArray(value.approvals) &&
    value.approvals.every(isApproval);
}

function isApproval(value: unknown): value is CheckpointDeliveryApproval {
  return isRecord(value) && isNonEmptyString(value.statement_digest) &&
    isNonEmptyString(value.witness_id) && isNonEmptyString(value.witness_key) &&
    isNonEmptyString(value.digest) && isNonEmptyString(value.signature);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function isNonNegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}
