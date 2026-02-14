const i64ToF64I = new BigInt64Array(1);
const i64ToF64F = new Float64Array(i64ToF64I.buffer);

let dv = new DataView(new ArrayBuffer());
const dataView = mem => dv.buffer === mem.buffer ? dv : dv = new DataView(mem.buffer);

const f64ToI64 = f => (i64ToF64F[0] = f, i64ToF64I[0]);

function toInt32(val) {
  return val >> 0;
}

function toUint32(val) {
  return val >>> 0;
}

const utf8Decoder = new TextDecoder();

const utf8Encoder = new TextEncoder();
let utf8EncodedLen = 0;
function utf8Encode(s, realloc, memory) {
  if (typeof s !== 'string') throw new TypeError('expected a string');
  if (s.length === 0) {
    utf8EncodedLen = 0;
    return 1;
  }
  let buf = utf8Encoder.encode(s);
  let ptr = realloc(0, 0, 1, buf.length);
  new Uint8Array(memory.buffer).set(buf, ptr);
  utf8EncodedLen = buf.length;
  return ptr;
}

let NEXT_TASK_ID = 0n;
function startCurrentTask(componentIdx, isAsync, entryFnName) {
  _debugLog('[startCurrentTask()] args', { componentIdx, isAsync });
  if (componentIdx === undefined || componentIdx === null) {
    throw new Error('missing/invalid component instance index while starting task');
  }
  const tasks = ASYNC_TASKS_BY_COMPONENT_IDX.get(componentIdx);
  
  const nextId = ++NEXT_TASK_ID;
  const newTask = new AsyncTask({ id: nextId, componentIdx, isAsync, entryFnName });
  const newTaskMeta = { id: nextId, componentIdx, task: newTask };
  
  ASYNC_CURRENT_TASK_IDS.push(nextId);
  ASYNC_CURRENT_COMPONENT_IDXS.push(componentIdx);
  
  if (!tasks) {
    ASYNC_TASKS_BY_COMPONENT_IDX.set(componentIdx, [newTaskMeta]);
    return nextId;
  } else {
    tasks.push(newTaskMeta);
  }
  
  return nextId;
}

function endCurrentTask(componentIdx, taskId) {
  _debugLog('[endCurrentTask()] args', { componentIdx });
  componentIdx ??= ASYNC_CURRENT_COMPONENT_IDXS.at(-1);
  taskId ??= ASYNC_CURRENT_TASK_IDS.at(-1);
  if (componentIdx === undefined || componentIdx === null) {
    throw new Error('missing/invalid component instance index while ending current task');
  }
  const tasks = ASYNC_TASKS_BY_COMPONENT_IDX.get(componentIdx);
  if (!tasks || !Array.isArray(tasks)) {
    throw new Error('missing/invalid tasks for component instance while ending task');
  }
  if (tasks.length == 0) {
    throw new Error('no current task(s) for component instance while ending task');
  }
  
  if (taskId) {
    const last = tasks[tasks.length - 1];
    if (last.id !== taskId) {
      throw new Error('current task does not match expected task ID');
    }
  }
  
  ASYNC_CURRENT_TASK_IDS.pop();
  ASYNC_CURRENT_COMPONENT_IDXS.pop();
  
  return tasks.pop();
}
const ASYNC_TASKS_BY_COMPONENT_IDX = new Map();
const ASYNC_CURRENT_TASK_IDS = [];
const ASYNC_CURRENT_COMPONENT_IDXS = [];

class AsyncTask {
  static State = {
    INITIAL: 'initial',
    CANCELLED: 'cancelled',
    CANCEL_PENDING: 'cancel-pending',
    CANCEL_DELIVERED: 'cancel-delivered',
    RESOLVED: 'resolved',
  }
  
  static BlockResult = {
    CANCELLED: 'block.cancelled',
    NOT_CANCELLED: 'block.not-cancelled',
  }
  
  #id;
  #componentIdx;
  #state;
  #isAsync;
  #onResolve = null;
  #entryFnName = null;
  #subtasks = [];
  #completionPromise = null;
  
  cancelled = false;
  requested = false;
  alwaysTaskReturn = false;
  
  returnCalls =  0;
  storage = [0, 0];
  borrowedHandles = {};
  
