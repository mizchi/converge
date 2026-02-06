// WASM loader for crdt_db (Ephemeral API only)

interface CrdtExports {
  create_doc(peer_id: string): number;
  ephemeral_set(handle: number, ns: string, key: string, value_json: string, timestamp: number): string;
  ephemeral_get(handle: number, ns: string, key: string): string;
  ephemeral_get_all(handle: number, ns: string): string;
  ephemeral_merge(handle: number, entries_json: string): string;
}

export interface EphemeralEntry {
  key: string;
  value: unknown;
  timestamp: number;
  peer: string;
}

// Nested entries: { ns: { key: entry } }
export type NsEntries = Record<string, Record<string, EphemeralEntry>>;

let wasm: CrdtExports | null = null;

export async function loadWasm(): Promise<CrdtExports> {
  if (wasm) return wasm;
  const mod = await import("../../../target/js/release/build/wasm/wasm.js");
  wasm = mod as unknown as CrdtExports;
  return wasm;
}

export class EphemeralRelay {
  private handle: number;

  constructor(w: CrdtExports) {
    this.handle = w.create_doc("relay");
  }

  /** Merge incoming entries, return only changed entries */
  merge(entries: NsEntries): NsEntries {
    const result = wasm!.ephemeral_merge(this.handle, JSON.stringify(entries));
    return JSON.parse(result);
  }

  /** Get all entries in a namespace */
  getAll(ns: string): Record<string, EphemeralEntry> {
    const result = wasm!.ephemeral_get_all(this.handle, ns);
    return JSON.parse(result);
  }

  /** Get full snapshot across given namespaces */
  snapshot(namespaces: string[]): NsEntries {
    const result: NsEntries = {};
    for (const ns of namespaces) {
      const entries = this.getAll(ns);
      if (Object.keys(entries).length > 0) {
        result[ns] = entries;
      }
    }
    return result;
  }
}
