import type {
  PeerCheckpointResponseMetadata,
  PeerCheckpointResponseSelection,
  PeerDeliveryPolicy,
  PeerDeliverySelection,
  PeerRouteState,
  PeerRouteUpdate,
} from "./peer-contracts.ts";

type AuditModule = typeof import(
  "../../../target/js/release/build/mizchi/converge/audit/runtime/bridge/bridge.js"
);

let loadedModule: Promise<AuditModule> | undefined;

function loadAuditModule(): Promise<AuditModule> {
  loadedModule ??= import(
    "../../../target/js/release/build/mizchi/converge/audit/runtime/bridge/bridge.js"
  );
  return loadedModule;
}

function parseJson<Result>(value: string): Result {
  return JSON.parse(value) as Result;
}

function routeArguments(route: PeerRouteState): [
  string,
  boolean,
  boolean,
  number,
  number,
  number,
] {
  return [
    route.peer_id,
    route.available,
    route.quarantined,
    route.failures,
    route.next_retry_at_ms,
    route.last_attempt_order,
  ];
}

/** Proof-facing peer scheduler backed by the generated MoonBit JS module. */
export class MoonBitPeerDeliveryPolicy implements PeerDeliveryPolicy {
  static async load(): Promise<MoonBitPeerDeliveryPolicy> {
    return new MoonBitPeerDeliveryPolicy(await loadAuditModule());
  }

  private readonly module: AuditModule;

  private constructor(module: AuditModule) {
    this.module = module;
  }

  selectBatch(
    routes: PeerRouteState[],
    nowMs: number,
    inFlightCount: number,
    maxInFlight: number,
    maxParallel: number,
  ): PeerDeliverySelection {
    return parseJson<PeerDeliverySelection>(
      this.module.audit_select_peer_delivery_batch(
        routes.map((route) => route.peer_id),
        routes.map((route) => route.available),
        routes.map((route) => route.quarantined),
        routes.map((route) => route.failures),
        routes.map((route) => route.next_retry_at_ms),
        routes.map((route) => route.last_attempt_order),
        nowMs,
        inFlightCount,
        maxInFlight,
        maxParallel,
      ),
    );
  }

  recordFailure(
    route: PeerRouteState,
    nowMs: number,
    attemptOrder: number,
    baseBackoffMs: number,
    maxBackoffMs: number,
  ): PeerRouteUpdate {
    return parseJson<PeerRouteUpdate>(
      this.module.audit_record_peer_delivery_failure(
        ...routeArguments(route),
        nowMs,
        attemptOrder,
        baseBackoffMs,
        maxBackoffMs,
      ),
    );
  }

  recordSuccess(
    route: PeerRouteState,
    attemptOrder: number,
  ): PeerRouteUpdate {
    return parseJson<PeerRouteUpdate>(
      this.module.audit_record_peer_delivery_success(
        ...routeArguments(route),
        attemptOrder,
      ),
    );
  }

  selectResponse(
    responses: PeerCheckpointResponseMetadata[],
    expectedDigest: string,
  ): PeerCheckpointResponseSelection {
    return parseJson<PeerCheckpointResponseSelection>(
      this.module.audit_select_peer_checkpoint_response(
        responses.map((response) => response.peer_id),
        responses.map((response) => response.checkpoint_digest),
        responses.map((response) => response.authenticated),
        responses.map((response) => response.received_at_ms),
        expectedDigest,
      ),
    );
  }
}
