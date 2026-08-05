export interface AuditBoundary {
  protocol_version: number;
  purpose: string;
  manifest_digest: string;
  scope_id: string;
  unit_id: string;
}

export interface PlayerLocalStoreConfiguration {
  boundary: AuditBoundary;
  genesis_digest: string;
  outbox_capacity: number;
}

export interface PlayerLocalAuditEvent {
  boundary: AuditBoundary;
  author_id: string;
  counter: number;
  epoch: number;
  event_digest: string;
  canonical_event: string;
}

export interface PlayerLocalEventEquivocation {
  accepted: PlayerLocalAuditEvent;
  conflicting: PlayerLocalAuditEvent;
}

export interface CheckpointSealDraft {
  boundary: AuditBoundary;
  epoch: number;
  previous_checkpoint: string;
  checkpoint_digest: string;
  canonical_envelope: string;
}

export interface CheckpointSealHead {
  boundary: AuditBoundary;
  epoch: number;
  checkpoint_digest: string;
}

export type CheckpointOutboxState =
  | { kind: "pending" }
  | { kind: "in_flight"; lease_expires_at_ms: number }
  | { kind: "acknowledged" };

export interface PlayerLocalCheckpointOutboxRecord {
  boundary: AuditBoundary;
  destination_id: string;
  epoch: number;
  checkpoint_digest: string;
  canonical_envelope: string;
  created_order: number;
  state: CheckpointOutboxState;
}

export interface EpochClosureEvidence {
  boundary: AuditBoundary;
  epoch: number;
  roster_digest: string;
  frontier_digest: string;
  certificate_digest: string;
}

export interface CheckpointAckEvidence {
  boundary: AuditBoundary;
  authority_id: string;
  epoch: number;
  checkpoint_digest: string;
  decision: "accepted" | "duplicate";
}

export interface CheckpointSealStorageSnapshot {
  boundary: AuditBoundary;
  current_epoch: number;
  current_digest: string;
  incoming_epoch_known: boolean;
  known_digest_matches: boolean;
  known_seal_complete: boolean;
  closure_consumed: boolean;
  outbox_entry_count: number;
  outbox_capacity: number;
  next_created_order: number;
}

/**
 * Host representation of MoonBit's opaque `PlayerLocalSealPlan`. Construct it
 * from `PlayerLocalSealPlan::write_set`; the physical adapter then rechecks the
 * storage-facing shape and compare-and-swaps the expected revision/snapshot.
 */
export interface PlayerLocalSealWriteSet {
  expected_revision: number;
  expected_snapshot: CheckpointSealStorageSnapshot;
  checkpoint: CheckpointSealDraft;
  next_head: CheckpointSealHead;
  outbox_entries: PlayerLocalCheckpointOutboxRecord[];
  consumed_closure: EpochClosureEvidence;
  next_outbox_entry_count: number;
  next_created_order: number;
}

export interface PlayerLocalAuditImage {
  boundary: AuditBoundary;
  genesis_digest: string;
  outbox_capacity: number;
  events: PlayerLocalAuditEvent[];
  equivocations: PlayerLocalEventEquivocation[];
  checkpoints: CheckpointSealDraft[];
  head: CheckpointSealHead;
  consumed_closures: EpochClosureEvidence[];
  outbox: PlayerLocalCheckpointOutboxRecord[];
  ack_history: CheckpointAckEvidence[];
  next_created_order: number;
  storage_revision: number;
}

export type PlayerLocalEventAdmission =
  | { decision: "stored" | "duplicate" | "equivocation" }
  | { decision: "refused"; reason: string };

export type PlayerLocalSealCommitResult =
  | { decision: "committed" | "concurrent_write" }
  | { decision: "refused"; reason: "invalid_write_set" };

export type PlayerLocalOutboxAckResult =
  | { decision: "updated" | "no_change" }
  | { decision: "refused"; reason: string };

export type PlayerLocalSealFaultPoint =
  | "after_history"
  | "after_head"
  | "after_outbox"
  | "after_closure";
