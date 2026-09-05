import { createInterface } from 'node:readline';
import { existsSync, statSync } from 'node:fs';
import { chmod, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { homedir, platform } from 'node:os';
import { delimiter, dirname, join, resolve } from 'node:path';

// This is deliberately the local executor used by reply-handoff.mjs. The web
// lane remains GPT-5.6 Sol/Extra High; only the local Work wake uses Luna.
export const LOCAL_WORK_MODEL = 'gpt-5.6-luna';
export const LOCAL_WORK_THINKING = 'medium';
export const WORK_BRIDGE_SCHEMA = 'chatgpt-auto-confirm.local-work-bridge.v1';

const DEFAULT_CODEX_PATH = '/Applications/ChatGPT.app/Contents/Resources/codex';
const THREAD_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/u;
const EVENT_ID_PATTERN = /^reply_[a-f0-9]{64}$/u;
const MAX_LEDGER_ENTRIES = 1000;
const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_PROBE_TIMEOUT_MS = 12_000;

function validThreadId(value) {
  return THREAD_ID_PATTERN.test(String(value || ''));
}

function validEventId(value) {
  return EVENT_ID_PATTERN.test(String(value || ''));
}

function normalizeText(value, limit = 4_000) {
  const text = String(value ?? '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/gu, '').trim();
  return text.length > limit ? text.slice(0, limit) : text;
}

function safeTimestamp(now) {
  const value = typeof now === 'function' ? now() : Date.now();
  return new Date(Number.isFinite(value) ? value : Date.now()).toISOString();
}

function configuredCodexPath(explicitPath) {
  const candidates = [
    explicitPath,
    process.env.CHATGPT_AUTO_CONFIRM_CODEX_PATH,
    process.env.CODEX_BINARY,
    DEFAULT_CODEX_PATH,
    'codex',
  ].filter(Boolean).map(String);
  for (const candidate of candidates) {
    const direct = candidate.includes('/') || candidate.includes('\\')
      ? candidate : null;
    if (direct && existsSync(direct)) {
      try { if (statSync(direct).isFile()) return direct; } catch { /* keep looking */ }
    }
    if (!direct) {
      for (const directory of String(process.env.PATH || '').split(delimiter).filter(Boolean)) {
        const resolvedPath = join(directory, candidate);
        if (!existsSync(resolvedPath)) continue;
        try { if (statSync(resolvedPath).isFile()) return resolvedPath; } catch { /* keep looking */ }
      }
    }
  }
  return null;
}

function commandEnvironment(extra = {}) {
  // Do not inherit a caller's shell interpolation or use shell:true. The
  // bridge only passes argv values to the signed-in local Codex executable.
  return { ...process.env, ...extra };
}

async function runProcess(command, args, {
  cwd,
  env,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxOutputBytes = 64 * 1024,
  detached = false,
} = {}) {
  return await new Promise((resolvePromise, rejectPromise) => {
    let child;
    try {
      child = spawn(command, args, {
        cwd,
        env: commandEnvironment(env),
        shell: false,
        detached,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      rejectPromise(error);
      return;
    }
    let stdout = '';
    let stderr = '';
    const append = (current, chunk) => {
      const next = `${current}${String(chunk)}`;
      return next.length > maxOutputBytes ? next.slice(-maxOutputBytes) : next;
    };
    child.stdout?.on('data', chunk => { stdout = append(stdout, chunk); });
    child.stderr?.on('data', chunk => { stderr = append(stderr, chunk); });
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { child.kill('SIGTERM'); } catch { /* child may already be gone */ }
      rejectPromise(new Error('local_work_bridge_process_timeout'));
    }, timeoutMs);
    child.once('error', error => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      rejectPromise(error);
    });
    child.once('close', (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolvePromise({ code, signal, stdout, stderr });
    });
  });
}

async function writeJsonAtomically(path, payload) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(payload)}\n`, { encoding: 'utf8', mode: 0o600 });
  await rename(temporary, path);
  try { await chmod(path, 0o600); } catch { /* Windows may not expose POSIX mode */ }
}

async function loadLedger(path) {
  try {
    const saved = JSON.parse(await readFile(path, 'utf8'));
    if (saved?.schema !== WORK_BRIDGE_SCHEMA || !Array.isArray(saved?.events)) throw new Error('invalid_work_bridge_ledger');
    return new Map(saved.events.filter(event => (
      validEventId(event?.eventId)
        && validThreadId(event?.threadId)
        && ['pending', 'accepted', 'failed'].includes(event?.status)
    )).slice(-MAX_LEDGER_ENTRIES).map(event => [event.eventId, event]));
  } catch (error) {
    if (error?.code === 'ENOENT') return new Map();
    throw error;
  }
}

async function saveLedger(path, events) {
  await writeJsonAtomically(path, {
    schema: WORK_BRIDGE_SCHEMA,
    events: [...events.values()].slice(-MAX_LEDGER_ENTRIES).map(event => ({
      eventId: event.eventId,
      threadId: event.threadId,
      status: event.status,
      acceptedAt: event.acceptedAt || null,
      failedAt: event.failedAt || null,
    })),
  });
}

function jsonRpcLineReader(child) {
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const pending = new Map();
  let nextId = 1;
  let closed = false;
  const failAll = error => {
    if (closed) return;
    closed = true;
    for (const pendingRequest of pending.values()) pendingRequest.reject(error);
    pending.clear();
    try { lines.close(); } catch { /* already closed */ }
  };
  lines.on('line', line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (!Object.prototype.hasOwnProperty.call(message, 'id')) return;
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.error) request.reject(new Error('app_server_request_rejected'));
    else request.resolve(message.result || {});
  });
  child.once('error', failAll);
  child.once('close', (code, signal) => {
    failAll(new Error(`app_server_closed:${code ?? 'none'}:${signal || 'none'}`));
  });
  const request = (method, params, timeoutMs) => new Promise((resolvePromise, rejectPromise) => {
    if (closed || child.stdin.destroyed) {
      rejectPromise(new Error('app_server_not_running'));
      return;
    }
    const id = nextId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      rejectPromise(new Error('app_server_request_timeout'));
    }, timeoutMs);
    pending.set(id, {
      resolve: value => { clearTimeout(timer); resolvePromise(value); },
      reject: error => { clearTimeout(timer); rejectPromise(error); },
    });
    try {
      child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    } catch (error) {
      pending.delete(id);
      clearTimeout(timer);
      rejectPromise(error);
    }
  });
  const notify = (method, params) => {
    if (closed || child.stdin.destroyed) return;
    try { child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method, params })}\n`); } catch { /* process is closing */ }
  };
  return { request, notify, close: () => failAll(new Error('app_server_probe_closed')) };
}