  awaitableResume = null;
  awaitableCancel = null;
  
  
  constructor(opts) {
    if (opts?.id === undefined) { throw new TypeError('missing task ID during task creation'); }
    this.#id = opts.id;
    if (opts?.componentIdx === undefined) {
      throw new TypeError('missing component id during task creation');
    }
    this.#componentIdx = opts.componentIdx;
    this.#state = AsyncTask.State.INITIAL;
    this.#isAsync = opts?.isAsync ?? false;
    this.#entryFnName = opts.entryFnName;
    
    const {
      promise: completionPromise,
      resolve: resolveCompletionPromise,
      reject: rejectCompletionPromise,
    } = Promise.withResolvers();
    this.#completionPromise = completionPromise;
    
    this.#onResolve = (results) => {
      // TODO: handle external facing cancellation (should likely be a rejection)
      resolveCompletionPromise(results);
    }
  }
  
  taskState() { return this.#state.slice(); }
  id() { return this.#id; }
  componentIdx() { return this.#componentIdx; }
  isAsync() { return this.#isAsync; }
  entryFnName() { return this.#entryFnName; }
  completionPromise() { return this.#completionPromise; }
  
  mayEnter(task) {
    const cstate = getOrCreateAsyncState(this.#componentIdx);
    if (!cstate.backpressure) {
      _debugLog('[AsyncTask#mayEnter()] disallowed due to backpressure', { taskID: this.#id });
      return false;
    }
    if (!cstate.callingSyncImport()) {
      _debugLog('[AsyncTask#mayEnter()] disallowed due to sync import call', { taskID: this.#id });
      return false;
    }
    const callingSyncExportWithSyncPending = cstate.callingSyncExport && !task.isAsync;
    if (!callingSyncExportWithSyncPending) {
      _debugLog('[AsyncTask#mayEnter()] disallowed due to sync export w/ sync pending', { taskID: this.#id });
      return false;
    }
    return true;
  }
  
  async enter() {
    _debugLog('[AsyncTask#enter()] args', { taskID: this.#id });
    
    // TODO: assert scheduler locked
    // TODO: trap if on the stack
    
    const cstate = getOrCreateAsyncState(this.#componentIdx);
    
    let mayNotEnter = !this.mayEnter(this);
    const componentHasPendingTasks = cstate.pendingTasks > 0;
    if (mayNotEnter || componentHasPendingTasks) {
      throw new Error('in enter()'); // TODO: remove
      cstate.pendingTasks.set(this.#id, new Awaitable(new Promise()));
      
      const blockResult = await this.onBlock(awaitable);
      if (blockResult) {
        // TODO: find this pending task in the component
        const pendingTask = cstate.pendingTasks.get(this.#id);
        if (!pendingTask) {
          throw new Error('pending task [' + this.#id + '] not found for component instance');
        }
        cstate.pendingTasks.remove(this.#id);
        this.#onResolve(new Error('failed enter'));
        return false;
      }
      
      mayNotEnter = !this.mayEnter(this);
      if (!mayNotEnter || !cstate.startPendingTask) {
        throw new Error('invalid component entrance/pending task resolution');
      }
      cstate.startPendingTask = false;
    }
    
    if (!this.isAsync) { cstate.callingSyncExport = true; }
    
    return true;
  }
  
  async waitForEvent(opts) {
    const { waitableSetRep, isAsync } = opts;
    _debugLog('[AsyncTask#waitForEvent()] args', { taskID: this.#id, waitableSetRep, isAsync });
    
    if (this.#isAsync !== isAsync) {
      throw new Error('async waitForEvent called on non-async task');
    }
    
    if (this.status === AsyncTask.State.CANCEL_PENDING) {
      this.#state = AsyncTask.State.CANCEL_DELIVERED;
      return {
        code: ASYNC_EVENT_CODE.TASK_CANCELLED,
      };
    }
    
    const state = getOrCreateAsyncState(this.#componentIdx);
    const waitableSet = state.waitableSets.get(waitableSetRep);
    if (!waitableSet) { throw new Error('missing/invalid waitable set'); }
    
    waitableSet.numWaiting += 1;
    let event = null;
    
    while (event == null) {
      const awaitable = new Awaitable(waitableSet.getPendingEvent());
      const waited = await this.blockOn({ awaitable, isAsync, isCancellable: true });
      if (waited) {
        if (this.#state !== AsyncTask.State.INITIAL) {
          throw new Error('task should be in initial state found [' + this.#state + ']');
        }
        this.#state = AsyncTask.State.CANCELLED;
        return {
          code: ASYNC_EVENT_CODE.TASK_CANCELLED,
        };
      }
      
      event = waitableSet.poll();
    }
    
    waitableSet.numWaiting -= 1;
    return event;
  }
  
  waitForEventSync(opts) {
    throw new Error('AsyncTask#yieldSync() not implemented')
  }
  
  async pollForEvent(opts) {
    const { waitableSetRep, isAsync } = opts;
    _debugLog('[AsyncTask#pollForEvent()] args', { taskID: this.#id, waitableSetRep, isAsync });
    
    if (this.#isAsync !== isAsync) {
      throw new Error('async pollForEvent called on non-async task');
    }
    
    throw new Error('AsyncTask#pollForEvent() not implemented');
  }
  
  pollForEventSync(opts) {
    throw new Error('AsyncTask#yieldSync() not implemented')
  }
  
  async blockOn(opts) {
    const { awaitable, isCancellable, forCallback } = opts;
    _debugLog('[AsyncTask#blockOn()] args', { taskID: this.#id, awaitable, isCancellable, forCallback });
    
    if (awaitable.resolved() && !ASYNC_DETERMINISM && _coinFlip()) {
      return AsyncTask.BlockResult.NOT_CANCELLED;
    }
    
    const cstate = getOrCreateAsyncState(this.#componentIdx);
    if (forCallback) { cstate.exclusiveRelease(); }
    
    let cancelled = await this.onBlock(awaitable);
    if (cancelled === AsyncTask.BlockResult.CANCELLED && !isCancellable) {
      const secondCancel = await this.onBlock(awaitable);
      if (secondCancel !== AsyncTask.BlockResult.NOT_CANCELLED) {
        throw new Error('uncancellable task was canceled despite second onBlock()');
      }
    }
    
    if (forCallback) {
      const acquired = new Awaitable(cstate.exclusiveLock());
      cancelled = await this.onBlock(acquired);
      if (cancelled === AsyncTask.BlockResult.CANCELLED) {
        const secondCancel = await this.onBlock(acquired);
        if (secondCancel !== AsyncTask.BlockResult.NOT_CANCELLED) {
          throw new Error('uncancellable callback task was canceled despite second onBlock()');
        }
      }
    }
    
    if (cancelled === AsyncTask.BlockResult.CANCELLED) {
      if (this.#state !== AsyncTask.State.INITIAL) {
        throw new Error('cancelled task is not at initial state');
      }
      if (isCancellable) {
        this.#state = AsyncTask.State.CANCELLED;
        return AsyncTask.BlockResult.CANCELLED;
      } else {
        this.#state = AsyncTask.State.CANCEL_PENDING;
        return AsyncTask.BlockResult.NOT_CANCELLED;
      }
    }
    
    return AsyncTask.BlockResult.NOT_CANCELLED;
  }
  
  async onBlock(awaitable) {
    _debugLog('[AsyncTask#onBlock()] args', { taskID: this.#id, awaitable });
    if (!(awaitable instanceof Awaitable)) {
      throw new Error('invalid awaitable during onBlock');
    }
    
    // Build a promise that this task can await on which resolves when it is awoken
    const { promise, resolve, reject } = Promise.withResolvers();
    this.awaitableResume = () => {
      _debugLog('[AsyncTask] resuming after onBlock', { taskID: this.#id });
      resolve();
    };
    this.awaitableCancel = (err) => {
      _debugLog('[AsyncTask] rejecting after onBlock', { taskID: this.#id, err });
      reject(err);
    };
    
    // Park this task/execution to be handled later
    const state = getOrCreateAsyncState(this.#componentIdx);
    state.parkTaskOnAwaitable({ awaitable, task: this });
    
    try {
      await promise;
      return AsyncTask.BlockResult.NOT_CANCELLED;
    } catch (err) {
      // rejection means task cancellation
      return AsyncTask.BlockResult.CANCELLED;
    }
  }
  
  async asyncOnBlock(awaitable) {
    _debugLog('[AsyncTask#asyncOnBlock()] args', { taskID: this.#id, awaitable });
    if (!(awaitable instanceof Awaitable)) {
      throw new Error('invalid awaitable during onBlock');
    }
    // TODO: watch for waitable AND cancellation
    // TODO: if it WAS cancelled:
    // - return true
    // - only once per subtask
    // - do not wait on the scheduler
    // - control flow should go to the subtask (only once)
    // - Once subtask blocks/resolves, reqlinquishControl() will tehn resolve request_cancel_end (without scheduler lock release)
    // - control flow goes back to request_cancel
    //
    // Subtask cancellation should work similarly to an async import call -- runs sync up until
    // the subtask blocks or resolves
    //
    throw new Error('AsyncTask#asyncOnBlock() not yet implemented');
  }
  
  async yield(opts) {
    const { isCancellable, forCallback } = opts;
    _debugLog('[AsyncTask#yield()] args', { taskID: this.#id, isCancellable, forCallback });
    
    if (isCancellable && this.status === AsyncTask.State.CANCEL_PENDING) {
      this.#state = AsyncTask.State.CANCELLED;
      return {
        code: ASYNC_EVENT_CODE.TASK_CANCELLED,
        payload: [0, 0],
      };
    }
    
    // TODO: Awaitables need to *always* trigger the parking mechanism when they're done...?
    // TODO: Component async state should remember which awaitables are done and work to clear tasks waiting
    
    const blockResult = await this.blockOn({
      awaitable: new Awaitable(new Promise(resolve => setTimeout(resolve, 0))),
      isCancellable,
      forCallback,
    });
    
    if (blockResult === AsyncTask.BlockResult.CANCELLED) {
      if (this.#state !== AsyncTask.State.INITIAL) {
        throw new Error('task should be in initial state found [' + this.#state + ']');
      }
      this.#state = AsyncTask.State.CANCELLED;
      return {
        code: ASYNC_EVENT_CODE.TASK_CANCELLED,
        payload: [0, 0],
      };
    }
    
    return {
      code: ASYNC_EVENT_CODE.NONE,
      payload: [0, 0],
    };
  }
  
  yieldSync(opts) {
    throw new Error('AsyncTask#yieldSync() not implemented')
  }
  
  cancel() {
    _debugLog('[AsyncTask#cancel()] args', { });
    if (!this.taskState() !== AsyncTask.State.CANCEL_DELIVERED) {
      throw new Error('invalid task state for cancellation');
    }
    if (this.borrowedHandles.length > 0) { throw new Error('task still has borrow handles'); }
    
    this.#onResolve(new Error('cancelled'));
    this.#state = AsyncTask.State.RESOLVED;
  }
  
  resolve(results) {
    _debugLog('[AsyncTask#resolve()] args', { results });
    if (this.#state === AsyncTask.State.RESOLVED) {
      throw new Error('task is already resolved');
    }
    if (this.borrowedHandles.length > 0) { throw new Error('task still has borrow handles'); }
    this.#onResolve(results.length === 1 ? results[0] : results);
    this.#state = AsyncTask.State.RESOLVED;
  }
  
  exit() {
    _debugLog('[AsyncTask#exit()] args', { });
    
    // TODO: ensure there is only one task at a time (scheduler.lock() functionality)
    if (this.#state !== AsyncTask.State.RESOLVED) {
      throw new Error('task exited without resolution');
    }
    if (this.borrowedHandles > 0) {
      throw new Error('task exited without clearing borrowed handles');
    }
    
    const state = getOrCreateAsyncState(this.#componentIdx);
    if (!state) { throw new Error('missing async state for component [' + this.#componentIdx + ']'); }
    if (!this.#isAsync && !state.inSyncExportCall) {
      throw new Error('sync task must be run from components known to be in a sync export call');
    }
    state.inSyncExportCall = false;
    
    this.startPendingTask();
  }
  
  startPendingTask(args) {
    _debugLog('[AsyncTask#startPendingTask()] args', args);
    throw new Error('AsyncTask#startPendingTask() not implemented');
  }
  
  createSubtask(args) {
    _debugLog('[AsyncTask#createSubtask()] args', args);
    const newSubtask = new AsyncSubtask({
      componentIdx: this.componentIdx(),
      taskID: this.id(),
      memoryIdx: args?.memoryIdx,
    });
    this.#subtasks.push(newSubtask);
    return newSubtask;
  }
  
  currentSubtask() {
    _debugLog('[AsyncTask#currentSubtask()]');
    if (this.#subtasks.length === 0) { throw new Error('no current subtask'); }
    return this.#subtasks.at(-1);
  }
  
  endCurrentSubtask() {
    _debugLog('[AsyncTask#endCurrentSubtask()]');
    if (this.#subtasks.length === 0) { throw new Error('cannot end current subtask: no current subtask'); }
    const subtask = this.#subtasks.pop();
    subtask.drop();
    return subtask;
  }
}

function unpackCallbackResult(result) {
  _debugLog('[unpackCallbackResult()] args', { result });
  if (!(_typeCheckValidI32(result))) { throw new Error('invalid callback return value [' + result + '], not a valid i32'); }
  const eventCode = result & 0xF;
  if (eventCode < 0 || eventCode > 3) {
    throw new Error('invalid async return value [' + eventCode + '], outside callback code range');
  }
  if (result < 0 || result >= 2**32) { throw new Error('invalid callback result'); }
  // TODO: table max length check?
  const waitableSetIdx = result >> 4;
  return [eventCode, waitableSetIdx];
}
const ASYNC_STATE = new Map();

function getOrCreateAsyncState(componentIdx, init) {
  if (!ASYNC_STATE.has(componentIdx)) {
    ASYNC_STATE.set(componentIdx, new ComponentAsyncState());
  }
  return ASYNC_STATE.get(componentIdx);
}

class ComponentAsyncState {
  #callingAsyncImport = false;
  #syncImportWait = Promise.withResolvers();
  #lock = null;
  
  mayLeave = true;
  waitableSets = new RepTable();
  waitables = new RepTable();
  
  #parkedTasks = new Map();
  
  callingSyncImport(val) {
    if (val === undefined) { return this.#callingAsyncImport; }
    if (typeof val !== 'boolean') { throw new TypeError('invalid setting for async import'); }
    const prev = this.#callingAsyncImport;
    this.#callingAsyncImport = val;
    if (prev === true && this.#callingAsyncImport === false) {
      this.#notifySyncImportEnd();
    }
  }
  
  #notifySyncImportEnd() {
    const existing = this.#syncImportWait;
    this.#syncImportWait = Promise.withResolvers();
    existing.resolve();
  }
  
  async waitForSyncImportCallEnd() {
    await this.#syncImportWait.promise;
  }
  
  parkTaskOnAwaitable(args) {
    if (!args.awaitable) { throw new TypeError('missing awaitable when trying to park'); }
    if (!args.task) { throw new TypeError('missing task when trying to park'); }
    const { awaitable, task } = args;
    
    let taskList = this.#parkedTasks.get(awaitable.id());
    if (!taskList) {
      taskList = [];
      this.#parkedTasks.set(awaitable.id(), taskList);
    }
    taskList.push(task);
    
    this.wakeNextTaskForAwaitable(awaitable);
  }
  
  wakeNextTaskForAwaitable(awaitable) {
    if (!awaitable) { throw new TypeError('missing awaitable when waking next task'); }
    const awaitableID = awaitable.id();
    
    const taskList = this.#parkedTasks.get(awaitableID);
    if (!taskList || taskList.length === 0) {
      _debugLog('[ComponentAsyncState] no tasks waiting for awaitable', { awaitableID: awaitable.id() });
      return;
    }
    
    let task = taskList.shift(); // todo(perf)
    if (!task) { throw new Error('no task in parked list despite previous check'); }
    
    if (!task.awaitableResume) {
      throw new Error('task ready due to awaitable is missing resume', { taskID: task.id(), awaitableID });
    }
    task.awaitableResume();
  }
  
  async exclusiveLock() {  // TODO: use atomics
  if (this.#lock === null) {
    this.#lock = { ticket: 0n };
  }
  
  // Take a ticket for the next valid usage
  const ticket = ++this.#lock.ticket;
  
  _debugLog('[ComponentAsyncState#exclusiveLock()] locking', {
    currentTicket: ticket - 1n,
    ticket
  });
  
  // If there is an active promise, then wait for it
  let finishedTicket;
  while (this.#lock.promise) {
    finishedTicket = await this.#lock.promise;
    if (finishedTicket === ticket - 1n) { break; }
  }
  
  const { promise, resolve } = Promise.withResolvers();
  this.#lock = {
    ticket,
    promise,
    resolve,
  };
  
  return this.#lock.promise;
}

exclusiveRelease() {
  _debugLog('[ComponentAsyncState#exclusiveRelease()] releasing', {
    currentTicket: this.#lock === null ? 'none' : this.#lock.ticket,
  });
  
  if (this.#lock === null) { return; }
  
  const existingLock = this.#lock;
  this.#lock = null;
  existingLock.resolve(existingLock.ticket);
}

isExclusivelyLocked() { return this.#lock !== null; }

}

function prepareCall(memoryIdx) {
  _debugLog('[prepareCall()] args', { memoryIdx });
  
  const taskMeta = getCurrentTask(ASYNC_CURRENT_COMPONENT_IDXS.at(-1), ASYNC_CURRENT_TASK_IDS.at(-1));
  if (!taskMeta) { throw new Error('invalid/missing current async task meta during prepare call'); }
  
  const task = taskMeta.task;
  if (!task) { throw new Error('unexpectedly missing task in task meta during prepare call'); }
  
  const state = getOrCreateAsyncState(task.componentIdx());
  if (!state) {
    throw new Error('invalid/missing async state for component instance [' + componentInstanceID + ']');
  }
  
  const subtask = task.createSubtask({
    memoryIdx,
  });
  
}

function asyncStartCall(callbackIdx, postReturnIdx) {
  _debugLog('[asyncStartCall()] args', { callbackIdx, postReturnIdx });
  
  const taskMeta = getCurrentTask(ASYNC_CURRENT_COMPONENT_IDXS.at(-1), ASYNC_CURRENT_TASK_IDS.at(-1));
  if (!taskMeta) { throw new Error('invalid/missing current async task meta during prepare call'); }
  
  const task = taskMeta.task;
  if (!task) { throw new Error('unexpectedly missing task in task meta during prepare call'); }
  
  const subtask = task.currentSubtask();
  if (!subtask) { throw new Error('invalid/missing subtask during async start call'); }
  
  return Number(subtask.waitableRep()) << 4 | subtask.getStateNumber();
}

function syncStartCall(callbackIdx) {
  _debugLog('[syncStartCall()] args', { callbackIdx });
}

if (!Promise.withResolvers) {
  Promise.withResolvers = () => {
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => {
      resolve = res;
      reject = rej;
    });
    return { promise, resolve, reject };
  };
}

const _debugLog = (...args) => {
  if (!globalThis?.process?.env?.JCO_DEBUG) { return; }
  console.debug(...args);
}
const ASYNC_DETERMINISM = 'random';
const _coinFlip = () => { return Math.random() > 0.5; };
const I32_MAX = 2_147_483_647;
const I32_MIN = -2_147_483_648;
const _typeCheckValidI32 = (n) => typeof n === 'number' && n >= I32_MIN && n <= I32_MAX;

const isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
let _fs;
async function fetchCompile (url) {
  if (isNode) {
    _fs = _fs || await import('node:fs/promises');
    return WebAssembly.compile(await _fs.readFile(url));
  }
  return fetch(url).then(WebAssembly.compileStreaming);
}

class RepTable {
  #data = [0, null];
  
  insert(val) {
    _debugLog('[RepTable#insert()] args', { val });
    const freeIdx = this.#data[0];
    if (freeIdx === 0) {
      this.#data.push(val);
      this.#data.push(null);
      return (this.#data.length >> 1) - 1;
    }
    this.#data[0] = this.#data[freeIdx << 1];
    const placementIdx = freeIdx << 1;
    this.#data[placementIdx] = val;
    this.#data[placementIdx + 1] = null;
    return freeIdx;
  }
  
  get(rep) {
    _debugLog('[RepTable#get()] args', { rep });
    const baseIdx = rep << 1;
    const val = this.#data[baseIdx];
    return val;
  }
  
  contains(rep) {
    _debugLog('[RepTable#contains()] args', { rep });
    const baseIdx = rep << 1;
    return !!this.#data[baseIdx];
  }
  
  remove(rep) {
    _debugLog('[RepTable#remove()] args', { rep });
    if (this.#data.length === 2) { throw new Error('invalid'); }
    
    const baseIdx = rep << 1;
    const val = this.#data[baseIdx];
    if (val === 0) { throw new Error('invalid resource rep (cannot be 0)'); }
    
    this.#data[baseIdx] = this.#data[0];
    this.#data[0] = rep;
    
    return val;
  }
  
  clear() {
    _debugLog('[RepTable#clear()] args', { rep });
    this.#data = [0, null];
  }
}

function throwInvalidBool() {
  throw new TypeError('invalid variant discriminant for bool');
}

const instantiateCore = WebAssembly.instantiate;


let exports0;
let memory0;
let realloc0;
let converge010CreateDoc;

function createDoc(arg0) {
  var ptr0 = utf8Encode(arg0, realloc0, memory0);
  var len0 = utf8EncodedLen;
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="create-doc"][Instruction::CallWasm] enter', {
    funcName: 'create-doc',
    paramCount: 2,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010CreateDoc');
  const ret = converge010CreateDoc(ptr0, len0);
  endCurrentTask(0);
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="create-doc"][Instruction::Return]', {
    funcName: 'create-doc',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return ret >>> 0;
}
let converge010DocInsert;

function docInsert(arg0, arg1, arg2, arg3) {
  var ptr0 = utf8Encode(arg1, realloc0, memory0);
  var len0 = utf8EncodedLen;
  var ptr1 = utf8Encode(arg2, realloc0, memory0);
  var len1 = utf8EncodedLen;
  var vec6 = arg3;
  var len6 = vec6.length;
  var result6 = realloc0(0, 0, 8, len6 * 24);
  for (let i = 0; i < vec6.length; i++) {
    const e = vec6[i];
    const base = result6 + i * 24;var {key: v2_0, val: v2_1 } = e;
    var ptr3 = utf8Encode(v2_0, realloc0, memory0);
    var len3 = utf8EncodedLen;
    dataView(memory0).setUint32(base + 4, len3, true);
    dataView(memory0).setUint32(base + 0, ptr3, true);
    var variant5 = v2_1;
    switch (variant5.tag) {
      case 'val-null': {
        dataView(memory0).setInt8(base + 8, 0, true);
        break;
      }
      case 'val-bool': {
        const e = variant5.val;
        dataView(memory0).setInt8(base + 8, 1, true);
        dataView(memory0).setInt8(base + 16, e ? 1 : 0, true);
        break;
      }
      case 'val-int': {
        const e = variant5.val;
        dataView(memory0).setInt8(base + 8, 2, true);
        dataView(memory0).setInt32(base + 16, toInt32(e), true);
        break;
      }
      case 'val-float': {
        const e = variant5.val;
        dataView(memory0).setInt8(base + 8, 3, true);
        dataView(memory0).setFloat64(base + 16, +e, true);
        break;
      }
      case 'val-str': {
        const e = variant5.val;
        dataView(memory0).setInt8(base + 8, 4, true);
        var ptr4 = utf8Encode(e, realloc0, memory0);
        var len4 = utf8EncodedLen;
        dataView(memory0).setUint32(base + 20, len4, true);
        dataView(memory0).setUint32(base + 16, ptr4, true);
        break;
      }
      default: {
        throw new TypeError(`invalid variant tag value \`${JSON.stringify(variant5.tag)}\` (received \`${variant5}\`) specified for \`Value\``);
      }
    }
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-insert"][Instruction::CallWasm] enter', {
    funcName: 'doc-insert',
    paramCount: 7,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010DocInsert');
  const ret = converge010DocInsert(toUint32(arg0), ptr0, len0, ptr1, len1, result6, len6);
  endCurrentTask(0);
  var ptr7 = dataView(memory0).getUint32(ret + 0, true);
  var len7 = dataView(memory0).getUint32(ret + 4, true);
  var result7 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr7, len7));
  var len9 = dataView(memory0).getUint32(ret + 16, true);
  var base9 = dataView(memory0).getUint32(ret + 12, true);
  var result9 = [];
  for (let i = 0; i < len9; i++) {
    const base = base9 + i * 12;
    var ptr8 = dataView(memory0).getUint32(base + 0, true);
    var len8 = dataView(memory0).getUint32(base + 4, true);
    var result8 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr8, len8));
    result9.push({
      peer: result8,
      counter: dataView(memory0).getInt32(base + 8, true),
    });
  }
  let variant25;
  switch (dataView(memory0).getUint8(ret + 24, true)) {
    case 0: {
      var ptr10 = dataView(memory0).getUint32(ret + 32, true);
      var len10 = dataView(memory0).getUint32(ret + 36, true);
      var result10 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr10, len10));
      var ptr11 = dataView(memory0).getUint32(ret + 40, true);
      var len11 = dataView(memory0).getUint32(ret + 44, true);
      var result11 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr11, len11));
      var len16 = dataView(memory0).getUint32(ret + 52, true);
      var base16 = dataView(memory0).getUint32(ret + 48, true);
      var result16 = [];
      for (let i = 0; i < len16; i++) {
        const base = base16 + i * 24;
        var ptr12 = dataView(memory0).getUint32(base + 0, true);
        var len12 = dataView(memory0).getUint32(base + 4, true);
        var result12 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr12, len12));
        let variant15;
        switch (dataView(memory0).getUint8(base + 8, true)) {
          case 0: {
            variant15= {
              tag: 'val-null',
            };
            break;
          }
          case 1: {
            var bool13 = dataView(memory0).getUint8(base + 16, true);
            variant15= {
              tag: 'val-bool',
              val: bool13 == 0 ? false : (bool13 == 1 ? true : throwInvalidBool())
            };
            break;
          }
          case 2: {
            variant15= {
              tag: 'val-int',
              val: dataView(memory0).getInt32(base + 16, true)
            };
            break;
          }
          case 3: {
            variant15= {
              tag: 'val-float',
              val: dataView(memory0).getFloat64(base + 16, true)
            };
            break;
          }
          case 4: {
            var ptr14 = dataView(memory0).getUint32(base + 16, true);
            var len14 = dataView(memory0).getUint32(base + 20, true);
            var result14 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr14, len14));
            variant15= {
              tag: 'val-str',
              val: result14
            };
            break;
          }
          default: {
            throw new TypeError('invalid variant discriminant for Value');
          }
        }
        result16.push({
          key: result12,
          val: variant15,
        });
      }
      variant25= {
        tag: 'insert',
        val: {
          tbl: result10,
          rowId: result11,
          values: result16,
        }
      };
      break;
    }
    case 1: {
      var ptr17 = dataView(memory0).getUint32(ret + 32, true);
      var len17 = dataView(memory0).getUint32(ret + 36, true);
      var result17 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr17, len17));
      var ptr18 = dataView(memory0).getUint32(ret + 40, true);
      var len18 = dataView(memory0).getUint32(ret + 44, true);
      var result18 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr18, len18));
      var ptr19 = dataView(memory0).getUint32(ret + 48, true);
      var len19 = dataView(memory0).getUint32(ret + 52, true);
      var result19 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr19, len19));
      let variant22;
      switch (dataView(memory0).getUint8(ret + 56, true)) {
        case 0: {
          variant22= {
            tag: 'val-null',
          };
          break;
        }
        case 1: {
          var bool20 = dataView(memory0).getUint8(ret + 64, true);
          variant22= {
            tag: 'val-bool',
            val: bool20 == 0 ? false : (bool20 == 1 ? true : throwInvalidBool())
          };
          break;
        }
        case 2: {
          variant22= {
            tag: 'val-int',
            val: dataView(memory0).getInt32(ret + 64, true)
          };
          break;
        }
        case 3: {
          variant22= {
            tag: 'val-float',
            val: dataView(memory0).getFloat64(ret + 64, true)
          };
          break;
        }
        case 4: {
          var ptr21 = dataView(memory0).getUint32(ret + 64, true);
          var len21 = dataView(memory0).getUint32(ret + 68, true);
          var result21 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr21, len21));
          variant22= {
            tag: 'val-str',
            val: result21
          };
          break;
        }
        default: {
          throw new TypeError('invalid variant discriminant for Value');
        }
      }
      variant25= {
        tag: 'update',
        val: {
          tbl: result17,
          rowId: result18,
          col: result19,
          val: variant22,
        }
      };
      break;
    }
    case 2: {
      var ptr23 = dataView(memory0).getUint32(ret + 32, true);
      var len23 = dataView(memory0).getUint32(ret + 36, true);
      var result23 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr23, len23));
      var ptr24 = dataView(memory0).getUint32(ret + 40, true);
      var len24 = dataView(memory0).getUint32(ret + 44, true);
      var result24 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr24, len24));
      variant25= {
        tag: 'delete',
        val: {
          tbl: result23,
          rowId: result24,
        }
      };
      break;
    }
    default: {
      throw new TypeError('invalid variant discriminant for RowOp');
    }
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-insert"][Instruction::Return]', {
    funcName: 'doc-insert',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return {
    id: {
      peer: result7,
      counter: dataView(memory0).getInt32(ret + 8, true),
    },
    deps: result9,
    lamport: dataView(memory0).getInt32(ret + 20, true),
    op: variant25,
  };
}
let converge010DocUpdate;

function docUpdate(arg0, arg1, arg2, arg3, arg4) {
  var ptr0 = utf8Encode(arg1, realloc0, memory0);
  var len0 = utf8EncodedLen;
  var ptr1 = utf8Encode(arg2, realloc0, memory0);
  var len1 = utf8EncodedLen;
  var ptr2 = utf8Encode(arg3, realloc0, memory0);
  var len2 = utf8EncodedLen;
  var variant4 = arg4;
  let variant4_0;
  let variant4_1;
  let variant4_2;
  switch (variant4.tag) {
    case 'val-null': {
      variant4_0 = 0;
      variant4_1 = 0n;
      variant4_2 = 0;
      break;
    }
    case 'val-bool': {
      const e = variant4.val;
      variant4_0 = 1;
      variant4_1 = BigInt(BigInt(e ? 1 : 0));
      variant4_2 = 0;
      break;
    }
    case 'val-int': {
      const e = variant4.val;
      variant4_0 = 2;
      variant4_1 = BigInt(BigInt(toInt32(e)));
      variant4_2 = 0;
      break;
    }
    case 'val-float': {
      const e = variant4.val;
      variant4_0 = 3;
      variant4_1 = BigInt(f64ToI64(+e));
      variant4_2 = 0;
      break;
    }
    case 'val-str': {
      const e = variant4.val;
      var ptr3 = utf8Encode(e, realloc0, memory0);
      var len3 = utf8EncodedLen;
      variant4_0 = 4;
      variant4_1 = BigInt(ptr3);
      variant4_2 = len3;
      break;
    }
    default: {
      throw new TypeError(`invalid variant tag value \`${JSON.stringify(variant4.tag)}\` (received \`${variant4}\`) specified for \`Value\``);
    }
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-update"][Instruction::CallWasm] enter', {
    funcName: 'doc-update',
    paramCount: 10,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010DocUpdate');
  const ret = converge010DocUpdate(toUint32(arg0), ptr0, len0, ptr1, len1, ptr2, len2, variant4_0, variant4_1, variant4_2);
  endCurrentTask(0);
  var ptr5 = dataView(memory0).getUint32(ret + 0, true);
  var len5 = dataView(memory0).getUint32(ret + 4, true);
  var result5 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr5, len5));
  var len7 = dataView(memory0).getUint32(ret + 16, true);
  var base7 = dataView(memory0).getUint32(ret + 12, true);
  var result7 = [];
  for (let i = 0; i < len7; i++) {
    const base = base7 + i * 12;
    var ptr6 = dataView(memory0).getUint32(base + 0, true);
    var len6 = dataView(memory0).getUint32(base + 4, true);
    var result6 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr6, len6));
    result7.push({
      peer: result6,
      counter: dataView(memory0).getInt32(base + 8, true),
    });
  }
  let variant23;
  switch (dataView(memory0).getUint8(ret + 24, true)) {
    case 0: {
      var ptr8 = dataView(memory0).getUint32(ret + 32, true);
      var len8 = dataView(memory0).getUint32(ret + 36, true);
      var result8 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr8, len8));
      var ptr9 = dataView(memory0).getUint32(ret + 40, true);
      var len9 = dataView(memory0).getUint32(ret + 44, true);
      var result9 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr9, len9));
      var len14 = dataView(memory0).getUint32(ret + 52, true);
      var base14 = dataView(memory0).getUint32(ret + 48, true);
      var result14 = [];
      for (let i = 0; i < len14; i++) {
        const base = base14 + i * 24;
        var ptr10 = dataView(memory0).getUint32(base + 0, true);
        var len10 = dataView(memory0).getUint32(base + 4, true);
        var result10 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr10, len10));
        let variant13;
        switch (dataView(memory0).getUint8(base + 8, true)) {
          case 0: {
            variant13= {
              tag: 'val-null',
            };
            break;
          }
          case 1: {
            var bool11 = dataView(memory0).getUint8(base + 16, true);
            variant13= {
              tag: 'val-bool',
              val: bool11 == 0 ? false : (bool11 == 1 ? true : throwInvalidBool())
            };
            break;
          }
          case 2: {
            variant13= {
              tag: 'val-int',
              val: dataView(memory0).getInt32(base + 16, true)
            };
            break;
          }
          case 3: {
            variant13= {
              tag: 'val-float',
              val: dataView(memory0).getFloat64(base + 16, true)
            };
            break;
          }
          case 4: {
            var ptr12 = dataView(memory0).getUint32(base + 16, true);
            var len12 = dataView(memory0).getUint32(base + 20, true);
            var result12 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr12, len12));
            variant13= {
              tag: 'val-str',
              val: result12
            };
            break;
          }
          default: {
            throw new TypeError('invalid variant discriminant for Value');
          }
        }
        result14.push({
          key: result10,
          val: variant13,
        });
      }
      variant23= {
        tag: 'insert',
        val: {
          tbl: result8,
          rowId: result9,
          values: result14,
        }
      };
      break;
    }
    case 1: {
      var ptr15 = dataView(memory0).getUint32(ret + 32, true);
      var len15 = dataView(memory0).getUint32(ret + 36, true);
      var result15 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr15, len15));
      var ptr16 = dataView(memory0).getUint32(ret + 40, true);
      var len16 = dataView(memory0).getUint32(ret + 44, true);
      var result16 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr16, len16));
      var ptr17 = dataView(memory0).getUint32(ret + 48, true);
      var len17 = dataView(memory0).getUint32(ret + 52, true);
      var result17 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr17, len17));
      let variant20;
      switch (dataView(memory0).getUint8(ret + 56, true)) {
        case 0: {
          variant20= {
            tag: 'val-null',
          };
          break;
        }
        case 1: {
          var bool18 = dataView(memory0).getUint8(ret + 64, true);
          variant20= {
            tag: 'val-bool',
            val: bool18 == 0 ? false : (bool18 == 1 ? true : throwInvalidBool())
          };
          break;
        }
        case 2: {
          variant20= {
            tag: 'val-int',
            val: dataView(memory0).getInt32(ret + 64, true)
          };
          break;
        }
        case 3: {
          variant20= {
            tag: 'val-float',
            val: dataView(memory0).getFloat64(ret + 64, true)
          };
          break;
        }
        case 4: {
          var ptr19 = dataView(memory0).getUint32(ret + 64, true);
          var len19 = dataView(memory0).getUint32(ret + 68, true);
          var result19 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr19, len19));
          variant20= {
            tag: 'val-str',
            val: result19
          };
          break;
        }
        default: {
          throw new TypeError('invalid variant discriminant for Value');
        }
      }
      variant23= {
        tag: 'update',
        val: {
          tbl: result15,
          rowId: result16,
          col: result17,
          val: variant20,
        }
      };
      break;
    }
    case 2: {
      var ptr21 = dataView(memory0).getUint32(ret + 32, true);
      var len21 = dataView(memory0).getUint32(ret + 36, true);
      var result21 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr21, len21));
      var ptr22 = dataView(memory0).getUint32(ret + 40, true);
      var len22 = dataView(memory0).getUint32(ret + 44, true);
      var result22 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr22, len22));
      variant23= {
        tag: 'delete',
        val: {
          tbl: result21,
          rowId: result22,
        }
      };
      break;
    }
    default: {
      throw new TypeError('invalid variant discriminant for RowOp');
    }
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-update"][Instruction::Return]', {
    funcName: 'doc-update',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return {
    id: {
      peer: result5,
      counter: dataView(memory0).getInt32(ret + 8, true),
    },
    deps: result7,
    lamport: dataView(memory0).getInt32(ret + 20, true),
    op: variant23,
  };
}
let converge010DocDelete;

function docDelete(arg0, arg1, arg2) {
  var ptr0 = utf8Encode(arg1, realloc0, memory0);
  var len0 = utf8EncodedLen;
  var ptr1 = utf8Encode(arg2, realloc0, memory0);
  var len1 = utf8EncodedLen;
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-delete"][Instruction::CallWasm] enter', {
    funcName: 'doc-delete',
    paramCount: 5,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010DocDelete');
  const ret = converge010DocDelete(toUint32(arg0), ptr0, len0, ptr1, len1);
  endCurrentTask(0);
  var ptr2 = dataView(memory0).getUint32(ret + 0, true);
  var len2 = dataView(memory0).getUint32(ret + 4, true);
  var result2 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr2, len2));
  var len4 = dataView(memory0).getUint32(ret + 16, true);
  var base4 = dataView(memory0).getUint32(ret + 12, true);
  var result4 = [];
  for (let i = 0; i < len4; i++) {
    const base = base4 + i * 12;
    var ptr3 = dataView(memory0).getUint32(base + 0, true);
    var len3 = dataView(memory0).getUint32(base + 4, true);
    var result3 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr3, len3));
    result4.push({
      peer: result3,
      counter: dataView(memory0).getInt32(base + 8, true),
    });
  }
  let variant20;
  switch (dataView(memory0).getUint8(ret + 24, true)) {
    case 0: {
      var ptr5 = dataView(memory0).getUint32(ret + 32, true);
      var len5 = dataView(memory0).getUint32(ret + 36, true);
      var result5 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr5, len5));
      var ptr6 = dataView(memory0).getUint32(ret + 40, true);
      var len6 = dataView(memory0).getUint32(ret + 44, true);
      var result6 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr6, len6));
      var len11 = dataView(memory0).getUint32(ret + 52, true);
      var base11 = dataView(memory0).getUint32(ret + 48, true);
      var result11 = [];
      for (let i = 0; i < len11; i++) {
        const base = base11 + i * 24;
        var ptr7 = dataView(memory0).getUint32(base + 0, true);
        var len7 = dataView(memory0).getUint32(base + 4, true);
        var result7 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr7, len7));
        let variant10;
        switch (dataView(memory0).getUint8(base + 8, true)) {
          case 0: {
            variant10= {
              tag: 'val-null',
            };
            break;
          }
          case 1: {
            var bool8 = dataView(memory0).getUint8(base + 16, true);
            variant10= {
              tag: 'val-bool',
              val: bool8 == 0 ? false : (bool8 == 1 ? true : throwInvalidBool())
            };
            break;
          }
          case 2: {
            variant10= {
              tag: 'val-int',
              val: dataView(memory0).getInt32(base + 16, true)
            };
            break;
          }
          case 3: {
            variant10= {
              tag: 'val-float',
              val: dataView(memory0).getFloat64(base + 16, true)
            };
            break;
          }
          case 4: {
            var ptr9 = dataView(memory0).getUint32(base + 16, true);
            var len9 = dataView(memory0).getUint32(base + 20, true);
            var result9 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr9, len9));
            variant10= {
              tag: 'val-str',
              val: result9
            };
            break;
          }
          default: {
            throw new TypeError('invalid variant discriminant for Value');
          }
        }
        result11.push({
          key: result7,
          val: variant10,
        });
      }
      variant20= {
        tag: 'insert',
        val: {
          tbl: result5,
          rowId: result6,
          values: result11,
        }
      };
      break;
    }
    case 1: {
      var ptr12 = dataView(memory0).getUint32(ret + 32, true);
      var len12 = dataView(memory0).getUint32(ret + 36, true);
      var result12 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr12, len12));
      var ptr13 = dataView(memory0).getUint32(ret + 40, true);
      var len13 = dataView(memory0).getUint32(ret + 44, true);
      var result13 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr13, len13));
      var ptr14 = dataView(memory0).getUint32(ret + 48, true);
      var len14 = dataView(memory0).getUint32(ret + 52, true);
      var result14 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr14, len14));
      let variant17;
      switch (dataView(memory0).getUint8(ret + 56, true)) {
        case 0: {
          variant17= {
            tag: 'val-null',
          };
          break;
        }
        case 1: {
          var bool15 = dataView(memory0).getUint8(ret + 64, true);
          variant17= {
            tag: 'val-bool',
            val: bool15 == 0 ? false : (bool15 == 1 ? true : throwInvalidBool())
          };
          break;
        }
        case 2: {
          variant17= {
            tag: 'val-int',
            val: dataView(memory0).getInt32(ret + 64, true)
          };
          break;
        }
        case 3: {
          variant17= {
            tag: 'val-float',
            val: dataView(memory0).getFloat64(ret + 64, true)
          };
          break;
        }
        case 4: {
          var ptr16 = dataView(memory0).getUint32(ret + 64, true);
          var len16 = dataView(memory0).getUint32(ret + 68, true);
          var result16 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr16, len16));
          variant17= {
            tag: 'val-str',
            val: result16
          };
          break;
        }
        default: {
          throw new TypeError('invalid variant discriminant for Value');
        }
      }
      variant20= {
        tag: 'update',
        val: {
          tbl: result12,
          rowId: result13,
          col: result14,
          val: variant17,
        }
      };
      break;
    }
    case 2: {
      var ptr18 = dataView(memory0).getUint32(ret + 32, true);
      var len18 = dataView(memory0).getUint32(ret + 36, true);
      var result18 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr18, len18));
      var ptr19 = dataView(memory0).getUint32(ret + 40, true);
      var len19 = dataView(memory0).getUint32(ret + 44, true);
      var result19 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr19, len19));
      variant20= {
        tag: 'delete',
        val: {
          tbl: result18,
          rowId: result19,
        }
      };
      break;
    }
    default: {
      throw new TypeError('invalid variant discriminant for RowOp');
    }
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-delete"][Instruction::Return]', {
    funcName: 'doc-delete',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return {
    id: {
      peer: result2,
      counter: dataView(memory0).getInt32(ret + 8, true),
    },
    deps: result4,
    lamport: dataView(memory0).getInt32(ret + 20, true),
    op: variant20,
  };
}
let converge010DocMergeRemote;

