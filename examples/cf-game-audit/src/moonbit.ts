type AuditModule = typeof import("../../../target/js/release/build/mizchi/converge/x/game_audit/worker/worker.js");

let auditModule: AuditModule | undefined;

const loadedCheckpointRuntime = Symbol("loaded-checkpoint-runtime");

export interface LoadedCheckpointRuntime {
  readonly [loadedCheckpointRuntime]: true;
}

const loadedCheckpointRuntimeCapability: LoadedCheckpointRuntime = Object.freeze({
  [loadedCheckpointRuntime]: true as const,
});

async function loadAuditModule(): Promise<AuditModule> {
  auditModule ??= await import(
    "../../../target/js/release/build/mizchi/converge/x/game_audit/worker/worker.js"
  );
  return auditModule;
}

export type AnchorHeadDecision =
  | "advance"
  | "duplicate"
  | "same_epoch_fork"
  | "wrong_parent_fork"
  | "gap"
  | "stale"
  | "boundary_rejected";

export type CentralReplayArtifactDecision =
  | "boundary_rejected"
  | "awaiting_transcript"
  | "checkpoint_link_rejected"
  | "replay_incomplete"
  | "replay_mismatch"
  | "verified";

export type CheckpointClosureDecision =
  | "ready"
  | "pending_missing_frontier"
  | "pending_under_quorum"
  | "conflict_equivocation"
  | "refused_invalid_evidence";

export interface CheckpointRuntimeBoundary {
  protocol_version: number;
  purpose: string;
  manifest_digest: string;
  scope_id: string;
  unit_id: string;
}

export interface CheckpointDeliveryWitness {
  witness_id: string;
  witness_key: string;
}

export interface CheckpointDeliveryAuthenticationPolicy {
  producer_id: string;
  producer_key: string;
  witnesses: CheckpointDeliveryWitness[];
  required_approvals: number;
}

export interface CheckpointDeliveryApproval {
  statement_digest: string;
  witness_id: string;
  witness_key: string;
  digest: string;
  signature: string;
}

export interface CheckpointDeliveryAuthentication {
  version: 1;
  producer_id: string;
  producer_key: string;
  statement_digest: string;
  producer_signature: string;
  approvals: CheckpointDeliveryApproval[];
}

export type CheckpointDeliveryAuthenticationVerification =
  | { ok: true; producer_id: string; approval_count: number }
  | { ok: false; error: string };

export type ExperimentalCheckpointDeliveryApprovalSigning =
  | { ok: true; approval: CheckpointDeliveryApproval }
  | { ok: false; error: string };

export function sameCheckpointDeliveryAuthenticationPolicy(
  left: CheckpointDeliveryAuthenticationPolicy | undefined,
  right: CheckpointDeliveryAuthenticationPolicy | undefined,
): boolean {
  if (!left || !right) return left === right;
  const normalizeWitnesses = (
    witnesses: CheckpointDeliveryWitness[],
  ): Array<[string, string]> => witnesses
    .map((witness): [string, string] => [
      witness.witness_id,
      witness.witness_key,
    ])
    .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  return JSON.stringify([
    left.producer_id,
    left.producer_key,
    left.required_approvals,
    normalizeWitnesses(left.witnesses),
  ]) === JSON.stringify([
    right.producer_id,
    right.producer_key,
    right.required_approvals,
    normalizeWitnesses(right.witnesses),
  ]);
}

export function sameCheckpointDeliveryAuthentication(
  left: CheckpointDeliveryAuthentication | undefined,
  right: CheckpointDeliveryAuthentication | undefined,
): boolean {
  if (!left || !right) return left === right;
  const normalizeApprovals = (
    approvals: CheckpointDeliveryApproval[],
  ): Array<[string, string, string, string, string]> => approvals
    .map((approval): [string, string, string, string, string] => [
      approval.statement_digest,
      approval.witness_id,
      approval.witness_key,
      approval.digest,
      approval.signature,
    ])
    .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  return JSON.stringify([
    left.version,
    left.producer_id,
    left.producer_key,
    left.statement_digest,
    left.producer_signature,
    normalizeApprovals(left.approvals),
  ]) === JSON.stringify([
    right.version,
    right.producer_id,
    right.producer_key,
    right.statement_digest,
    right.producer_signature,
    normalizeApprovals(right.approvals),
  ]);
}

