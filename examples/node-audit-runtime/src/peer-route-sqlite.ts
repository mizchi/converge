import { DatabaseSync, type SQLInputValue } from "node:sqlite";

import type { AuditBoundary } from "./contracts.ts";
import type {
  PeerForkEvidence,
  PeerRouteClaim,
  PeerRouteEndpoint,
  PeerRouteRecord,
  PeerRouteState,
} from "./peer-contracts.ts";

interface BoundaryRow {
  protocol_version: number;
  purpose: string;
  manifest_digest: string;
  scope_id: string;
  unit_id: string;
}

interface RouteRow {
  peer_id: string;
  endpoint_url: string;
  available: number;
  quarantined: number;
  failures: number;
  next_retry_at_ms: number;
  last_attempt_order: number;
  lease_expires_at_ms: number | null;
  lease_attempt_order: number | null;
}

interface ClockRow {
  next_attempt_order: number;
}

function isNonNegativeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function positiveAttemptOrder(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 1 && value <= 2_147_483_648;
}

function sameBoundary(left: BoundaryRow, right: AuditBoundary): boolean {
  return (
    left.protocol_version === right.protocol_version &&
    left.purpose === right.purpose &&
    left.manifest_digest === right.manifest_digest &&
    left.scope_id === right.scope_id &&
    left.unit_id === right.unit_id
  );
}

function endpointValid(endpoint: PeerRouteEndpoint): boolean {
  if (endpoint.peer_id.length === 0) return false;
  try {
    const url = new URL(endpoint.endpoint_url);
    return (
      (url.protocol === "http:" || url.protocol === "https:") &&
      url.username.length === 0 &&
      url.password.length === 0 &&
      url.hash.length === 0
    );
  } catch {
    return false;
  }
}

export class PeerRouteStoreConcurrentError extends Error {}

export class PeerRouteStoreCorruptError extends Error {}

export class PeerRouteSqliteStore {
  static open(path: string, expectedBoundary: AuditBoundary): PeerRouteSqliteStore {
    const database = new DatabaseSync(path);
    try {
      const store = new PeerRouteSqliteStore(database);
      store.createSchema();
      const boundary = store.get<BoundaryRow>(
        `SELECT protocol_version, purpose, manifest_digest, scope_id, unit_id
         FROM player_local_config WHERE singleton = 1`,
      );
      if (!boundary || !sameBoundary(boundary, expectedBoundary)) {
        throw new Error("peer route database boundary mismatch");
      }
      store.assertValidImage();
      return store;
    } catch (error) {
      database.close();
      throw error;
    }
  }

  private readonly database: DatabaseSync;

  private constructor(database: DatabaseSync) {
    this.database = database;
  }

  close(): void {
    this.database.close();
  }

  configureRoutes(
    endpoints: PeerRouteEndpoint[],
  ):
    | { decision: "configured"; inserted: number }
    | { decision: "refused" | "conflict"; peer_id?: string } {
    const seen = new Set<string>();
    if (endpoints.length === 0) return { decision: "refused" };
    for (const endpoint of endpoints) {
      if (!endpointValid(endpoint) || seen.has(endpoint.peer_id)) {
        return { decision: "refused" };
      }
      seen.add(endpoint.peer_id);
    }
    return this.transaction(() => {
      for (const endpoint of endpoints) {
        const existing = this.get<{ endpoint_url: string }>(
          `SELECT endpoint_url FROM player_local_peer_routes WHERE peer_id = ?`,
          endpoint.peer_id,
        );
        if (existing && existing.endpoint_url !== endpoint.endpoint_url) {
          return { decision: "conflict", peer_id: endpoint.peer_id };
        }
      }
      let inserted = 0;
      for (const endpoint of endpoints) {
        const changed = this.run(
          `INSERT OR IGNORE INTO player_local_peer_routes
           (peer_id, endpoint_url, available, quarantined, failures,
            next_retry_at_ms, last_attempt_order, lease_expires_at_ms,
            lease_attempt_order)
           VALUES (?, ?, 1, 0, 0, 0, 0, NULL, NULL)`,
          endpoint.peer_id,
          endpoint.endpoint_url,
        );
        inserted += changed;
      }
      return { decision: "configured", inserted };
    });
  }

