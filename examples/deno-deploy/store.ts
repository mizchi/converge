// Deno KV event store for crdt_db

import type { CrdtServer, EventRun } from "./wasm.ts";

// Deno KV has a 64KB value limit. Split large EventRuns into smaller chunks.
const MAX_OPS_PER_CHUNK = 50;
// Deno KV atomic: max 10 mutations per commit
const MAX_ATOMIC_MUTATIONS = 10;

function splitEventRun(run: EventRun): EventRun[] {
  if (run.ops.length <= MAX_OPS_PER_CHUNK) return [run];
  const chunks: EventRun[] = [];
  for (let i = 0; i < run.ops.length; i += MAX_OPS_PER_CHUNK) {
    chunks.push({
      peer: run.peer,
      counter_start: run.counter_start + i,
      lamport_start: run.lamport_start + i,
      deps: i === 0 ? run.deps : [[run.peer, run.counter_start + i - 1]],
      ops: run.ops.slice(i, i + MAX_OPS_PER_CHUNK),
    });
  }
  return chunks;
}

export class EventStore {
  private kv: Deno.Kv;
  private localVersion = 0;

  constructor(kv: Deno.Kv) {
    this.kv = kv;
  }

  /** Replay all events from KV into WASM doc. Returns event count. */
  async replayAll(crdt: CrdtServer): Promise<number> {
    let count = 0;
    const iter = this.kv.list<EventRun>({ prefix: ["events"] });
    for await (const entry of iter) {
      crdt.mergeRemote([entry.value]);
      count++;
    }
    this.localVersion = count;
    return count;
  }

  /**
   * Check KV version and replay any new events written by other isolates.
   * Returns [replayed count, current KV version].
   */
  async catchUp(crdt: CrdtServer): Promise<[number, number]> {
    const countEntry = await this.kv.get<number>(["meta", "count"]);
    const kvVersion = countEntry.value ?? 0;
    if (kvVersion <= this.localVersion) return [0, kvVersion];

    let replayed = 0;
    const iter = this.kv.list<EventRun>({
      start: ["events", this.localVersion],
      end: ["events", kvVersion],
    });
    for await (const entry of iter) {
      crdt.mergeRemote([entry.value]);
      replayed++;
    }
    this.localVersion = kvVersion;
    return [replayed, kvVersion];
  }

  /**
   * Append events to KV using atomic batches.
   * Takes currentVersion from catchUp to skip redundant KV read.
   */
  async appendEvents(events: EventRun[], currentVersion: number): Promise<void> {
    // Flatten all chunks
    const allChunks: EventRun[] = [];
    for (const event of events) {
      allChunks.push(...splitEventRun(event));
    }

    let idx = currentVersion;
    // Batch into atomic commits (reserve 1 slot for meta in last batch)
    for (let i = 0; i < allChunks.length; i += MAX_ATOMIC_MUTATIONS - 1) {
      const batch = allChunks.slice(i, i + MAX_ATOMIC_MUTATIONS - 1);
      const isLastBatch = i + MAX_ATOMIC_MUTATIONS - 1 >= allChunks.length;
      const op = this.kv.atomic();
      for (const chunk of batch) {
        op.set(["events", idx], chunk);
        idx++;
      }
      if (isLastBatch) {
        op.set(["meta", "count"], idx);
      }
      await op.commit();
    }
    this.localVersion = idx;
  }
}