export function sameCheckpointDeliveryApproval(
  left: CheckpointDeliveryApproval,
  right: CheckpointDeliveryApproval,
): boolean {
  return left.statement_digest === right.statement_digest &&
    left.witness_id === right.witness_id &&
    left.witness_key === right.witness_key &&
    left.digest === right.digest &&
    left.signature === right.signature;
}

export interface StoredCheckpointClosure {
  epoch: number;
  roster_digest: string;
  frontier_digest: string;
  certificate_digest: string;
}

export interface PreparedCheckpointOutboxEntry {
  destination_id: string;
  epoch: number;
  checkpoint_digest: string;
  canonical_envelope: string;
  created_order: number;
}

export type AtomicCheckpointSealPreparation =
  | {
    decision: "prepared";
    epoch: number;
    digest: string;
    closure_epoch: number;
    next_outbox_entry_count: number;
    next_created_order: number;
    outbox: PreparedCheckpointOutboxEntry[];
  }
  | { decision: "duplicate" }
  | { decision: "conflict" | "refused"; reason: string };

export type CheckpointAckDecision =
  | "accepted"
  | "duplicate"
  | "gap"
  | "same_epoch_fork"
  | "parent_fork"
  | "stale_unknown"
  | "boundary_mismatch"
  | "refused";

export interface VerifiedAnchor {
  ok: true;
  session_id: string;
  publisher_key: string;
  epoch: number;
  digest: string;
  previous_digest: string;
  observer_id: string;
  anchor_root: string;
  anchor_size: number;
  envelope_bytes: number;
}

interface RefusedAnchor {
  ok: false;
  error: string;
}

export interface VerifiedPveReplay {
  ok: true;
  complete: true;
  session_id: string;
  authority_key: string;
  transparency_checkpoint_digest: string;
  checkpoint_digest: string;
  epoch: number;
  cleared: boolean;
  accepted_dodges: number;
  survivors: string[];
  defeated: string[];
  replayed_assets: number;
  bundle_bytes: number;
}

export interface RefusedPveReplay {
  ok: false;
  complete: boolean;
  error: string;
}

export type PveReplayVerification = VerifiedPveReplay | RefusedPveReplay;

export interface VerifiedPvpReplay {
  ok: true;
  complete: true;
  session_id: string;
  referee_key: string;
  checkpoint_digest: string;
  epoch: number;
  accepted_commands: number;
  approval_count: number;
  required_approvals: number;
  equivocators: string[];
  bundle_bytes: number;
}

export interface RefusedPvpReplay {
  ok: false;
  complete: boolean;
  error: string;
}

export type PvpReplayVerification = VerifiedPvpReplay | RefusedPvpReplay;

export interface VerifiedOpenWorldPveReplay {
  ok: true;
  complete: true;
  world_id: string;
  encounter_session_id: string;
  authority_key: string;
  transparency_checkpoint_digest: string;
  audit_checkpoint_digest: string;
  seal_checkpoint_digest: string;
  checkpoint_digest: string;
  observer_approvals: number;
  required_observer_approvals: number;
  cleared: boolean;
  accepted_dodges: number;
  survivors: string[];
  defeated: string[];
  verified_item_creations: VerifiedItemCreation[];
  bundle_bytes: number;
}

export interface VerifiedItemCreation {
  asset_id: string;
  initial_owner_id: string;
  item_type: string;
  quantity: number;
  output_index: number;
  source_event: string;
  checkpoint_digest: string;
  inventory_session_id: string;
  checkpoint_epoch: number;
}

export interface RefusedOpenWorldPveReplay {
  ok: false;
  complete: boolean;
  error: string;
}

export type OpenWorldPveReplayVerification =
  | VerifiedOpenWorldPveReplay
  | RefusedOpenWorldPveReplay;

export interface VerifiedInventoryListing {
  ok: true;
  complete: true;
  session_id: string;
  authority_key: string;
  checkpoint_digest: string;
  previous_checkpoint: string;
  epoch: number;
  public_state_root: string;
  asset_id: string;
  current_owner_id: string;
  version: number;
  last_event: string;
  approval_count: number;
  required_approvals: number;
  bundle_bytes: number;
}

