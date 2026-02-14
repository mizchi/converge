// converge-component E2E test
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

let passed = 0;
let failed = 0;

function assert(cond, msg) {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    failed++;
  } else {
    console.log(`PASS: ${msg}`);
    passed++;
  }
}

function assertEq(a, b, msg) {
  const as = JSON.stringify(a);
  const bs = JSON.stringify(b);
  if (as !== bs) {
    console.error(`FAIL: ${msg}\n  expected: ${bs}\n  actual:   ${as}`);
    failed++;
  } else {
    console.log(`PASS: ${msg}`);
    passed++;
  }
}

// ===== Test 1: create-doc =====
{
  const h = createDoc("peer-A");
  assert(h === 0, 'createDoc returns handle 0');
}

// ===== Test 2: doc-insert =====
{
  const h = createDoc("peer-ins");
  const ev = docInsert(h, "users", "row1", [
    { key: "name", val: { tag: "val-str", val: "Alice" } },
    { key: "age", val: { tag: "val-int", val: 30 } },
  ]);
  assertEq(ev.id.peer, "peer-ins", 'insert event peer matches');
  assertEq(ev.id.counter, 0, 'insert event counter is 0');
  assert(ev.lamport > 0, 'insert event lamport > 0');
  assertEq(ev.op.tag, "insert", 'insert event op tag is "insert"');
  assertEq(ev.op.val.tbl, "users", 'insert event table is "users"');
  assertEq(ev.op.val.rowId, "row1", 'insert event row-id is "row1"');
  assertEq(ev.op.val.values.length, 2, 'insert event has 2 key-value pairs');
  assertEq(ev.op.val.values[0], { key: "name", val: { tag: "val-str", val: "Alice" } }, 'insert event kv[0] matches');
  assertEq(ev.op.val.values[1], { key: "age", val: { tag: "val-int", val: 30 } }, 'insert event kv[1] matches');
}

// ===== Test 3: doc-update =====
{
  const h = createDoc("peer-upd");
  docInsert(h, "users", "row1", [
    { key: "age", val: { tag: "val-int", val: 30 } },
  ]);
  const ev = docUpdate(h, "users", "row1", "age", { tag: "val-int", val: 31 });
  assertEq(ev.id.peer, "peer-upd", 'update event peer matches');
  assertEq(ev.id.counter, 1, 'update event counter is 1');
  assertEq(ev.op.tag, "update", 'update event op tag is "update"');
  assertEq(ev.op.val.col, "age", 'update event column is "age"');
  assertEq(ev.op.val.val, { tag: "val-int", val: 31 }, 'update event value is 31');
  // deps should include the insert event
  assert(ev.deps.length > 0, 'update event has deps');
  assertEq(ev.deps[0].counter, 0, 'update event depends on counter 0');
}

// ===== Test 4: doc-delete =====
{
  const h = createDoc("peer-del");
  docInsert(h, "users", "row1", [
    { key: "x", val: { tag: "val-int", val: 1 } },
  ]);
  const ev = docDelete(h, "users", "row1");
  assertEq(ev.op.tag, "delete", 'delete event op tag is "delete"');
  assertEq(ev.op.val.tbl, "users", 'delete event table matches');
  assertEq(ev.op.val.rowId, "row1", 'delete event row-id matches');
}

// ===== Test 5: doc-sync-state =====
{
  const h = createDoc("peer-sync");
  docInsert(h, "t", "r1", [{ key: "k", val: { tag: "val-null" } }]);
  docUpdate(h, "t", "r1", "k", { tag: "val-int", val: 42 });
  const state = docSyncState(h);
  assert(state.frontier.length > 0, 'sync state has frontier');
  assertEq(state.frontier[0].peer, "peer-sync", 'frontier peer matches');
  assert(state.versions.length > 0, 'sync state has versions');
  assertEq(state.versions[0].peer, "peer-sync", 'version peer matches');
  assert(state.versions[0].version >= 1, 'version >= 1');
}