async function probeThreadWithAppServer(codexPath, threadId, timeoutMs) {
  const child = spawn(codexPath, ['app-server', '--listen', 'stdio://'], {
    shell: false,
    stdio: ['pipe', 'pipe', 'ignore'],
    env: commandEnvironment(),
  });
  const rpc = jsonRpcLineReader(child);
  try {
    await rpc.request('initialize', {
      clientInfo: { name: 'chatgpt-auto-confirm', version: '0.1.0' },
      capabilities: {},
    }, timeoutMs);
    rpc.notify('notifications/initialized', {});
    // The bridge only needs ownership metadata. Avoid reconstructing the full
    // turn history during a probe; the actual queued Work turn will read its
    // own context after delivery.
    const result = await rpc.request('thread/resume', { threadId, excludeTurns: true }, timeoutMs);
    const returnedId = result?.thread?.id || result?.threadId || result?.id;
    return String(returnedId || '') === threadId;
  } finally {
    rpc.close();
    try { child.kill('SIGTERM'); } catch { /* probe already exited */ }
  }
}

export class LocalWorkBridge {
  constructor({
    codexPath,
    stateFile = resolve(homedir(), '.codex', 'browser', 'chatgpt-auto-confirm-work-bridge.json'),
    cwd,
    now = Date.now,
    probeThread = probeThreadWithAppServer,
    enqueue = runProcess,
    timeoutMs = DEFAULT_TIMEOUT_MS,
    probeTimeoutMs = DEFAULT_PROBE_TIMEOUT_MS,
    logger = () => {},
  } = {}) {
    this.codexPath = codexPath;
    this.stateFile = stateFile;
    this.cwd = cwd;
    this.now = now;
    this.probeThread = probeThread;
    this.enqueue = enqueue;
    this.timeoutMs = timeoutMs;
    this.probeTimeoutMs = probeTimeoutMs;
    this.logger = logger;
    this.independentLifetime = true;
    this.idempotentDelivery = true;
    // The plugin server owns the observer loop for this adapter. Keeping this
    // marker lets a Browser lease avoid running a second process-local timer
    // against the same persisted handoff file.
    this.serverSupervised = true;
    this.events = new Map();
    this.owned = new Map();
    this.sendLocks = new Map();
    this.ready = this.restore();
  }

  clock() {
    const value = typeof this.now === 'function' ? this.now() : Date.now();
    return Number.isFinite(Number(value)) ? Number(value) : Date.now();
  }

  async restore() {
    this.events = await loadLedger(this.stateFile);
  }