export interface RefusedInventoryListing {
  ok: false;
  complete: boolean;
  error: string;
}

export type InventoryListingVerification =
  | VerifiedInventoryListing
  | RefusedInventoryListing;

export async function verifyAnchorEnvelope(
  envelopeHex: string,
  authorityKey: string,
  sessionId: string,
): Promise<VerifiedAnchor | RefusedAnchor> {
  const audit = await loadAuditModule();
  return JSON.parse(
    audit.audit_verify_anchor_envelope(envelopeHex, authorityKey, sessionId),
  ) as VerifiedAnchor | RefusedAnchor;
}

export async function openCheckpointClosure(input: {
  boundary: CheckpointRuntimeBoundary;
  closure: StoredCheckpointClosure;
  frontierComplete: boolean;
  conflictFree: boolean;
  quorumSatisfied: boolean;
}): Promise<CheckpointClosureDecision> {
  const audit = await loadAuditModule();
  return audit.audit_open_checkpoint_closure(
    input.boundary.protocol_version,
    input.boundary.purpose,
    input.boundary.manifest_digest,
    input.boundary.scope_id,
    input.boundary.unit_id,
    input.closure.epoch,
    input.closure.roster_digest,
    input.closure.frontier_digest,
    input.closure.certificate_digest,
    input.frontierComplete,
    input.conflictFree,
    input.quorumSatisfied,
  ) as CheckpointClosureDecision;
}

export async function loadCheckpointRuntime(): Promise<LoadedCheckpointRuntime> {
  await loadAuditModule();
  return loadedCheckpointRuntimeCapability;
}

/**
 * Client-side bridge for the unaudited experimental Ed25519 implementation.
 * Keep the seed in the witness process; authority routes must never call this.
 */
export async function signExperimentalCheckpointDeliveryApproval(input: {
  witnessSeedHex: string;
  witnessId: string;
  statementDigest: string;
}): Promise<ExperimentalCheckpointDeliveryApprovalSigning> {
  const audit = await loadAuditModule();
  return JSON.parse(
    audit.audit_experimental_sign_checkpoint_delivery_approval(
      input.witnessSeedHex,
      input.witnessId,
      input.statementDigest,
    ),
  ) as ExperimentalCheckpointDeliveryApprovalSigning;
}

export function verifyCheckpointDeliveryAuthenticationSync(
  runtime: LoadedCheckpointRuntime,
  input: {
  boundary: CheckpointRuntimeBoundary;
  destinationId: string;
  epoch: number;
  previousCheckpoint: string;
  checkpointDigest: string;
  canonicalEnvelope: string;
  policy: CheckpointDeliveryAuthenticationPolicy;
  authentication: CheckpointDeliveryAuthentication;
  },
): CheckpointDeliveryAuthenticationVerification {
  if (runtime !== loadedCheckpointRuntimeCapability || !auditModule) {
    throw new Error("MoonBit checkpoint runtime must be loaded before authentication");
  }
  const { boundary, policy, authentication } = input;
  return JSON.parse(
    auditModule.audit_verify_checkpoint_delivery_authentication(
      boundary.protocol_version,
      boundary.purpose,
      boundary.manifest_digest,
      boundary.scope_id,
      boundary.unit_id,
      input.destinationId,
      input.epoch,
      input.previousCheckpoint,
      input.checkpointDigest,
      input.canonicalEnvelope,
      policy.producer_id,
      policy.producer_key,
      policy.witnesses.map((witness) => witness.witness_id),
      policy.witnesses.map((witness) => witness.witness_key),
      policy.required_approvals,
      authentication.producer_id,
      authentication.producer_key,
      authentication.statement_digest,
      authentication.producer_signature,
      authentication.approvals.map((approval) => approval.statement_digest),
      authentication.approvals.map((approval) => approval.witness_id),
      authentication.approvals.map((approval) => approval.witness_key),
      authentication.approvals.map((approval) => approval.digest),
      authentication.approvals.map((approval) => approval.signature),
    ),
  ) as CheckpointDeliveryAuthenticationVerification;
}