function docMergeRemote(arg0, arg1) {
  var vec24 = arg1;
  var len24 = vec24.length;
  var result24 = realloc0(0, 0, 4, len24 * 32);
  for (let i = 0; i < vec24.length; i++) {
    const e = vec24[i];
    const base = result24 + i * 32;var {peer: v0_0, counterStart: v0_1, lamportStart: v0_2, deps: v0_3, ops: v0_4 } = e;
    var ptr1 = utf8Encode(v0_0, realloc0, memory0);
    var len1 = utf8EncodedLen;
    dataView(memory0).setUint32(base + 4, len1, true);
    dataView(memory0).setUint32(base + 0, ptr1, true);
    dataView(memory0).setInt32(base + 8, toInt32(v0_1), true);
    dataView(memory0).setInt32(base + 12, toInt32(v0_2), true);
    var vec4 = v0_3;
    var len4 = vec4.length;
    var result4 = realloc0(0, 0, 4, len4 * 12);
    for (let i = 0; i < vec4.length; i++) {
      const e = vec4[i];
      const base = result4 + i * 12;var {peer: v2_0, counter: v2_1 } = e;
      var ptr3 = utf8Encode(v2_0, realloc0, memory0);
      var len3 = utf8EncodedLen;
      dataView(memory0).setUint32(base + 4, len3, true);
      dataView(memory0).setUint32(base + 0, ptr3, true);
      dataView(memory0).setInt32(base + 8, toInt32(v2_1), true);
    }
    dataView(memory0).setUint32(base + 20, len4, true);
    dataView(memory0).setUint32(base + 16, result4, true);
    var vec23 = v0_4;
    var len23 = vec23.length;
    var result23 = realloc0(0, 0, 8, len23 * 48);
    for (let i = 0; i < vec23.length; i++) {
      const e = vec23[i];
      const base = result23 + i * 48;var variant22 = e;
      switch (variant22.tag) {
        case 'insert': {
          const e = variant22.val;
          dataView(memory0).setInt8(base + 0, 0, true);
          var {tbl: v5_0, rowId: v5_1, values: v5_2 } = e;
          var ptr6 = utf8Encode(v5_0, realloc0, memory0);
          var len6 = utf8EncodedLen;
          dataView(memory0).setUint32(base + 12, len6, true);
          dataView(memory0).setUint32(base + 8, ptr6, true);
          var ptr7 = utf8Encode(v5_1, realloc0, memory0);
          var len7 = utf8EncodedLen;
          dataView(memory0).setUint32(base + 20, len7, true);
          dataView(memory0).setUint32(base + 16, ptr7, true);
          var vec12 = v5_2;
          var len12 = vec12.length;
          var result12 = realloc0(0, 0, 8, len12 * 24);
          for (let i = 0; i < vec12.length; i++) {
            const e = vec12[i];
            const base = result12 + i * 24;var {key: v8_0, val: v8_1 } = e;
            var ptr9 = utf8Encode(v8_0, realloc0, memory0);
            var len9 = utf8EncodedLen;
            dataView(memory0).setUint32(base + 4, len9, true);
            dataView(memory0).setUint32(base + 0, ptr9, true);
            var variant11 = v8_1;
            switch (variant11.tag) {
              case 'val-null': {
                dataView(memory0).setInt8(base + 8, 0, true);
                break;
              }
              case 'val-bool': {
                const e = variant11.val;
                dataView(memory0).setInt8(base + 8, 1, true);
                dataView(memory0).setInt8(base + 16, e ? 1 : 0, true);
                break;
              }
              case 'val-int': {
                const e = variant11.val;
                dataView(memory0).setInt8(base + 8, 2, true);
                dataView(memory0).setInt32(base + 16, toInt32(e), true);
                break;
              }
              case 'val-float': {
                const e = variant11.val;
                dataView(memory0).setInt8(base + 8, 3, true);
                dataView(memory0).setFloat64(base + 16, +e, true);
                break;
              }
              case 'val-str': {
                const e = variant11.val;
                dataView(memory0).setInt8(base + 8, 4, true);
                var ptr10 = utf8Encode(e, realloc0, memory0);
                var len10 = utf8EncodedLen;
                dataView(memory0).setUint32(base + 20, len10, true);
                dataView(memory0).setUint32(base + 16, ptr10, true);
                break;
              }
              default: {
                throw new TypeError(`invalid variant tag value \`${JSON.stringify(variant11.tag)}\` (received \`${variant11}\`) specified for \`Value\``);
              }
            }
          }
          dataView(memory0).setUint32(base + 28, len12, true);
          dataView(memory0).setUint32(base + 24, result12, true);
          break;
        }
        case 'update': {
          const e = variant22.val;
          dataView(memory0).setInt8(base + 0, 1, true);
          var {tbl: v13_0, rowId: v13_1, col: v13_2, val: v13_3 } = e;
          var ptr14 = utf8Encode(v13_0, realloc0, memory0);
          var len14 = utf8EncodedLen;
          dataView(memory0).setUint32(base + 12, len14, true);
          dataView(memory0).setUint32(base + 8, ptr14, true);
          var ptr15 = utf8Encode(v13_1, realloc0, memory0);
          var len15 = utf8EncodedLen;
          dataView(memory0).setUint32(base + 20, len15, true);
          dataView(memory0).setUint32(base + 16, ptr15, true);
          var ptr16 = utf8Encode(v13_2, realloc0, memory0);
          var len16 = utf8EncodedLen;
          dataView(memory0).setUint32(base + 28, len16, true);
          dataView(memory0).setUint32(base + 24, ptr16, true);
          var variant18 = v13_3;
          switch (variant18.tag) {
            case 'val-null': {
              dataView(memory0).setInt8(base + 32, 0, true);
              break;
            }
            case 'val-bool': {
              const e = variant18.val;
              dataView(memory0).setInt8(base + 32, 1, true);
              dataView(memory0).setInt8(base + 40, e ? 1 : 0, true);
              break;
            }
            case 'val-int': {
              const e = variant18.val;
              dataView(memory0).setInt8(base + 32, 2, true);
              dataView(memory0).setInt32(base + 40, toInt32(e), true);
              break;
            }
            case 'val-float': {
              const e = variant18.val;
              dataView(memory0).setInt8(base + 32, 3, true);
              dataView(memory0).setFloat64(base + 40, +e, true);
              break;
            }
            case 'val-str': {
              const e = variant18.val;
              dataView(memory0).setInt8(base + 32, 4, true);
              var ptr17 = utf8Encode(e, realloc0, memory0);
              var len17 = utf8EncodedLen;
              dataView(memory0).setUint32(base + 44, len17, true);
              dataView(memory0).setUint32(base + 40, ptr17, true);
              break;
            }
            default: {
              throw new TypeError(`invalid variant tag value \`${JSON.stringify(variant18.tag)}\` (received \`${variant18}\`) specified for \`Value\``);
            }
          }
          break;
        }
        case 'delete': {
          const e = variant22.val;
          dataView(memory0).setInt8(base + 0, 2, true);
          var {tbl: v19_0, rowId: v19_1 } = e;
          var ptr20 = utf8Encode(v19_0, realloc0, memory0);
          var len20 = utf8EncodedLen;
          dataView(memory0).setUint32(base + 12, len20, true);
          dataView(memory0).setUint32(base + 8, ptr20, true);
          var ptr21 = utf8Encode(v19_1, realloc0, memory0);
          var len21 = utf8EncodedLen;
          dataView(memory0).setUint32(base + 20, len21, true);
          dataView(memory0).setUint32(base + 16, ptr21, true);
          break;
        }
        default: {
          throw new TypeError(`invalid variant tag value \`${JSON.stringify(variant22.tag)}\` (received \`${variant22}\`) specified for \`RowOp\``);
        }
      }
    }
    dataView(memory0).setUint32(base + 28, len23, true);
    dataView(memory0).setUint32(base + 24, result23, true);
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-merge-remote"][Instruction::CallWasm] enter', {
    funcName: 'doc-merge-remote',
    paramCount: 3,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010DocMergeRemote');
  const ret = converge010DocMergeRemote(toUint32(arg0), result24, len24);
  endCurrentTask(0);
  var len41 = dataView(memory0).getUint32(ret + 4, true);
  var base41 = dataView(memory0).getUint32(ret + 0, true);
  var result41 = [];
  for (let i = 0; i < len41; i++) {
    const base = base41 + i * 48;
    let variant40;
    switch (dataView(memory0).getUint8(base + 0, true)) {
      case 0: {
        var ptr25 = dataView(memory0).getUint32(base + 8, true);
        var len25 = dataView(memory0).getUint32(base + 12, true);
        var result25 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr25, len25));
        var ptr26 = dataView(memory0).getUint32(base + 16, true);
        var len26 = dataView(memory0).getUint32(base + 20, true);
        var result26 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr26, len26));
        var ptr27 = dataView(memory0).getUint32(base + 24, true);
        var len27 = dataView(memory0).getUint32(base + 28, true);
        var result27 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr27, len27));
        let variant30;
        switch (dataView(memory0).getUint8(base + 32, true)) {
          case 0: {
            variant30= {
              tag: 'val-null',
            };
            break;
          }
          case 1: {
            var bool28 = dataView(memory0).getUint8(base + 40, true);
            variant30= {
              tag: 'val-bool',
              val: bool28 == 0 ? false : (bool28 == 1 ? true : throwInvalidBool())
            };
            break;
          }
          case 2: {
            variant30= {
              tag: 'val-int',
              val: dataView(memory0).getInt32(base + 40, true)
            };
            break;
          }
          case 3: {
            variant30= {
              tag: 'val-float',
              val: dataView(memory0).getFloat64(base + 40, true)
            };
            break;
          }
          case 4: {
            var ptr29 = dataView(memory0).getUint32(base + 40, true);
            var len29 = dataView(memory0).getUint32(base + 44, true);
            var result29 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr29, len29));
            variant30= {
              tag: 'val-str',
              val: result29
            };
            break;
          }
          default: {
            throw new TypeError('invalid variant discriminant for Value');
          }
        }
        variant40= {
          tag: 'set-cell',
          val: {
            tbl: result25,
            rowId: result26,
            col: result27,
            val: variant30,
          }
        };
        break;
      }
      case 1: {
        var ptr31 = dataView(memory0).getUint32(base + 8, true);
        var len31 = dataView(memory0).getUint32(base + 12, true);
        var result31 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr31, len31));
        var ptr32 = dataView(memory0).getUint32(base + 16, true);
        var len32 = dataView(memory0).getUint32(base + 20, true);
        var result32 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr32, len32));
        var len37 = dataView(memory0).getUint32(base + 28, true);
        var base37 = dataView(memory0).getUint32(base + 24, true);
        var result37 = [];
        for (let i = 0; i < len37; i++) {
          const base = base37 + i * 24;
          var ptr33 = dataView(memory0).getUint32(base + 0, true);
          var len33 = dataView(memory0).getUint32(base + 4, true);
          var result33 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr33, len33));
          let variant36;
          switch (dataView(memory0).getUint8(base + 8, true)) {
            case 0: {
              variant36= {
                tag: 'val-null',
              };
              break;
            }
            case 1: {
              var bool34 = dataView(memory0).getUint8(base + 16, true);
              variant36= {
                tag: 'val-bool',
                val: bool34 == 0 ? false : (bool34 == 1 ? true : throwInvalidBool())
              };
              break;
            }
            case 2: {
              variant36= {
                tag: 'val-int',
                val: dataView(memory0).getInt32(base + 16, true)
              };
              break;
            }
            case 3: {
              variant36= {
                tag: 'val-float',
                val: dataView(memory0).getFloat64(base + 16, true)
              };
              break;
            }
            case 4: {
              var ptr35 = dataView(memory0).getUint32(base + 16, true);
              var len35 = dataView(memory0).getUint32(base + 20, true);
              var result35 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr35, len35));
              variant36= {
                tag: 'val-str',
                val: result35
              };
              break;
            }
            default: {
              throw new TypeError('invalid variant discriminant for Value');
            }
          }
          result37.push({
            key: result33,
            val: variant36,
          });
        }
        variant40= {
          tag: 'insert-row',
          val: {
            tbl: result31,
            rowId: result32,
            values: result37,
          }
        };
        break;
      }
      case 2: {
        var ptr38 = dataView(memory0).getUint32(base + 8, true);
        var len38 = dataView(memory0).getUint32(base + 12, true);
        var result38 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr38, len38));
        var ptr39 = dataView(memory0).getUint32(base + 16, true);
        var len39 = dataView(memory0).getUint32(base + 20, true);
        var result39 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr39, len39));
        variant40= {
          tag: 'delete-row',
          val: {
            tbl: result38,
            rowId: result39,
          }
        };
        break;
      }
      default: {
        throw new TypeError('invalid variant discriminant for MergeOp');
      }
    }
    result41.push(variant40);
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-merge-remote"][Instruction::Return]', {
    funcName: 'doc-merge-remote',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return result41;
}
let converge010DocGetPending;

