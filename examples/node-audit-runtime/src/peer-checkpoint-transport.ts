import type {
  PeerCheckpointDelivery,
  PeerCheckpointDispatchResult,
  PeerCheckpointSender,
  PeerCheckpointTransportConfiguration,
  PeerDeliveryPolicy,
  PeerForkEvidence,
  PeerResponseVerifier,
  PeerRouteClaim,
  PeerRouteEndpoint,
  PeerRouteState,
  RawPeerCheckpointResponse,
} from "./peer-contracts.ts";
import {
  PeerRouteSqliteStore,
  PeerRouteStoreConcurrentError,
} from "./peer-route-sqlite.ts";

export type * from "./peer-contracts.ts";

interface AttemptResult {
  claim: PeerRouteClaim;
  response?: RawPeerCheckpointResponse;
  authenticated: boolean;
  received_at_ms: number;
}

function positiveInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function deliveryValid(delivery: PeerCheckpointDelivery): boolean {
  const boundary = delivery.boundary;
  return (
    positiveInteger(boundary.protocol_version) &&
    boundary.purpose.length > 0 &&
    boundary.manifest_digest.length > 0 &&
    boundary.scope_id.length > 0 &&
    boundary.unit_id.length > 0 &&
    Number.isSafeInteger(delivery.epoch) &&
    delivery.epoch >= 0 &&
    delivery.checkpoint_digest.length > 0 &&
    delivery.canonical_envelope.length > 0
  );
}

function validConfiguration(
  value: PeerCheckpointTransportConfiguration,
): boolean {
  return (
    positiveInteger(value.max_in_flight) &&
    positiveInteger(value.max_parallel) &&
    positiveInteger(value.lease_duration_ms) &&
    positiveInteger(value.base_backoff_ms) &&
    positiveInteger(value.max_backoff_ms) &&
    value.max_backoff_ms >= value.base_backoff_ms
  );
}

export class PeerCheckpointDispatcher {
  private readonly store: PeerRouteSqliteStore;
  private readonly policy: PeerDeliveryPolicy;
  private readonly sender: PeerCheckpointSender;
  private readonly verifyResponse: PeerResponseVerifier;
  private readonly configuration: PeerCheckpointTransportConfiguration;

  constructor(
    store: PeerRouteSqliteStore,
    policy: PeerDeliveryPolicy,
    sender: PeerCheckpointSender,
    verifyResponse: PeerResponseVerifier,
    configuration: PeerCheckpointTransportConfiguration,
  ) {
    if (!validConfiguration(configuration)) {
      throw new TypeError("invalid peer checkpoint transport configuration");
    }
    if (
      !positiveInteger(sender.maximum_attempt_duration_ms) ||
      sender.maximum_attempt_duration_ms > configuration.lease_duration_ms
    ) {
      throw new TypeError("sender deadline must not exceed durable lease");
    }
    this.store = store;
    this.policy = policy;
    this.sender = sender;
    this.verifyResponse = verifyResponse;
    this.configuration = configuration;
  }

  async dispatch(
    delivery: PeerCheckpointDelivery,
    nowMs: number,
    signal: AbortSignal = new AbortController().signal,
  ): Promise<PeerCheckpointDispatchResult> {
    if (
      !deliveryValid(delivery) ||
      !Number.isSafeInteger(nowMs) ||
      nowMs < 0 ||
      nowMs > 2_147_483_647 - this.configuration.max_parallel
    ) {
      throw new TypeError("invalid peer checkpoint dispatch input");
    }
    const routeRecords = this.store.routes(nowMs);
    const routeStates = routeRecords.map((route): PeerRouteState => ({
      peer_id: route.peer_id,
      available: route.available,
      quarantined: route.quarantined,
      failures: route.failures,
      next_retry_at_ms: route.next_retry_at_ms,
      last_attempt_order: route.last_attempt_order,
    }));
    const selection = this.policy.selectBatch(
      routeStates,
      nowMs,
      this.store.activeLeaseCount(nowMs),
      this.configuration.max_in_flight,
      this.configuration.max_parallel,
    );
    if (selection.decision === "backpressured") {
      return { decision: "backpressured" };
    }
    if (selection.decision === "unavailable") {
      return { decision: "unavailable" };
    }
    if (selection.decision === "refused") {
      throw new Error(`MoonBit peer selection refused: ${selection.reason}`);
    }
    const selectedPeerIds = selection.indices.map((index) => {
      const route = routeStates[index];
      if (!route) throw new Error("MoonBit selected an unknown route index");
      return route.peer_id;
    });
    const claims = this.store.claimRoutes(
      selectedPeerIds,
      nowMs,
      this.configuration.lease_duration_ms,
    );
    if (claims.length === 0) return { decision: "unavailable" };

    let completionOrder = 0;
    const attempts = await Promise.all(
      claims.map(async (claim): Promise<AttemptResult> => {
        try {
          const response = await this.sender.send(claim.endpoint, delivery, signal);
          const receivedAt = nowMs + completionOrder;
          completionOrder += 1;
          const authenticated =
            response.peer_id === claim.route.peer_id &&
            (await this.verifyResponse(response, claim.endpoint, delivery));
          return {
            claim,
            response,
            authenticated,
            received_at_ms: receivedAt,
          };
        } catch {
          const receivedAt = nowMs + completionOrder;
          completionOrder += 1;
          return { claim, authenticated: false, received_at_ms: receivedAt };
        }
      }),
    );

    for (const attempt of attempts) {
      this.persistAttempt(attempt, delivery, nowMs);
    }
    const responses = attempts
      .filter(
        (attempt): attempt is AttemptResult & {
          response: RawPeerCheckpointResponse;
        } => attempt.response !== undefined,
      )
      .map((attempt) => ({
        peer_id: attempt.claim.route.peer_id,
        checkpoint_digest: attempt.response.checkpoint_digest,
        authenticated: attempt.authenticated,
        received_at_ms: attempt.received_at_ms,
      }));
    const authenticated = attempts.filter((attempt) => attempt.authenticated).length;
    const failed = attempts.length - authenticated;
    const responseSelection = this.policy.selectResponse(
      responses,
      delivery.checkpoint_digest,
    );
    if (responseSelection.decision === "fork_detected") {
      return {
        decision: "fork_detected",
        fork_peers: attempts
          .filter(
            (attempt) =>
              attempt.authenticated &&
              attempt.response !== undefined &&
              attempt.response.checkpoint_digest !== delivery.checkpoint_digest,
          )
          .map((attempt) => attempt.claim.route.peer_id),
        attempted: attempts.length,
        authenticated,
        failed,
      };
    }
    if (responseSelection.decision === "accepted") {
      const selected = responses[responseSelection.index];
      if (!selected) throw new Error("MoonBit selected an unknown response index");
      return {
        decision: "accepted",
        peer_id: selected.peer_id,
        attempted: attempts.length,
        authenticated,
        failed,
      };
    }
    if (responseSelection.decision === "refused") {
      throw new Error("MoonBit peer response selection refused");
    }
    return {
      decision: "no_authenticated_response",
      attempted: attempts.length,
      authenticated: 0,
      failed,
    };
  }