export function prepareCheckpointSealSync(
  runtime: LoadedCheckpointRuntime,
  input: {
  boundary: CheckpointRuntimeBoundary;
  closure: StoredCheckpointClosure;
  currentEpoch: number;
  currentDigest: string;
  incomingEpochKnown: boolean;
  knownDigestMatches: boolean;
  knownSealComplete: boolean;
  closureConsumed: boolean;
  outboxEntryCount: number;
  outboxCapacity: number;
  nextCreatedOrder: number;
  checkpointEpoch: number;
  previousCheckpoint: string;
  checkpointDigest: string;
  canonicalEnvelope: string;
  destinations: string[];
  },
): AtomicCheckpointSealPreparation {
  if (runtime !== loadedCheckpointRuntimeCapability || !auditModule) {
    throw new Error("MoonBit checkpoint runtime must be loaded before transaction");
  }
  return JSON.parse(
    auditModule.audit_prepare_atomic_checkpoint_seal(
      input.boundary.protocol_version,
      input.boundary.purpose,
      input.boundary.manifest_digest,
      input.boundary.scope_id,
      input.boundary.unit_id,
      input.closure.epoch,
      input.closure.roster_digest,
      input.closure.frontier_digest,
      input.closure.certificate_digest,
      input.currentEpoch,
      input.currentDigest,
      input.incomingEpochKnown,
      input.knownDigestMatches,
      input.knownSealComplete,
      input.closureConsumed,
      input.outboxEntryCount,
      input.outboxCapacity,
      input.nextCreatedOrder,
      input.checkpointEpoch,
      input.previousCheckpoint,
      input.checkpointDigest,
      input.canonicalEnvelope,
      input.destinations,
    ),
  ) as AtomicCheckpointSealPreparation;
}

export function acknowledgeCheckpointOutboxSync(
  runtime: LoadedCheckpointRuntime,
  input: {
  boundary: CheckpointRuntimeBoundary;
  destinationId: string;
  epoch: number;
  checkpointDigest: string;
  canonicalEnvelope: string;
  createdOrder: number;
  ackBoundary: CheckpointRuntimeBoundary;
  ackAuthorityId: string;
  ackEpoch: number;
  ackCheckpointDigest: string;
  ackDecision: CheckpointAckDecision;
  authenticationSucceeded: boolean;
  },
): string {
  if (runtime !== loadedCheckpointRuntimeCapability || !auditModule) {
    throw new Error("MoonBit checkpoint runtime must be loaded before transaction");
  }
  return auditModule.audit_acknowledge_checkpoint_outbox(
    input.boundary.protocol_version,
    input.boundary.purpose,
    input.boundary.manifest_digest,
    input.boundary.scope_id,
    input.boundary.unit_id,
    input.destinationId,
    input.epoch,
    input.checkpointDigest,
    input.canonicalEnvelope,
    input.createdOrder,
    input.ackBoundary.protocol_version,
    input.ackBoundary.purpose,
    input.ackBoundary.manifest_digest,
    input.ackBoundary.scope_id,
    input.ackBoundary.unit_id,
    input.ackAuthorityId,
    input.ackEpoch,
    input.ackCheckpointDigest,
    input.ackDecision,
    input.authenticationSucceeded,
  );
}

export function classifyAnchorHead(input: {
  boundaryMatches: boolean;
  epochKnown: boolean;
  knownDigestMatches: boolean;
  currentEpoch: number;
  incomingEpoch: number;
  parentMatches: boolean;
}): AnchorHeadDecision {
  if (!auditModule) {
    throw new Error("MoonBit audit module must be loaded before classification");
  }
  return auditModule.audit_classify_anchor_head(
    input.boundaryMatches,
    input.epochKnown,
    input.knownDigestMatches,
    input.currentEpoch,
    input.incomingEpoch,
    input.parentMatches,
  ) as AnchorHeadDecision;
}

export async function classifyCentralReplayArtifacts(input: {
  anchorMatchesJob: boolean;
  transcriptPresent: boolean;
  checkpointLinkValid: boolean;
  kernelReplayComplete: boolean;
  kernelReplayMatches: boolean;
}): Promise<CentralReplayArtifactDecision> {
  const audit = await loadAuditModule();
  return audit.audit_classify_central_replay(
    input.anchorMatchesJob,
    input.transcriptPresent,
    input.checkpointLinkValid,
    input.kernelReplayComplete,
    input.kernelReplayMatches,
  ) as CentralReplayArtifactDecision;
}

