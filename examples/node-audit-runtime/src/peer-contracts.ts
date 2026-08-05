import type { AuditBoundary } from "./contracts.ts";

export interface PeerRouteState {
  peer_id: string;
  available: boolean;
  quarantined: boolean;
  failures: number;
  next_retry_at_ms: number;
  last_attempt_order: number;
}

export interface PeerRouteEndpoint {
  peer_id: string;
  endpoint_url: string;
}

export interface PeerRouteRecord extends PeerRouteState, PeerRouteEndpoint {
  lease_expires_at_ms: number | null;
}

export interface PeerRouteClaim {
  route: PeerRouteState;
  endpoint: PeerRouteEndpoint;
  attempt_order: number;
  lease_expires_at_ms: number;
}

export interface PeerForkEvidence {
  peer_id: string;
  expected_digest: string;
  conflicting_digest: string;
  received_at_ms: number;
  canonical_response: string;
}

export type PeerDeliverySelection =
  | { decision: "selected"; indices: number[] }
  | { decision: "unavailable" }
  | { decision: "backpressured" }
  | { decision: "refused"; reason: string };

export type PeerRouteUpdate =
  | { decision: "updated"; route: PeerRouteState }
  | { decision: "refused" };

export interface PeerCheckpointResponseMetadata {
  peer_id: string;
  checkpoint_digest: string;
  authenticated: boolean;
  received_at_ms: number;
}

export type PeerCheckpointResponseSelection =
  | { decision: "accepted"; index: number }
  | { decision: "fork_detected"; fork_count: number }
  | { decision: "unavailable" }
  | { decision: "refused" };

export interface PeerDeliveryPolicy {
  selectBatch(
    routes: PeerRouteState[],
    nowMs: number,
    inFlightCount: number,
    maxInFlight: number,
    maxParallel: number,
  ): PeerDeliverySelection;
  recordFailure(
    route: PeerRouteState,
    nowMs: number,
    attemptOrder: number,
    baseBackoffMs: number,
    maxBackoffMs: number,
  ): PeerRouteUpdate;
  recordSuccess(route: PeerRouteState, attemptOrder: number): PeerRouteUpdate;
  selectResponse(
    responses: PeerCheckpointResponseMetadata[],
    expectedDigest: string,
  ): PeerCheckpointResponseSelection;
}

export interface PeerCheckpointDelivery {
  boundary: AuditBoundary;
  epoch: number;
  checkpoint_digest: string;
  canonical_envelope: string;
}

export interface RawPeerCheckpointResponse {
  kind: "converge-peer-checkpoint-ack-v1";
  peer_id: string;
  checkpoint_digest: string;
  canonical_response: string;
  authentication: unknown;
}

export interface PeerCheckpointSender {
  readonly maximum_attempt_duration_ms: number;
  send(
    route: PeerRouteEndpoint,
    delivery: PeerCheckpointDelivery,
    signal: AbortSignal,
  ): Promise<RawPeerCheckpointResponse>;
}

export type PeerResponseVerifier = (
  response: RawPeerCheckpointResponse,
  route: PeerRouteEndpoint,
  delivery: PeerCheckpointDelivery,
) => Promise<boolean>;

export interface PeerCheckpointTransportConfiguration {
  max_in_flight: number;
  max_parallel: number;
  lease_duration_ms: number;
  base_backoff_ms: number;
  max_backoff_ms: number;
}

export type PeerCheckpointDispatchResult =
  | {
      decision: "accepted";
      peer_id: string;
      attempted: number;
      authenticated: number;
      failed: number;
    }
  | {
      decision: "fork_detected";
      fork_peers: string[];
      attempted: number;
      authenticated: number;
      failed: number;
    }
  | {
      decision: "no_authenticated_response";
      attempted: number;
      authenticated: 0;
      failed: number;
    }
  | { decision: "unavailable" | "backpressured" };