  private persistAttempt(
    attempt: AttemptResult,
    delivery: PeerCheckpointDelivery,
    nowMs: number,
  ): void {
    const routeUpdate = attempt.authenticated
      ? this.policy.recordSuccess(
          attempt.claim.route,
          attempt.claim.attempt_order,
        )
      : this.policy.recordFailure(
          attempt.claim.route,
          nowMs,
          attempt.claim.attempt_order,
          this.configuration.base_backoff_ms,
          this.configuration.max_backoff_ms,
        );
    if (routeUpdate.decision !== "updated") {
      throw new Error("MoonBit peer route transition refused");
    }
    const isFork =
      attempt.authenticated &&
      attempt.response !== undefined &&
      attempt.response.checkpoint_digest !== delivery.checkpoint_digest;
    const committed = isFork
      ? this.store.recordFork(
          attempt.claim,
          routeUpdate.route,
          this.forkEvidence(attempt, delivery),
        )
      : this.store.completeClaim(attempt.claim, routeUpdate.route);
    if (!committed) throw new PeerRouteStoreConcurrentError();
  }

  private forkEvidence(
    attempt: AttemptResult & { response?: RawPeerCheckpointResponse },
    delivery: PeerCheckpointDelivery,
  ): PeerForkEvidence {
    if (!attempt.response) throw new Error("fork response missing");
    return {
      peer_id: attempt.claim.route.peer_id,
      expected_digest: delivery.checkpoint_digest,
      conflicting_digest: attempt.response.checkpoint_digest,
      received_at_ms: attempt.received_at_ms,
      canonical_response: attempt.response.canonical_response,
    };
  }
}

export interface HttpPeerCheckpointSenderConfiguration {
  timeout_ms: number;
  max_response_bytes: number;
}

export class HttpPeerCheckpointSender implements PeerCheckpointSender {
  readonly maximum_attempt_duration_ms: number;
  private readonly configuration: HttpPeerCheckpointSenderConfiguration;

  constructor(configuration: HttpPeerCheckpointSenderConfiguration) {
    if (
      !positiveInteger(configuration.timeout_ms) ||
      !positiveInteger(configuration.max_response_bytes)
    ) {
      throw new TypeError("invalid HTTP peer sender configuration");
    }
    this.configuration = configuration;
    this.maximum_attempt_duration_ms = configuration.timeout_ms;
  }

  async send(
    route: PeerRouteEndpoint,
    delivery: PeerCheckpointDelivery,
    signal: AbortSignal,
  ): Promise<RawPeerCheckpointResponse> {
    const timeout = AbortSignal.timeout(this.configuration.timeout_ms);
    const response = await fetch(route.endpoint_url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        kind: "converge-peer-checkpoint-v1",
        peer_id: route.peer_id,
        boundary: delivery.boundary,
        epoch: delivery.epoch,
        checkpoint_digest: delivery.checkpoint_digest,
        canonical_envelope: delivery.canonical_envelope,
      }),
      signal: AbortSignal.any([signal, timeout]),
    });
    if (!response.ok) throw new Error(`peer HTTP status ${response.status}`);
    const bytes = await readBoundedBody(
      response,
      this.configuration.max_response_bytes,
    );
    const decoded: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (!rawResponseValid(decoded)) throw new Error("invalid peer response");
    return decoded;
  }
}

async function readBoundedBody(
  response: Response,
  maximumBytes: number,
): Promise<Uint8Array> {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null && Number(contentLength) > maximumBytes) {
    await response.body?.cancel();
    throw new Error("peer response exceeds byte budget");
  }
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumBytes) {
      await reader.cancel();
      throw new Error("peer response exceeds byte budget");
    }
    chunks.push(value);
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function rawResponseValid(value: unknown): value is RawPeerCheckpointResponse {
  if (!value || typeof value !== "object") return false;
  const response = value as Record<string, unknown>;
  return (
    response.kind === "converge-peer-checkpoint-ack-v1" &&
    typeof response.peer_id === "string" &&
    response.peer_id.length > 0 &&
    typeof response.checkpoint_digest === "string" &&
    response.checkpoint_digest.length > 0 &&
    typeof response.canonical_response === "string" &&
    response.canonical_response.length > 0 &&
    Object.hasOwn(response, "authentication")
  );
}