  routes(nowMs: number): PeerRouteRecord[] {
    if (!isNonNegativeInteger(nowMs)) return [];
    return this.routeRows().map((row) => ({
      peer_id: row.peer_id,
      endpoint_url: row.endpoint_url,
      available:
        row.available === 1 &&
        (row.lease_expires_at_ms === null || row.lease_expires_at_ms <= nowMs),
      quarantined: row.quarantined === 1,
      failures: row.failures,
      next_retry_at_ms: row.next_retry_at_ms,
      last_attempt_order: row.last_attempt_order,
      lease_expires_at_ms: row.lease_expires_at_ms,
    }));
  }

  activeLeaseCount(nowMs: number): number {
    if (!isNonNegativeInteger(nowMs)) return 0;
    return (
      this.get<{ count: number }>(
        `SELECT COUNT(*) AS count FROM player_local_peer_routes
         WHERE lease_expires_at_ms > ?`,
        nowMs,
      )?.count ?? 0
    );
  }

  claimRoutes(
    peerIds: string[],
    nowMs: number,
    leaseDurationMs: number,
  ): PeerRouteClaim[] {
    if (
      !isNonNegativeInteger(nowMs) ||
      !Number.isSafeInteger(leaseDurationMs) ||
      leaseDurationMs <= 0 ||
      new Set(peerIds).size !== peerIds.length
    ) {
      return [];
    }
    const leaseExpiresAt = nowMs + leaseDurationMs;
    if (!Number.isSafeInteger(leaseExpiresAt) || leaseExpiresAt < nowMs) {
      return [];
    }
    return this.transaction(() => {
      let nextAttemptOrder = this.get<ClockRow>(
        `SELECT next_attempt_order FROM player_local_peer_attempt_clock
         WHERE singleton = 1`,
      )?.next_attempt_order;
      if (nextAttemptOrder === undefined) throw new Error("missing attempt clock");
      const claims: PeerRouteClaim[] = [];
      for (const peerId of peerIds) {
        if (nextAttemptOrder > 2_147_483_647) break;
        const row = this.routeAt(peerId);
        if (
          !row ||
          row.available !== 1 ||
          row.quarantined === 1 ||
          row.next_retry_at_ms > nowMs ||
          (row.lease_expires_at_ms !== null && row.lease_expires_at_ms > nowMs)
        ) {
          continue;
        }
        const changed = this.run(
          `UPDATE player_local_peer_routes
           SET lease_expires_at_ms = ?, lease_attempt_order = ?
           WHERE peer_id = ? AND available = 1 AND quarantined = 0
             AND next_retry_at_ms <= ?
             AND (lease_expires_at_ms IS NULL OR lease_expires_at_ms <= ?)`,
          leaseExpiresAt,
          nextAttemptOrder,
          peerId,
          nowMs,
          nowMs,
        );
        if (changed !== 1) continue;
        claims.push({
          route: this.routeState(row),
          endpoint: { peer_id: row.peer_id, endpoint_url: row.endpoint_url },
          attempt_order: nextAttemptOrder,
          lease_expires_at_ms: leaseExpiresAt,
        });
        nextAttemptOrder += 1;
      }
      this.run(
        `UPDATE player_local_peer_attempt_clock SET next_attempt_order = ?
         WHERE singleton = 1`,
        nextAttemptOrder,
      );
      return claims;
    });
  }

  completeClaim(claim: PeerRouteClaim, nextRoute: PeerRouteState): boolean {
    if (
      claim.route.peer_id !== nextRoute.peer_id ||
      nextRoute.last_attempt_order !== claim.attempt_order
    ) {
      return false;
    }
    return this.transaction(() =>
      this.updateClaimedRoute(claim, nextRoute, false) === 1,
    );
  }

