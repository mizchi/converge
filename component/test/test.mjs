import { converge } from './gen/converge-component.js';

const {
  createDoc,
  docInsert,
  docUpdate,
  docDelete,
  docMergeRemote,
  docGetPending,
  docSyncState,
  ephemeralSet,
  ephemeralGet,
  ephemeralGetAll,
  ephemeralMerge,
} = converge;

// -- Test 1: create-doc + doc-insert --
console.log("=== Test 1: create-doc + doc-insert ===");
const h = createDoc("peer-A");
console.log("handle:", h);

const ev1 = docInsert(h, "users", "row1", [
  { key: "name", val: { tag: "val-str", val: "Alice" } },
  { key: "age", val: { tag: "val-int", val: 30 } },
]);
console.log("insert event:", JSON.stringify(ev1, null, 2));

// -- Test 2: doc-update --
console.log("\n=== Test 2: doc-update ===");
const ev2 = docUpdate(h, "users", "row1", "age", { tag: "val-int", val: 31 });
console.log("update event:", JSON.stringify(ev2, null, 2));

// -- Test 3: doc-sync-state --
console.log("\n=== Test 3: doc-sync-state ===");
const state = docSyncState(h);
console.log("sync state:", JSON.stringify(state, null, 2));

// -- Test 4: doc-get-pending + doc-merge-remote --
console.log("\n=== Test 4: two-peer sync ===");
const h2 = createDoc("peer-B");
const pending = docGetPending(h, []);
console.log("pending runs:", JSON.stringify(pending, null, 2));

const mergeOps = docMergeRemote(h2, pending);
console.log("merge ops:", JSON.stringify(mergeOps, null, 2));

// -- Test 5: doc-delete --
console.log("\n=== Test 5: doc-delete ===");
const ev3 = docDelete(h, "users", "row1");
console.log("delete event:", JSON.stringify(ev3, null, 2));

// -- Test 6: ephemeral-set + ephemeral-get --
console.log("\n=== Test 6: ephemeral ===");
const entry = ephemeralSet(h, "cursors", "cursor1", { tag: "val-str", val: "x:10,y:20" }, Date.now());
console.log("ephemeral set:", JSON.stringify(entry, null, 2));

const got = ephemeralGet(h, "cursors", "cursor1");
console.log("ephemeral get:", JSON.stringify(got, null, 2));

const all = ephemeralGetAll(h, "cursors");
console.log("ephemeral get-all:", JSON.stringify(all, null, 2));

// -- Test 7: ephemeral-merge --
console.log("\n=== Test 7: ephemeral-merge ===");
const changed = ephemeralMerge(h2, [
  { ns: "cursors", key: "cursor-B", val: { tag: "val-str", val: "x:5,y:5" }, timestamp: Date.now(), peer: "peer-B" },
]);
console.log("ephemeral merge changed:", JSON.stringify(changed, null, 2));

console.log("\n=== All tests passed ===");