  status() {
    return {
      available: Boolean(this.codexPath),
      transport: this.codexPath ? 'codex-queue' : 'unavailable',
      model: LOCAL_WORK_MODEL,
      thinking: LOCAL_WORK_THINKING,
      ledgerEntries: this.events.size,
    };
  }

  async ownsTask(threadId) {
    await this.ready;
    if (!this.codexPath || !validThreadId(threadId)) return false;
    const cachedAt = this.owned.get(threadId);
    if (cachedAt && this.clock() - cachedAt < 15_000) return true;
    try {
      const owned = await this.probeThread(this.codexPath, threadId, this.probeTimeoutMs);
      if (owned) this.owned.set(threadId, this.clock());
      return owned === true;
    } catch {
      return false;
    }
  }

  async persistEvent(event) {
    this.events.set(event.eventId, event);
    await saveLedger(this.stateFile, this.events);
  }

  async send({ eventId, threadId, model, thinking, prompt }) {
    await this.ready;
    if (!this.codexPath || !validEventId(eventId) || !validThreadId(threadId)
        || model !== LOCAL_WORK_MODEL || thinking !== LOCAL_WORK_THINKING) {
      throw new Error('local_work_bridge_input_rejected');
    }
    const message = normalizeText(prompt);
    if (!message || !message.includes(eventId)) throw new Error('local_work_bridge_event_marker_missing');
    const existing = this.events.get(eventId);
    if (existing && existing.threadId !== threadId) {
      throw new Error('local_work_bridge_event_identity_conflict');
    }
    if (existing?.status === 'accepted' && existing.threadId === threadId) {
      return { accepted: true, eventId, deduplicated: true };
    }
    const previousLock = this.sendLocks.get(eventId) || Promise.resolve();
    const operation = previousLock.then(async () => {
      const current = this.events.get(eventId);
      if (current && current.threadId !== threadId) {
        throw new Error('local_work_bridge_event_identity_conflict');
      }
      if (current?.status === 'accepted' && current.threadId === threadId) {
        return { accepted: true, eventId, deduplicated: true };
      }
      if (!await this.ownsTask(threadId)) throw new Error('work_task_not_owned');
      const pending = {
        eventId, threadId, status: 'pending', acceptedAt: null, failedAt: null,
      };
      await this.persistEvent(pending);
      const invocation = await this.enqueue(this.codexPath, [
        'queue', '--thread', threadId, '--message', message,
        '--model', LOCAL_WORK_MODEL,
        '-c', 'model_reasoning_effort="medium"',
        '--approve-for-me',
      ], {
        cwd: this.cwd,
        timeoutMs: this.timeoutMs,
        maxOutputBytes: 32 * 1024,
      });
      if (invocation?.code !== 0) {
        const failed = { ...pending, status: 'failed', failedAt: safeTimestamp(this.now) };
        await this.persistEvent(failed);
        throw new Error('local_work_bridge_enqueue_failed');
      }
      const accepted = { ...pending, status: 'accepted', acceptedAt: safeTimestamp(this.now) };
      await this.persistEvent(accepted);
      this.logger({ event: 'local_work_wake_accepted', eventId, threadId });
      return { accepted: true, eventId, deduplicated: false };
    });
    const settledOperation = operation.catch(() => {});
    this.sendLocks.set(eventId, settledOperation);
    try { return await operation; } finally {
      if (this.sendLocks.get(eventId) === settledOperation) this.sendLocks.delete(eventId);
    }
  }
}

export function createLocalWorkBridge(options = {}) {
  const enabled = options.enabled !== false
    && process.env.CHATGPT_AUTO_CONFIRM_WORK_BRIDGE !== '0';
  if (!enabled) return null;
  const codexPath = configuredCodexPath(options.codexPath);
  if (!codexPath) return null;
  return new LocalWorkBridge({ ...options, codexPath });
}

export function localWorkBridgeAvailable(options = {}) {
  const enabled = options.enabled !== false
    && process.env.CHATGPT_AUTO_CONFIRM_WORK_BRIDGE !== '0';
  return enabled && Boolean(configuredCodexPath(options.codexPath));
}

// This command is intentionally read-only. It is useful to verify the
// executable path without starting a model turn.
export function localWorkBridgeDescriptor(options = {}) {
  const codexPath = configuredCodexPath(options.codexPath);
  const enabled = options.enabled !== false && process.env.CHATGPT_AUTO_CONFIRM_WORK_BRIDGE !== '0';
  const available = enabled && Boolean(codexPath);
  return {
    enabled,
    available,
    platform: platform(),
    model: LOCAL_WORK_MODEL,
    thinking: LOCAL_WORK_THINKING,
    transport: available ? 'codex-queue' : 'unavailable',
  };
}