function docGetPending(arg0, arg1) {
  var vec2 = arg1;
  var len2 = vec2.length;
  var result2 = realloc0(0, 0, 4, len2 * 12);
  for (let i = 0; i < vec2.length; i++) {
    const e = vec2[i];
    const base = result2 + i * 12;var {peer: v0_0, version: v0_1 } = e;
    var ptr1 = utf8Encode(v0_0, realloc0, memory0);
    var len1 = utf8EncodedLen;
    dataView(memory0).setUint32(base + 4, len1, true);
    dataView(memory0).setUint32(base + 0, ptr1, true);
    dataView(memory0).setInt32(base + 8, toInt32(v0_1), true);
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-get-pending"][Instruction::CallWasm] enter', {
    funcName: 'doc-get-pending',
    paramCount: 3,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010DocGetPending');
  const ret = converge010DocGetPending(toUint32(arg0), result2, len2);
  endCurrentTask(0);
  var len23 = dataView(memory0).getUint32(ret + 4, true);
  var base23 = dataView(memory0).getUint32(ret + 0, true);
  var result23 = [];
  for (let i = 0; i < len23; i++) {
    const base = base23 + i * 32;
    var ptr3 = dataView(memory0).getUint32(base + 0, true);
    var len3 = dataView(memory0).getUint32(base + 4, true);
    var result3 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr3, len3));
    var len5 = dataView(memory0).getUint32(base + 20, true);
    var base5 = dataView(memory0).getUint32(base + 16, true);
    var result5 = [];
    for (let i = 0; i < len5; i++) {
      const base = base5 + i * 12;
      var ptr4 = dataView(memory0).getUint32(base + 0, true);
      var len4 = dataView(memory0).getUint32(base + 4, true);
      var result4 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr4, len4));
      result5.push({
        peer: result4,
        counter: dataView(memory0).getInt32(base + 8, true),
      });
    }
    var len22 = dataView(memory0).getUint32(base + 28, true);
    var base22 = dataView(memory0).getUint32(base + 24, true);
    var result22 = [];
    for (let i = 0; i < len22; i++) {
      const base = base22 + i * 48;
      let variant21;
      switch (dataView(memory0).getUint8(base + 0, true)) {
        case 0: {
          var ptr6 = dataView(memory0).getUint32(base + 8, true);
          var len6 = dataView(memory0).getUint32(base + 12, true);
          var result6 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr6, len6));
          var ptr7 = dataView(memory0).getUint32(base + 16, true);
          var len7 = dataView(memory0).getUint32(base + 20, true);
          var result7 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr7, len7));
          var len12 = dataView(memory0).getUint32(base + 28, true);
          var base12 = dataView(memory0).getUint32(base + 24, true);
          var result12 = [];
          for (let i = 0; i < len12; i++) {
            const base = base12 + i * 24;
            var ptr8 = dataView(memory0).getUint32(base + 0, true);
            var len8 = dataView(memory0).getUint32(base + 4, true);
            var result8 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr8, len8));
            let variant11;
            switch (dataView(memory0).getUint8(base + 8, true)) {
              case 0: {
                variant11= {
                  tag: 'val-null',
                };
                break;
              }
              case 1: {
                var bool9 = dataView(memory0).getUint8(base + 16, true);
                variant11= {
                  tag: 'val-bool',
                  val: bool9 == 0 ? false : (bool9 == 1 ? true : throwInvalidBool())
                };
                break;
              }
              case 2: {
                variant11= {
                  tag: 'val-int',
                  val: dataView(memory0).getInt32(base + 16, true)
                };
                break;
              }
              case 3: {
                variant11= {
                  tag: 'val-float',
                  val: dataView(memory0).getFloat64(base + 16, true)
                };
                break;
              }
              case 4: {
                var ptr10 = dataView(memory0).getUint32(base + 16, true);
                var len10 = dataView(memory0).getUint32(base + 20, true);
                var result10 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr10, len10));
                variant11= {
                  tag: 'val-str',
                  val: result10
                };
                break;
              }
              default: {
                throw new TypeError('invalid variant discriminant for Value');
              }
            }
            result12.push({
              key: result8,
              val: variant11,
            });
          }
          variant21= {
            tag: 'insert',
            val: {
              tbl: result6,
              rowId: result7,
              values: result12,
            }
          };
          break;
        }
        case 1: {
          var ptr13 = dataView(memory0).getUint32(base + 8, true);
          var len13 = dataView(memory0).getUint32(base + 12, true);
          var result13 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr13, len13));
          var ptr14 = dataView(memory0).getUint32(base + 16, true);
          var len14 = dataView(memory0).getUint32(base + 20, true);
          var result14 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr14, len14));
          var ptr15 = dataView(memory0).getUint32(base + 24, true);
          var len15 = dataView(memory0).getUint32(base + 28, true);
          var result15 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr15, len15));
          let variant18;
          switch (dataView(memory0).getUint8(base + 32, true)) {
            case 0: {
              variant18= {
                tag: 'val-null',
              };
              break;
            }
            case 1: {
              var bool16 = dataView(memory0).getUint8(base + 40, true);
              variant18= {
                tag: 'val-bool',
                val: bool16 == 0 ? false : (bool16 == 1 ? true : throwInvalidBool())
              };
              break;
            }
            case 2: {
              variant18= {
                tag: 'val-int',
                val: dataView(memory0).getInt32(base + 40, true)
              };
              break;
            }
            case 3: {
              variant18= {
                tag: 'val-float',
                val: dataView(memory0).getFloat64(base + 40, true)
              };
              break;
            }
            case 4: {
              var ptr17 = dataView(memory0).getUint32(base + 40, true);
              var len17 = dataView(memory0).getUint32(base + 44, true);
              var result17 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr17, len17));
              variant18= {
                tag: 'val-str',
                val: result17
              };
              break;
            }
            default: {
              throw new TypeError('invalid variant discriminant for Value');
            }
          }
          variant21= {
            tag: 'update',
            val: {
              tbl: result13,
              rowId: result14,
              col: result15,
              val: variant18,
            }
          };
          break;
        }
        case 2: {
          var ptr19 = dataView(memory0).getUint32(base + 8, true);
          var len19 = dataView(memory0).getUint32(base + 12, true);
          var result19 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr19, len19));
          var ptr20 = dataView(memory0).getUint32(base + 16, true);
          var len20 = dataView(memory0).getUint32(base + 20, true);
          var result20 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr20, len20));
          variant21= {
            tag: 'delete',
            val: {
              tbl: result19,
              rowId: result20,
            }
          };
          break;
        }
        default: {
          throw new TypeError('invalid variant discriminant for RowOp');
        }
      }
      result22.push(variant21);
    }
    result23.push({
      peer: result3,
      counterStart: dataView(memory0).getInt32(base + 8, true),
      lamportStart: dataView(memory0).getInt32(base + 12, true),
      deps: result5,
      ops: result22,
    });
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-get-pending"][Instruction::Return]', {
    funcName: 'doc-get-pending',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return result23;
}
let converge010DocSyncState;