  recordFork(
    claim: PeerRouteClaim,
    nextRoute: PeerRouteState,
    evidence: PeerForkEvidence,
  ): boolean {
    if (
      evidence.peer_id !== claim.route.peer_id ||
      evidence.expected_digest.length === 0 ||
      evidence.conflicting_digest.length === 0 ||
      evidence.expected_digest === evidence.conflicting_digest ||
      evidence.canonical_response.length === 0 ||
      !isNonNegativeInteger(evidence.received_at_ms) ||
      nextRoute.last_attempt_order !== claim.attempt_order
    ) {
      return false;
    }
    return this.transaction(() => {
      const existing = this.get<{
        received_at_ms: number;
        canonical_response: string;
      }>(
        `SELECT received_at_ms, canonical_response
         FROM player_local_peer_fork_evidence
         WHERE peer_id = ? AND expected_digest = ? AND conflicting_digest = ?`,
        evidence.peer_id,
        evidence.expected_digest,
        evidence.conflicting_digest,
      );
      if (
        existing &&
        (existing.received_at_ms !== evidence.received_at_ms ||
          existing.canonical_response !== evidence.canonical_response)
      ) {
        return false;
      }
      if (!existing) {
        this.run(
          `INSERT INTO player_local_peer_fork_evidence
           (peer_id, expected_digest, conflicting_digest, received_at_ms,
            canonical_response)
           VALUES (?, ?, ?, ?, ?)`,
          evidence.peer_id,
          evidence.expected_digest,
          evidence.conflicting_digest,
          evidence.received_at_ms,
          evidence.canonical_response,
        );
      }
      return this.updateClaimedRoute(claim, nextRoute, true) === 1;
    });
  }

  forkEvidence(): PeerForkEvidence[] {
    return this.all<PeerForkEvidence>(
      `SELECT peer_id, expected_digest, conflicting_digest, received_at_ms,
              canonical_response
       FROM player_local_peer_fork_evidence
       ORDER BY received_at_ms, peer_id, conflicting_digest`,
    ).map((evidence) => ({ ...evidence }));
  }

  private createSchema(): void {
    this.database.exec(`
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS player_local_peer_attempt_clock (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        next_attempt_order INTEGER NOT NULL CHECK (
          next_attempt_order >= 1 AND next_attempt_order <= 2147483648
        )
      );
      INSERT OR IGNORE INTO player_local_peer_attempt_clock
      (singleton, next_attempt_order) VALUES (1, 1);
      CREATE TABLE IF NOT EXISTS player_local_peer_routes (
        peer_id TEXT PRIMARY KEY CHECK (length(peer_id) > 0),
        endpoint_url TEXT NOT NULL CHECK (length(endpoint_url) > 0),
        available INTEGER NOT NULL CHECK (available IN (0, 1)),
        quarantined INTEGER NOT NULL CHECK (quarantined IN (0, 1)),
        failures INTEGER NOT NULL CHECK (failures >= 0),
        next_retry_at_ms INTEGER NOT NULL CHECK (next_retry_at_ms >= 0),
        last_attempt_order INTEGER NOT NULL CHECK (last_attempt_order >= 0),
        lease_expires_at_ms INTEGER,
        lease_attempt_order INTEGER UNIQUE,
        CHECK (
          (lease_expires_at_ms IS NULL AND lease_attempt_order IS NULL)
          OR
          (lease_expires_at_ms >= 0 AND lease_attempt_order >= 1)
        )
      );
      CREATE INDEX IF NOT EXISTS player_local_peer_route_retry
      ON player_local_peer_routes(
        available, quarantined, next_retry_at_ms, last_attempt_order
      );
      CREATE TABLE IF NOT EXISTS player_local_peer_fork_evidence (
        peer_id TEXT NOT NULL,
        expected_digest TEXT NOT NULL CHECK (length(expected_digest) > 0),
        conflicting_digest TEXT NOT NULL CHECK (length(conflicting_digest) > 0),
        received_at_ms INTEGER NOT NULL CHECK (received_at_ms >= 0),
        canonical_response TEXT NOT NULL CHECK (length(canonical_response) > 0),
        PRIMARY KEY (peer_id, expected_digest, conflicting_digest),
        FOREIGN KEY (peer_id) REFERENCES player_local_peer_routes(peer_id)
      );
    `);
  }

