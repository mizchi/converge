// MoonBit JS target loader for crdt_db on Cloudflare Workers
// Lazy-loaded to avoid global scope restrictions (Math.random in module init)

interface CrdtExports {
  create_doc(peer_id: string): number;
  doc_merge_remote(handle: number, events_json: string): string;
  doc_get_pending(handle: number, known_json: string): string;
  doc_sync_state(handle: number): string;
  doc_insert(handle: number, tbl: string, row_id: string, values_json: string): string;
  doc_update(handle: number, tbl: string, row_id: string, col: string, value_json: string): string;
  doc_delete(handle: number, tbl: string, row_id: string): string;
}

export interface EventRun {
  peer: string;
  counter_start: number;
  lamport_start: number;
  deps: [string, number][];
  ops: RowOp[];
}

export type RowOp =
  | { type: "insert"; tbl: string; row_id: string; values: [string, unknown][] }
  | { type: "update"; tbl: string; row_id: string; col: string; value: unknown }
  | { type: "delete"; tbl: string; row_id: string };

export interface MergeOp {
  type: "set_cell" | "insert_row" | "delete_row";
  tbl: string;
  row_id: string;
  col?: string;
  value?: unknown;
  values?: [string, unknown][];
}

export interface SyncState {
  frontier: [string, number][];
  versions: Record<string, number>;
}

let wasm: CrdtExports | null = null;

export async function loadWasm(): Promise<CrdtExports> {
  if (wasm) return wasm;
  // Dynamic import to defer module initialization to handler scope
  const mod = await import("../../../target/js/release/build/wasm/wasm.js");
  wasm = mod as unknown as CrdtExports;
  return wasm;
}

export class CrdtServer {
  private handle: number;

  constructor(w: CrdtExports) {
    this.handle = w.create_doc("server");
  }

  mergeRemote(events: EventRun[]): MergeOp[] {
    const result = wasm!.doc_merge_remote(this.handle, JSON.stringify(events));
    return JSON.parse(result);
  }

  getPending(knownPeers: Record<string, number>): EventRun[] {
    const result = wasm!.doc_get_pending(this.handle, JSON.stringify(knownPeers));
    return JSON.parse(result);
  }

  syncState(): SyncState {
    const result = wasm!.doc_sync_state(this.handle);
    return JSON.parse(result);
  }
}