// ===== Test 6: two-peer sync via get-pending + merge-remote =====
{
  const hA = createDoc("peer-A-sync");
  docInsert(hA, "items", "i1", [
    { key: "name", val: { tag: "val-str", val: "Widget" } },
    { key: "qty", val: { tag: "val-int", val: 5 } },
  ]);
  docUpdate(hA, "items", "i1", "qty", { tag: "val-int", val: 10 });

  // Get pending events from peer-A (no known peers)
  const pending = docGetPending(hA, []);
  assert(pending.length > 0, 'pending runs not empty');
  assertEq(pending[0].peer, "peer-A-sync", 'pending run peer matches');
  assert(pending[0].ops.length >= 2, 'pending run has >= 2 ops');

  // Merge into peer-B
  const hB = createDoc("peer-B-sync");
  const mergeOps = docMergeRemote(hB, pending);
  assert(mergeOps.length > 0, 'merge produces operations');

  // First merge op should be insert-row
  assertEq(mergeOps[0].tag, "insert-row", 'first merge op is insert-row');
  assertEq(mergeOps[0].val.tbl, "items", 'merge insert-row table matches');
  assertEq(mergeOps[0].val.rowId, "i1", 'merge insert-row row-id matches');

  // Second should be set-cell for qty update
  assertEq(mergeOps[1].tag, "set-cell", 'second merge op is set-cell');
  assertEq(mergeOps[1].val.col, "qty", 'set-cell column is "qty"');
  assertEq(mergeOps[1].val.val, { tag: "val-int", val: 10 }, 'set-cell value is 10');

  // Peer-B sync state should now include peer-A
  const stateB = docSyncState(hB);
  const peerNames = stateB.versions.map(v => v.peer).sort();
  assert(peerNames.includes("peer-A-sync"), 'peer-B knows about peer-A');
}

// ===== Test 7: value type roundtrips =====
{
  const h = createDoc("peer-types");
  // null
  docInsert(h, "t", "r-null", [{ key: "v", val: { tag: "val-null" } }]);
  // bool
  docInsert(h, "t", "r-bool", [{ key: "v", val: { tag: "val-bool", val: true } }]);
  // int
  docInsert(h, "t", "r-int", [{ key: "v", val: { tag: "val-int", val: -42 } }]);
  // float
  docInsert(h, "t", "r-float", [{ key: "v", val: { tag: "val-float", val: 3.14 } }]);
  // string
  docInsert(h, "t", "r-str", [{ key: "v", val: { tag: "val-str", val: "hello" } }]);

  // Verify via get-pending that all values survive the component boundary
  const pending = docGetPending(h, []);
  assert(pending.length > 0, 'value type test has pending events');
  const ops = pending[0].ops;
  assert(ops.length === 5, 'value type test has 5 ops');

  // Check each value roundtripped correctly
  assertEq(ops[0].val.values[0].val, { tag: "val-null" }, 'null value roundtrips through component');
  assertEq(ops[1].val.values[0].val, { tag: "val-bool", val: true }, 'bool value roundtrips through component');
  assertEq(ops[2].val.values[0].val, { tag: "val-int", val: -42 }, 'int value roundtrips through component');
  assertEq(ops[3].val.values[0].val, { tag: "val-float", val: 3.14 }, 'float value roundtrips through component');
  assertEq(ops[4].val.values[0].val, { tag: "val-str", val: "hello" }, 'string value roundtrips through component');
}

// ===== Test 8: multiple key-value insert =====
{
  const h = createDoc("peer-multi");
  const ev = docInsert(h, "profile", "p1", [
    { key: "first", val: { tag: "val-str", val: "John" } },
    { key: "last", val: { tag: "val-str", val: "Doe" } },
    { key: "active", val: { tag: "val-bool", val: true } },
    { key: "score", val: { tag: "val-float", val: 99.5 } },
  ]);
  assertEq(ev.op.val.values.length, 4, 'multi-kv insert has 4 values');
  assertEq(ev.op.val.values[0].key, "first", 'multi-kv key[0] is "first"');
  assertEq(ev.op.val.values[3].val, { tag: "val-float", val: 99.5 }, 'multi-kv val[3] is float 99.5');
}