  private updateClaimedRoute(
    claim: PeerRouteClaim,
    nextRoute: PeerRouteState,
    quarantine: boolean,
  ): number {
    return this.run(
      `UPDATE player_local_peer_routes
       SET available = ?, quarantined = ?, failures = ?,
           next_retry_at_ms = ?, last_attempt_order = ?,
           lease_expires_at_ms = NULL, lease_attempt_order = NULL
       WHERE peer_id = ? AND lease_expires_at_ms = ?
         AND lease_attempt_order = ?`,
      nextRoute.available ? 1 : 0,
      quarantine || nextRoute.quarantined ? 1 : 0,
      nextRoute.failures,
      nextRoute.next_retry_at_ms,
      nextRoute.last_attempt_order,
      claim.route.peer_id,
      claim.lease_expires_at_ms,
      claim.attempt_order,
    );
  }

  private assertValidImage(): void {
    const clock = this.get<ClockRow>(
      `SELECT next_attempt_order FROM player_local_peer_attempt_clock
       WHERE singleton = 1`,
    );
    if (!clock || !positiveAttemptOrder(clock.next_attempt_order)) {
      throw new PeerRouteStoreCorruptError("invalid peer attempt clock");
    }
    const forkPeers = new Set(
      this.all<{ peer_id: string; expected_digest: string; conflicting_digest: string }>(
        `SELECT peer_id, expected_digest, conflicting_digest
         FROM player_local_peer_fork_evidence`,
      ).map((evidence) => {
        if (
          evidence.expected_digest.length === 0 ||
          evidence.conflicting_digest.length === 0 ||
          evidence.expected_digest === evidence.conflicting_digest
        ) {
          throw new PeerRouteStoreCorruptError("invalid fork evidence");
        }
        return evidence.peer_id;
      }),
    );
    for (const route of this.routeRows()) {
      if (
        !endpointValid(route) ||
        !isNonNegativeInteger(route.failures) ||
        !isNonNegativeInteger(route.next_retry_at_ms) ||
        !isNonNegativeInteger(route.last_attempt_order) ||
        route.last_attempt_order >= clock.next_attempt_order ||
        (route.lease_attempt_order !== null &&
          (route.lease_expires_at_ms === null ||
            route.lease_attempt_order <= route.last_attempt_order ||
            route.lease_attempt_order >= clock.next_attempt_order)) ||
        (route.quarantined === 1) !== forkPeers.has(route.peer_id)
      ) {
        throw new PeerRouteStoreCorruptError("invalid peer route image");
      }
    }
  }

  private routeState(row: RouteRow): PeerRouteState {
    return {
      peer_id: row.peer_id,
      available: row.available === 1,
      quarantined: row.quarantined === 1,
      failures: row.failures,
      next_retry_at_ms: row.next_retry_at_ms,
      last_attempt_order: row.last_attempt_order,
    };
  }

  private routeAt(peerId: string): RouteRow | undefined {
    return this.get<RouteRow>(
      `SELECT peer_id, endpoint_url, available, quarantined, failures,
              next_retry_at_ms, last_attempt_order, lease_expires_at_ms,
              lease_attempt_order
       FROM player_local_peer_routes WHERE peer_id = ?`,
      peerId,
    );
  }

  private routeRows(): RouteRow[] {
    return this.all<RouteRow>(
      `SELECT peer_id, endpoint_url, available, quarantined, failures,
              next_retry_at_ms, last_attempt_order, lease_expires_at_ms,
              lease_attempt_order
       FROM player_local_peer_routes ORDER BY peer_id`,
    );
  }

  private transaction<Result>(operation: () => Result): Result {
    this.database.exec("BEGIN IMMEDIATE");
    try {
      const result = operation();
      this.database.exec("COMMIT");
      return result;
    } catch (error) {
      this.database.exec("ROLLBACK");
      throw error;
    }
  }

  private get<Row>(sql: string, ...parameters: SQLInputValue[]): Row | undefined {
    return this.database.prepare(sql).get(...parameters) as Row | undefined;
  }

  private all<Row>(sql: string, ...parameters: SQLInputValue[]): Row[] {
    return this.database.prepare(sql).all(...parameters) as Row[];
  }

  private run(sql: string, ...parameters: SQLInputValue[]): number {
    return Number(this.database.prepare(sql).run(...parameters).changes);
  }
}