function docSyncState(arg0) {
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-sync-state"][Instruction::CallWasm] enter', {
    funcName: 'doc-sync-state',
    paramCount: 1,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010DocSyncState');
  const ret = converge010DocSyncState(toUint32(arg0));
  endCurrentTask(0);
  var len1 = dataView(memory0).getUint32(ret + 4, true);
  var base1 = dataView(memory0).getUint32(ret + 0, true);
  var result1 = [];
  for (let i = 0; i < len1; i++) {
    const base = base1 + i * 12;
    var ptr0 = dataView(memory0).getUint32(base + 0, true);
    var len0 = dataView(memory0).getUint32(base + 4, true);
    var result0 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr0, len0));
    result1.push({
      peer: result0,
      counter: dataView(memory0).getInt32(base + 8, true),
    });
  }
  var len3 = dataView(memory0).getUint32(ret + 12, true);
  var base3 = dataView(memory0).getUint32(ret + 8, true);
  var result3 = [];
  for (let i = 0; i < len3; i++) {
    const base = base3 + i * 12;
    var ptr2 = dataView(memory0).getUint32(base + 0, true);
    var len2 = dataView(memory0).getUint32(base + 4, true);
    var result2 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr2, len2));
    result3.push({
      peer: result2,
      version: dataView(memory0).getInt32(base + 8, true),
    });
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="doc-sync-state"][Instruction::Return]', {
    funcName: 'doc-sync-state',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return {
    frontier: result1,
    versions: result3,
  };
}
let converge010EphemeralSet;

