/** @module Interface mizchi:converge/converge@0.1.0 **/
export function createDoc(peerId: string): number;
export function docInsert(handle: number, tbl: string, rowId: string, values: Array<KeyValue>): Event;
export function docUpdate(handle: number, tbl: string, rowId: string, col: string, val: Value): Event;
export function docDelete(handle: number, tbl: string, rowId: string): Event;
export function docMergeRemote(handle: number, events: Array<EventRun>): Array<MergeOp>;
export function docGetPending(handle: number, known: Array<PeerVersion>): Array<EventRun>;
export function docSyncState(handle: number): SyncState;
export function ephemeralSet(handle: number, ns: string, key: string, val: Value, timestamp: number): EphemeralEntry;
export function ephemeralGet(handle: number, ns: string, key: string): EphemeralEntry | undefined;
export function ephemeralGetAll(handle: number, ns: string): Array<EphemeralEntry>;
export function ephemeralMerge(handle: number, entries: Array<EphemeralRemoteEntry>): Array<EphemeralRemoteEntry>;
export type Value = ValueValNull | ValueValBool | ValueValInt | ValueValFloat | ValueValStr;
export interface ValueValNull {
  tag: 'val-null',
}
export interface ValueValBool {
  tag: 'val-bool',
  val: boolean,
}
export interface ValueValInt {
  tag: 'val-int',
  val: number,
}
export interface ValueValFloat {
  tag: 'val-float',
  val: number,
}
export interface ValueValStr {
  tag: 'val-str',
  val: string,
}
export interface KeyValue {
  key: string,
  val: Value,
}
export interface EventId {
  peer: string,
  counter: number,
}
export interface InsertOp {
  tbl: string,
  rowId: string,
  values: Array<KeyValue>,
}
export interface UpdateOp {
  tbl: string,
  rowId: string,
  col: string,
  val: Value,
}
export interface DeleteOp {
  tbl: string,
  rowId: string,
}
export type RowOp = RowOpInsert | RowOpUpdate | RowOpDelete;
export interface RowOpInsert {
  tag: 'insert',
  val: InsertOp,
}
export interface RowOpUpdate {
  tag: 'update',
  val: UpdateOp,
}
export interface RowOpDelete {
  tag: 'delete',
  val: DeleteOp,
}
export interface Event {
  id: EventId,
  deps: Array<EventId>,
  lamport: number,
  op: RowOp,
}
export interface EventRun {
  peer: string,
  counterStart: number,
  lamportStart: number,
  deps: Array<EventId>,
  ops: Array<RowOp>,
}
export interface SetCellOp {
  tbl: string,
  rowId: string,
  col: string,
  val: Value,
}
export interface InsertRowOp {
  tbl: string,
  rowId: string,
  values: Array<KeyValue>,
}
export interface DeleteRowOp {
  tbl: string,
  rowId: string,
}
export type MergeOp = MergeOpSetCell | MergeOpInsertRow | MergeOpDeleteRow;
export interface MergeOpSetCell {
  tag: 'set-cell',
  val: SetCellOp,
}
export interface MergeOpInsertRow {
  tag: 'insert-row',
  val: InsertRowOp,
}
export interface MergeOpDeleteRow {
  tag: 'delete-row',
  val: DeleteRowOp,
}
export interface PeerVersion {
  peer: string,
  version: number,
}
export interface SyncState {
  frontier: Array<EventId>,
  versions: Array<PeerVersion>,
}
export interface EphemeralEntry {
  key: string,
  val: Value,
  timestamp: number,
  peer: string,
}
export interface EphemeralRemoteEntry {
  ns: string,
  key: string,
  val: Value,
  timestamp: number,
  peer: string,
}