// ===== Test 9: ephemeral set + get =====
{
  const h = createDoc("peer-eph");
  const ts = 1000000.0;
  const entry = ephemeralSet(h, "cursors", "c1", { tag: "val-str", val: "x:10,y:20" }, ts);
  assertEq(entry.key, "c1", 'ephemeral set returns correct key');
  assertEq(entry.val, { tag: "val-str", val: "x:10,y:20" }, 'ephemeral set returns correct value');
  assertEq(entry.timestamp, ts, 'ephemeral set returns correct timestamp');
  assertEq(entry.peer, "peer-eph", 'ephemeral set returns correct peer');

  const got = ephemeralGet(h, "cursors", "c1");
  assert(got !== undefined, 'ephemeral get returns Some');
  assertEq(got.key, "c1", 'ephemeral get key matches');
  assertEq(got.val, { tag: "val-str", val: "x:10,y:20" }, 'ephemeral get value matches');

  const missing = ephemeralGet(h, "cursors", "nonexistent");
  assertEq(missing, undefined, 'ephemeral get missing key returns undefined');
}

// ===== Test 10: ephemeral get-all =====
{
  const h = createDoc("peer-eall");
  ephemeralSet(h, "ns1", "k1", { tag: "val-int", val: 1 }, 100.0);
  ephemeralSet(h, "ns1", "k2", { tag: "val-int", val: 2 }, 200.0);
  ephemeralSet(h, "ns2", "k3", { tag: "val-int", val: 3 }, 300.0);

  const all1 = ephemeralGetAll(h, "ns1");
  assertEq(all1.length, 2, 'ephemeral get-all ns1 has 2 entries');

  const all2 = ephemeralGetAll(h, "ns2");
  assertEq(all2.length, 1, 'ephemeral get-all ns2 has 1 entry');

  const allEmpty = ephemeralGetAll(h, "ns-missing");
  assertEq(allEmpty.length, 0, 'ephemeral get-all missing ns returns empty');
}

// ===== Test 11: ephemeral merge =====
{
  const h = createDoc("peer-emerge");
  const ts = 5000.0;
  const changed = ephemeralMerge(h, [
    { ns: "cursors", key: "remote-k", val: { tag: "val-str", val: "pos" }, timestamp: ts, peer: "remote-peer" },
  ]);
  assert(changed.length > 0, 'ephemeral merge returns changed entries');
  assertEq(changed[0].key, "remote-k", 'ephemeral merge changed key matches');
  assertEq(changed[0].peer, "remote-peer", 'ephemeral merge changed peer matches');

  // Verify the merged entry is visible via get
  const got = ephemeralGet(h, "cursors", "remote-k");
  assert(got !== undefined, 'merged ephemeral entry is gettable');
  assertEq(got.val, { tag: "val-str", val: "pos" }, 'merged ephemeral value matches');
}

// ===== Test 12: event deps chain =====
{
  const h = createDoc("peer-deps");
  const ev1 = docInsert(h, "t", "r1", [{ key: "a", val: { tag: "val-int", val: 1 } }]);
  assertEq(ev1.deps.length, 0, 'first event has no deps');

  const ev2 = docUpdate(h, "t", "r1", "a", { tag: "val-int", val: 2 });
  assertEq(ev2.deps.length, 1, 'second event has 1 dep');
  assertEq(ev2.deps[0].counter, 0, 'second event depends on counter 0');

  const ev3 = docInsert(h, "t", "r2", [{ key: "b", val: { tag: "val-int", val: 3 } }]);
  assertEq(ev3.deps.length, 1, 'third event has 1 dep');
  assertEq(ev3.deps[0].counter, 1, 'third event depends on counter 1');
}

// ===== Test 13: merge-remote delete sync =====
{
  const hA = createDoc("peer-delsync-A");
  docInsert(hA, "t", "r1", [{ key: "x", val: { tag: "val-int", val: 1 } }]);
  docDelete(hA, "t", "r1");

  const pending = docGetPending(hA, []);
  const hB = createDoc("peer-delsync-B");
  const mergeOps = docMergeRemote(hB, pending);

  // Merge should include delete-row (insert-row may be optimized away)
  assert(mergeOps.length > 0, 'delete sync produces merge ops');
  const tags = mergeOps.map(op => op.tag);
  assert(tags.includes("delete-row"), 'delete sync includes delete-row');
}

// ===== Summary =====
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