function ephemeralSet(arg0, arg1, arg2, arg3, arg4) {
  var ptr0 = utf8Encode(arg1, realloc0, memory0);
  var len0 = utf8EncodedLen;
  var ptr1 = utf8Encode(arg2, realloc0, memory0);
  var len1 = utf8EncodedLen;
  var variant3 = arg3;
  let variant3_0;
  let variant3_1;
  let variant3_2;
  switch (variant3.tag) {
    case 'val-null': {
      variant3_0 = 0;
      variant3_1 = 0n;
      variant3_2 = 0;
      break;
    }
    case 'val-bool': {
      const e = variant3.val;
      variant3_0 = 1;
      variant3_1 = BigInt(BigInt(e ? 1 : 0));
      variant3_2 = 0;
      break;
    }
    case 'val-int': {
      const e = variant3.val;
      variant3_0 = 2;
      variant3_1 = BigInt(BigInt(toInt32(e)));
      variant3_2 = 0;
      break;
    }
    case 'val-float': {
      const e = variant3.val;
      variant3_0 = 3;
      variant3_1 = BigInt(f64ToI64(+e));
      variant3_2 = 0;
      break;
    }
    case 'val-str': {
      const e = variant3.val;
      var ptr2 = utf8Encode(e, realloc0, memory0);
      var len2 = utf8EncodedLen;
      variant3_0 = 4;
      variant3_1 = BigInt(ptr2);
      variant3_2 = len2;
      break;
    }
    default: {
      throw new TypeError(`invalid variant tag value \`${JSON.stringify(variant3.tag)}\` (received \`${variant3}\`) specified for \`Value\``);
    }
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="ephemeral-set"][Instruction::CallWasm] enter', {
    funcName: 'ephemeral-set',
    paramCount: 9,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010EphemeralSet');
  const ret = converge010EphemeralSet(toUint32(arg0), ptr0, len0, ptr1, len1, variant3_0, variant3_1, variant3_2, +arg4);
  endCurrentTask(0);
  var ptr4 = dataView(memory0).getUint32(ret + 0, true);
  var len4 = dataView(memory0).getUint32(ret + 4, true);
  var result4 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr4, len4));
  let variant7;
  switch (dataView(memory0).getUint8(ret + 8, true)) {
    case 0: {
      variant7= {
        tag: 'val-null',
      };
      break;
    }
    case 1: {
      var bool5 = dataView(memory0).getUint8(ret + 16, true);
      variant7= {
        tag: 'val-bool',
        val: bool5 == 0 ? false : (bool5 == 1 ? true : throwInvalidBool())
      };
      break;
    }
    case 2: {
      variant7= {
        tag: 'val-int',
        val: dataView(memory0).getInt32(ret + 16, true)
      };
      break;
    }
    case 3: {
      variant7= {
        tag: 'val-float',
        val: dataView(memory0).getFloat64(ret + 16, true)
      };
      break;
    }
    case 4: {
      var ptr6 = dataView(memory0).getUint32(ret + 16, true);
      var len6 = dataView(memory0).getUint32(ret + 20, true);
      var result6 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr6, len6));
      variant7= {
        tag: 'val-str',
        val: result6
      };
      break;
    }
    default: {
      throw new TypeError('invalid variant discriminant for Value');
    }
  }
  var ptr8 = dataView(memory0).getUint32(ret + 32, true);
  var len8 = dataView(memory0).getUint32(ret + 36, true);
  var result8 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr8, len8));
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="ephemeral-set"][Instruction::Return]', {
    funcName: 'ephemeral-set',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return {
    key: result4,
    val: variant7,
    timestamp: dataView(memory0).getFloat64(ret + 24, true),
    peer: result8,
  };
}
let converge010EphemeralGet;