export async function marketplaceCreationPersistAllowed(input: {
  openWorldBoundary: boolean;
  centralReplayVerified: boolean;
  summaryNormalized: boolean;
  checkpointBound: boolean;
  conflictFree: boolean;
}): Promise<boolean> {
  const audit = await loadAuditModule();
  return audit.audit_marketplace_creation_persist_allowed(
    input.openWorldBoundary,
    input.centralReplayVerified,
    input.summaryNormalized,
    input.checkpointBound,
    input.conflictFree,
  );
}

export async function inventoryHeadAdvanceAllowed(input: {
  creationEligible: boolean;
  proofVerified: boolean;
  manifestMatches: boolean;
  parentMatches: boolean;
  epochAdvances: boolean;
  ownerVersionConsistent: boolean;
}): Promise<boolean> {
  const audit = await loadAuditModule();
  return audit.audit_inventory_head_advance_allowed(
    input.creationEligible,
    input.proofVerified,
    input.manifestMatches,
    input.parentMatches,
    input.epochAdvances,
    input.ownerVersionConsistent,
  );
}

export async function verifyPveReplayBundle(
  bundleHex: string,
  expectedSessionId: string,
  expectedAuthorityKey: string,
  expectedCheckpointDigest: string,
): Promise<PveReplayVerification> {
  const audit = await loadAuditModule();
  return JSON.parse(
    audit.audit_verify_pve_replay_bundle(
      bundleHex,
      expectedSessionId,
      expectedAuthorityKey,
      expectedCheckpointDigest,
    ),
  ) as PveReplayVerification;
}

export async function verifyPvpReplayBundle(
  bundleHex: string,
  expectedSessionId: string,
  expectedRefereeKey: string,
  expectedCheckpointDigest: string,
): Promise<PvpReplayVerification> {
  const audit = await loadAuditModule();
  return JSON.parse(
    audit.audit_verify_pvp_replay_bundle(
      bundleHex,
      expectedSessionId,
      expectedRefereeKey,
      expectedCheckpointDigest,
    ),
  ) as PvpReplayVerification;
}

export async function verifyOpenWorldPveReplayBundle(
  bundleHex: string,
  expectedWorldId: string,
  expectedEncounterSessionId: string,
  expectedAuthorityKey: string,
  expectedTransparencyLogSessionId: string,
  expectedTransparencyPublisherKey: string,
  expectedTransparencyCheckpointDigest: string,
  expectedAuditCheckpointDigest: string,
  expectedSealCheckpointDigest: string,
  expectedEncounterCheckpointDigest: string,
): Promise<OpenWorldPveReplayVerification> {
  const audit = await loadAuditModule();
  return JSON.parse(
    audit.audit_verify_open_world_pve_replay_bundle(
      bundleHex,
      expectedWorldId,
      expectedEncounterSessionId,
      expectedAuthorityKey,
      expectedTransparencyLogSessionId,
      expectedTransparencyPublisherKey,
      expectedTransparencyCheckpointDigest,
      expectedAuditCheckpointDigest,
      expectedSealCheckpointDigest,
      expectedEncounterCheckpointDigest,
    ),
  ) as OpenWorldPveReplayVerification;
}

export async function verifyInventoryListingProofBundle(
  bundleHex: string,
  expectedSessionId: string,
  expectedAuthorityKey: string,
  expectedCheckpointDigest: string,
  expectedGameManifestDigest: string,
  expectedAssetId: string,
  expectedInitialOwnerId: string,
  expectedItemType: string,
  expectedQuantity: number,
  expectedSourceEvent: string,
  expectedOutputIndex: number,
  expectedSellerId: string,
  rejectedAncestor: boolean,
): Promise<InventoryListingVerification> {
  const audit = await loadAuditModule();
  return JSON.parse(
    audit.audit_verify_inventory_listing_proof_bundle(
      bundleHex,
      expectedSessionId,
      expectedAuthorityKey,
      expectedCheckpointDigest,
      expectedGameManifestDigest,
      expectedAssetId,
      expectedInitialOwnerId,
      expectedItemType,
      expectedQuantity,
      expectedSourceEvent,
      expectedOutputIndex,
      expectedSellerId,
      rejectedAncestor,
    ),
  ) as InventoryListingVerification;
}
