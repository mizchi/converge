// WASM-GC loader for crdt_db

const WASM_PATH = new URL(
  "../../target/wasm-gc/release/build/wasm/wasm.wasm",
  import.meta.url,
);

interface CrdtExports {
  create_doc(peer_id: string): number;
  doc_merge_remote(handle: number, events_json: string): string;
  doc_get_pending(handle: number, known_json: string): string;
  doc_sync_state(handle: number): string;
  doc_insert(
    handle: number,
    tbl: string,
    row_id: string,
    values_json: string,
  ): string;
  doc_update(
    handle: number,
    tbl: string,
    row_id: string,
    col: string,
    value_json: string,
  ): string;
  doc_delete(handle: number, tbl: string, row_id: string): string;
}

let exports: CrdtExports;

export async function loadWasm(): Promise<CrdtExports> {
  if (exports) return exports;

  const bytes = await Deno.readFile(WASM_PATH);
  const module = await WebAssembly.compile(bytes, {
    // @ts-ignore: WASM-GC JS String Builtins proposal
    builtins: ["js-string"],
    // @ts-ignore: WASM-GC imported string constants
    importedStringConstants: "_",
  });
  const instance = await WebAssembly.instantiate(module, {});
  exports = instance.exports as unknown as CrdtExports;
  return exports;
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

export class CrdtServer {
  private handle: number;

  constructor(private wasm: CrdtExports) {
    this.handle = wasm.create_doc("server");
  }

  mergeRemote(events: EventRun[]): MergeOp[] {
    const result = this.wasm.doc_merge_remote(
      this.handle,
      JSON.stringify(events),
    );
    return JSON.parse(result);
  }

  getPending(knownPeers: Record<string, number>): EventRun[] {
    const result = this.wasm.doc_get_pending(
      this.handle,
      JSON.stringify(knownPeers),
    );
    return JSON.parse(result);
  }

  syncState(): SyncState {
    const result = this.wasm.doc_sync_state(this.handle);
    return JSON.parse(result);
  }
}