function ephemeralGet(arg0, arg1, arg2) {
  var ptr0 = utf8Encode(arg1, realloc0, memory0);
  var len0 = utf8EncodedLen;
  var ptr1 = utf8Encode(arg2, realloc0, memory0);
  var len1 = utf8EncodedLen;
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="ephemeral-get"][Instruction::CallWasm] enter', {
    funcName: 'ephemeral-get',
    paramCount: 5,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010EphemeralGet');
  const ret = converge010EphemeralGet(toUint32(arg0), ptr0, len0, ptr1, len1);
  endCurrentTask(0);
  let variant7;
  switch (dataView(memory0).getUint8(ret + 0, true)) {
    case 0: {
      variant7 = undefined;
      break;
    }
    case 1: {
      var ptr2 = dataView(memory0).getUint32(ret + 8, true);
      var len2 = dataView(memory0).getUint32(ret + 12, true);
      var result2 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr2, len2));
      let variant5;
      switch (dataView(memory0).getUint8(ret + 16, true)) {
        case 0: {
          variant5= {
            tag: 'val-null',
          };
          break;
        }
        case 1: {
          var bool3 = dataView(memory0).getUint8(ret + 24, true);
          variant5= {
            tag: 'val-bool',
            val: bool3 == 0 ? false : (bool3 == 1 ? true : throwInvalidBool())
          };
          break;
        }
        case 2: {
          variant5= {
            tag: 'val-int',
            val: dataView(memory0).getInt32(ret + 24, true)
          };
          break;
        }
        case 3: {
          variant5= {
            tag: 'val-float',
            val: dataView(memory0).getFloat64(ret + 24, true)
          };
          break;
        }
        case 4: {
          var ptr4 = dataView(memory0).getUint32(ret + 24, true);
          var len4 = dataView(memory0).getUint32(ret + 28, true);
          var result4 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr4, len4));
          variant5= {
            tag: 'val-str',
            val: result4
          };
          break;
        }
        default: {
          throw new TypeError('invalid variant discriminant for Value');
        }
      }
      var ptr6 = dataView(memory0).getUint32(ret + 40, true);
      var len6 = dataView(memory0).getUint32(ret + 44, true);
      var result6 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr6, len6));
      variant7 = {
        key: result2,
        val: variant5,
        timestamp: dataView(memory0).getFloat64(ret + 32, true),
        peer: result6,
      };
      break;
    }
    default: {
      throw new TypeError('invalid variant discriminant for option');
    }
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="ephemeral-get"][Instruction::Return]', {
    funcName: 'ephemeral-get',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return variant7;
}
let converge010EphemeralGetAll;

