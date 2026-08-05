import { describe, expect, it } from "vitest";
import {
  audit_benchmark_make_checkpoint_delivery_authentication,
} from "../../../target/js/release/build/mizchi/converge/x/game_audit/worker/worker.js";
import {
  approveCheckpointWitnessCollection,
  type PublicCheckpointWitnessCollection,
} from "../src/witness-client";

const PRODUCER_SEED =
  "000102030405060708090a0b0c0d0e0f" +
  "101112131415161718191a1b1c1d1e1f";
const WITNESS_SEEDS = [
  "404142434445464748494a4b4c4d4e4f" +
    "505152535455565758595a5b5c5d5e5f",
  "606162636465666768696a6b6c6d6e6f" +
    "707172737475767778797a7b7c7d7e7f",
];
const WITNESS_IDS = ["witness-a", "witness-b"];

function collectionFixture(): {
  collection: PublicCheckpointWitnessCollection;
  expectedApproval: PublicCheckpointWitnessCollection["producer_authentication"]["approvals"][number];
} {
  const statement = {
    boundary: {
      protocol_version: 1,
      purpose: "checkpoint-v1",
      manifest_digest: "manifest-1",
      scope_id: "cf:pvp:peer-client",
      unit_id: "peer-client",
    },
    destination_id: "authority-1",
    epoch: 0,
    previous_checkpoint: "genesis",
    checkpoint_digest: "checkpoint-peer-client",
    canonical_envelope: "canonical-envelope-peer-client",
  };
  const fixture = JSON.parse(
    audit_benchmark_make_checkpoint_delivery_authentication(
      PRODUCER_SEED,
      "checkpoint-producer",
      WITNESS_SEEDS,
      WITNESS_IDS,
      2,
      2,
      statement.boundary.protocol_version,
      statement.boundary.purpose,
      statement.boundary.manifest_digest,
      statement.boundary.scope_id,
      statement.boundary.unit_id,
      statement.destination_id,
      statement.epoch,
      statement.previous_checkpoint,
      statement.checkpoint_digest,
      statement.canonical_envelope,
    ),
  ) as {
    ok: true;
    policy: PublicCheckpointWitnessCollection["authentication_policy"];
    authentication: PublicCheckpointWitnessCollection["producer_authentication"];
  };
  const [expectedApproval] = fixture.authentication.approvals;
  return {
    collection: {
      ok: true,
      collection_id: "collection-peer-client",
      statement,
      producer_authentication: {
        ...fixture.authentication,
        approvals: [],
      },
      authentication_policy: fixture.policy,
      status: "collecting",
      approval_count: 0,
      required_approvals: 2,
      deadline_at: Date.now() + 60_000,
      created_at: Date.now(),
      ready_at: null,
    },
    expectedApproval,
  };
}

describe("checkpoint witness client", () => {
  it("fetches the public collection, signs locally, and submits only the approval", async () => {
    const { collection, expectedApproval } = collectionFixture();
    let submitted: unknown;
    const fetchImpl = async (
      input: string | URL | Request,
      init?: RequestInit,
    ): Promise<Response> => {
      const request = new Request(input, init);
      if (request.method === "GET") return Response.json(collection);
      submitted = await request.json();
      return Response.json(
        { ok: true, decision: "accepted", status: "collecting", approval_count: 1 },
        { status: 202 },
      );
    };

    const result = await approveCheckpointWitnessCollection({
      baseUrl: "https://audit.example",
      mode: "pvp",
      unit: "peer-client",
      collectionId: collection.collection_id,
      witnessId: WITNESS_IDS[0],
      witnessSeedHex: WITNESS_SEEDS[0],
      fetchImpl,
    });

    expect(submitted).toEqual({
      collection_id: collection.collection_id,
      approval: expectedApproval,
    });
    expect(result).toMatchObject({
      httpStatus: 202,
      witnessId: WITNESS_IDS[0],
      witnessKey: expectedApproval.witness_key,
      response: { ok: true, decision: "accepted", approval_count: 1 },
    });
  });

  it("rejects a seed that does not match the provisioned witness before POST", async () => {
    const { collection } = collectionFixture();
    let postCount = 0;
    const fetchImpl = async (
      input: string | URL | Request,
      init?: RequestInit,
    ): Promise<Response> => {
      const request = new Request(input, init);
      if (request.method === "GET") return Response.json(collection);
      postCount += 1;
      return Response.json({ ok: true }, { status: 202 });
    };

    await expect(approveCheckpointWitnessCollection({
      baseUrl: "https://audit.example",
      mode: "pvp",
      unit: "peer-client",
      collectionId: collection.collection_id,
      witnessId: WITNESS_IDS[1],
      witnessSeedHex: WITNESS_SEEDS[0],
      fetchImpl,
    })).rejects.toThrow("witness_seed_does_not_match_roster");
    expect(postCount).toBe(0);
  });
});