function ephemeralGetAll(arg0, arg1) {
  var ptr0 = utf8Encode(arg1, realloc0, memory0);
  var len0 = utf8EncodedLen;
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="ephemeral-get-all"][Instruction::CallWasm] enter', {
    funcName: 'ephemeral-get-all',
    paramCount: 3,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010EphemeralGetAll');
  const ret = converge010EphemeralGetAll(toUint32(arg0), ptr0, len0);
  endCurrentTask(0);
  var len6 = dataView(memory0).getUint32(ret + 4, true);
  var base6 = dataView(memory0).getUint32(ret + 0, true);
  var result6 = [];
  for (let i = 0; i < len6; i++) {
    const base = base6 + i * 40;
    var ptr1 = dataView(memory0).getUint32(base + 0, true);
    var len1 = dataView(memory0).getUint32(base + 4, true);
    var result1 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr1, len1));
    let variant4;
    switch (dataView(memory0).getUint8(base + 8, true)) {
      case 0: {
        variant4= {
          tag: 'val-null',
        };
        break;
      }
      case 1: {
        var bool2 = dataView(memory0).getUint8(base + 16, true);
        variant4= {
          tag: 'val-bool',
          val: bool2 == 0 ? false : (bool2 == 1 ? true : throwInvalidBool())
        };
        break;
      }
      case 2: {
        variant4= {
          tag: 'val-int',
          val: dataView(memory0).getInt32(base + 16, true)
        };
        break;
      }
      case 3: {
        variant4= {
          tag: 'val-float',
          val: dataView(memory0).getFloat64(base + 16, true)
        };
        break;
      }
      case 4: {
        var ptr3 = dataView(memory0).getUint32(base + 16, true);
        var len3 = dataView(memory0).getUint32(base + 20, true);
        var result3 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr3, len3));
        variant4= {
          tag: 'val-str',
          val: result3
        };
        break;
      }
      default: {
        throw new TypeError('invalid variant discriminant for Value');
      }
    }
    var ptr5 = dataView(memory0).getUint32(base + 32, true);
    var len5 = dataView(memory0).getUint32(base + 36, true);
    var result5 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr5, len5));
    result6.push({
      key: result1,
      val: variant4,
      timestamp: dataView(memory0).getFloat64(base + 24, true),
      peer: result5,
    });
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="ephemeral-get-all"][Instruction::Return]', {
    funcName: 'ephemeral-get-all',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return result6;
}
let converge010EphemeralMerge;

function ephemeralMerge(arg0, arg1) {
  var vec6 = arg1;
  var len6 = vec6.length;
  var result6 = realloc0(0, 0, 8, len6 * 48);
  for (let i = 0; i < vec6.length; i++) {
    const e = vec6[i];
    const base = result6 + i * 48;var {ns: v0_0, key: v0_1, val: v0_2, timestamp: v0_3, peer: v0_4 } = e;
    var ptr1 = utf8Encode(v0_0, realloc0, memory0);
    var len1 = utf8EncodedLen;
    dataView(memory0).setUint32(base + 4, len1, true);
    dataView(memory0).setUint32(base + 0, ptr1, true);
    var ptr2 = utf8Encode(v0_1, realloc0, memory0);
    var len2 = utf8EncodedLen;
    dataView(memory0).setUint32(base + 12, len2, true);
    dataView(memory0).setUint32(base + 8, ptr2, true);
    var variant4 = v0_2;
    switch (variant4.tag) {
      case 'val-null': {
        dataView(memory0).setInt8(base + 16, 0, true);
        break;
      }
      case 'val-bool': {
        const e = variant4.val;
        dataView(memory0).setInt8(base + 16, 1, true);
        dataView(memory0).setInt8(base + 24, e ? 1 : 0, true);
        break;
      }
      case 'val-int': {
        const e = variant4.val;
        dataView(memory0).setInt8(base + 16, 2, true);
        dataView(memory0).setInt32(base + 24, toInt32(e), true);
        break;
      }
      case 'val-float': {
        const e = variant4.val;
        dataView(memory0).setInt8(base + 16, 3, true);
        dataView(memory0).setFloat64(base + 24, +e, true);
        break;
      }
      case 'val-str': {
        const e = variant4.val;
        dataView(memory0).setInt8(base + 16, 4, true);
        var ptr3 = utf8Encode(e, realloc0, memory0);
        var len3 = utf8EncodedLen;
        dataView(memory0).setUint32(base + 28, len3, true);
        dataView(memory0).setUint32(base + 24, ptr3, true);
        break;
      }
      default: {
        throw new TypeError(`invalid variant tag value \`${JSON.stringify(variant4.tag)}\` (received \`${variant4}\`) specified for \`Value\``);
      }
    }
    dataView(memory0).setFloat64(base + 32, +v0_3, true);
    var ptr5 = utf8Encode(v0_4, realloc0, memory0);
    var len5 = utf8EncodedLen;
    dataView(memory0).setUint32(base + 44, len5, true);
    dataView(memory0).setUint32(base + 40, ptr5, true);
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="ephemeral-merge"][Instruction::CallWasm] enter', {
    funcName: 'ephemeral-merge',
    paramCount: 3,
    async: false,
    postReturn: false,
  });
  const _wasm_call_currentTaskID = startCurrentTask(0, false, 'converge010EphemeralMerge');
  const ret = converge010EphemeralMerge(toUint32(arg0), result6, len6);
  endCurrentTask(0);
  var len13 = dataView(memory0).getUint32(ret + 4, true);
  var base13 = dataView(memory0).getUint32(ret + 0, true);
  var result13 = [];
  for (let i = 0; i < len13; i++) {
    const base = base13 + i * 48;
    var ptr7 = dataView(memory0).getUint32(base + 0, true);
    var len7 = dataView(memory0).getUint32(base + 4, true);
    var result7 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr7, len7));
    var ptr8 = dataView(memory0).getUint32(base + 8, true);
    var len8 = dataView(memory0).getUint32(base + 12, true);
    var result8 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr8, len8));
    let variant11;
    switch (dataView(memory0).getUint8(base + 16, true)) {
      case 0: {
        variant11= {
          tag: 'val-null',
        };
        break;
      }
      case 1: {
        var bool9 = dataView(memory0).getUint8(base + 24, true);
        variant11= {
          tag: 'val-bool',
          val: bool9 == 0 ? false : (bool9 == 1 ? true : throwInvalidBool())
        };
        break;
      }
      case 2: {
        variant11= {
          tag: 'val-int',
          val: dataView(memory0).getInt32(base + 24, true)
        };
        break;
      }
      case 3: {
        variant11= {
          tag: 'val-float',
          val: dataView(memory0).getFloat64(base + 24, true)
        };
        break;
      }
      case 4: {
        var ptr10 = dataView(memory0).getUint32(base + 24, true);
        var len10 = dataView(memory0).getUint32(base + 28, true);
        var result10 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr10, len10));
        variant11= {
          tag: 'val-str',
          val: result10
        };
        break;
      }
      default: {
        throw new TypeError('invalid variant discriminant for Value');
      }
    }
    var ptr12 = dataView(memory0).getUint32(base + 40, true);
    var len12 = dataView(memory0).getUint32(base + 44, true);
    var result12 = utf8Decoder.decode(new Uint8Array(memory0.buffer, ptr12, len12));
    result13.push({
      ns: result7,
      key: result8,
      val: variant11,
      timestamp: dataView(memory0).getFloat64(base + 32, true),
      peer: result12,
    });
  }
  _debugLog('[iface="mizchi:converge/converge@0.1.0", function="ephemeral-merge"][Instruction::Return]', {
    funcName: 'ephemeral-merge',
    paramCount: 1,
    async: false,
    postReturn: false
  });
  return result13;
}

const $init = (() => {
  let gen = (function* _initGenerator () {
    const module0 = fetchCompile(new URL('./converge-component.core.wasm', import.meta.url));
    ({ exports: exports0 } = yield instantiateCore(yield module0));
    memory0 = exports0.memory;
    realloc0 = exports0.cabi_realloc;
    converge010CreateDoc = exports0['mizchi:converge/converge@0.1.0#create-doc'];
    converge010DocInsert = exports0['mizchi:converge/converge@0.1.0#doc-insert'];
    converge010DocUpdate = exports0['mizchi:converge/converge@0.1.0#doc-update'];
    converge010DocDelete = exports0['mizchi:converge/converge@0.1.0#doc-delete'];
    converge010DocMergeRemote = exports0['mizchi:converge/converge@0.1.0#doc-merge-remote'];
    converge010DocGetPending = exports0['mizchi:converge/converge@0.1.0#doc-get-pending'];
    converge010DocSyncState = exports0['mizchi:converge/converge@0.1.0#doc-sync-state'];
    converge010EphemeralSet = exports0['mizchi:converge/converge@0.1.0#ephemeral-set'];
    converge010EphemeralGet = exports0['mizchi:converge/converge@0.1.0#ephemeral-get'];
    converge010EphemeralGetAll = exports0['mizchi:converge/converge@0.1.0#ephemeral-get-all'];
    converge010EphemeralMerge = exports0['mizchi:converge/converge@0.1.0#ephemeral-merge'];
  })();
  let promise, resolve, reject;
  function runNext (value) {
    try {
      let done;
      do {
        ({ value, done } = gen.next(value));
      } while (!(value instanceof Promise) && !done);
      if (done) {
        if (resolve) resolve(value);
        else return value;
      }
      if (!promise) promise = new Promise((_resolve, _reject) => (resolve = _resolve, reject = _reject));
      value.then(runNext, reject);
    }
    catch (e) {
      if (reject) reject(e);
      else throw e;
    }
  }
  const maybeSyncReturn = runNext(null);
  return promise || maybeSyncReturn;
})();

await $init;
const converge010 = {
  createDoc: createDoc,
  docDelete: docDelete,
  docGetPending: docGetPending,
  docInsert: docInsert,
  docMergeRemote: docMergeRemote,
  docSyncState: docSyncState,
  docUpdate: docUpdate,
  ephemeralGet: ephemeralGet,
  ephemeralGetAll: ephemeralGetAll,
  ephemeralMerge: ephemeralMerge,
  ephemeralSet: ephemeralSet,
  
};

export { converge010 as converge, converge010 as 'mizchi:converge/converge@0.1.0',  }