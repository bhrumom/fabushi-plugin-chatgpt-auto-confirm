import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

export const LOCAL_EXECUTOR = Object.freeze({ model: 'gpt-5.6-luna', thinking: 'medium' });
export const digest = text => createHash('sha256').update(String(text)).digest('hex');
const idPattern = /^[a-zA-Z0-9_-]{1,128}$/u;
const hashPattern = /^[a-f0-9]{64}$/u;
const terminal = new Set(['delivered', 'cancelled', 'superseded']);
async function bounded(action) {
  let timer;
  try {
    return await Promise.race([Promise.resolve().then(action), new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('host_timeout')), 10_000);
    })]);
  } finally { clearTimeout(timer); }
}

// No model call happens here. The owning desktop host must keep these callbacks
// alive independently of an agent turn, and deduplicate send() by eventId.
export function handoffAvailable(bridge) {
  return bridge?.independentLifetime === true && bridge?.idempotentDelivery === true
    && typeof bridge?.send === 'function' && typeof bridge?.ownsTask === 'function';
}

export class ReplyHandoff {
  constructor({ stateFile, readSnapshot, bridge, now = Date.now, stableMs = 2000 }) {
    this.stateFile = stateFile;
    this.readSnapshot = readSnapshot;
    this.bridge = bridge;
    this.now = now;
    this.stableMs = stableMs;
    this.watches = new Map();
    this.tail = Promise.resolve();
  }

  serial(action) {
    const result = this.tail.then(action);
    this.tail = result.catch(() => {});
    return result;
  }

  async restore() {
    try {
      const saved = JSON.parse(await readFile(this.stateFile, 'utf8'));
      if (saved.schema !== 1 || !Array.isArray(saved.watches)) throw new Error('invalid_handoff_state');
      for (const watch of saved.watches) {
        this.validate(watch);
        if (!['waiting', 'settling', 'pending', ...terminal].includes(watch.status)) {
          throw new Error('invalid_handoff_status');
        }
        // Stability must be established again after downtime.
        watch.candidate = null;
        this.watches.set(watch.watchId, watch);
      }
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }

  validate(watch) {
    for (const key of ['watchId', 'tabId', 'threadId']) {
      if (!idPattern.test(watch[key] || '')) throw new Error(`invalid_${key}`);
    }
    const url = new URL(watch.conversationUrl);
    if (url.origin !== 'https://chatgpt.com' || url.search || url.hash
        || !/^\/(?:g\/[^/]+\/)?c\/[^/]+$/u.test(url.pathname)) throw new Error('invalid_conversation_url');
    for (const key of ['expectedUserDigest', 'baselineAssistantDigest']) {
      if (!hashPattern.test(watch[key] || '')) throw new Error(`invalid_${key}`);
    }
  }

  async save() {
    await mkdir(dirname(this.stateFile), { recursive: true });
    const temporary = `${this.stateFile}.${randomUUID()}.tmp`;
    await writeFile(temporary, JSON.stringify({ schema: 1, watches: [...this.watches.values()] }), { mode: 0o600 });
    await rename(temporary, this.stateFile);
  }

  register(input) {
    return this.serial(async () => {
      if (!handoffAvailable(this.bridge)) throw new Error('independent_work_bridge_unavailable');
      this.validate(input);
      const binding = Object.fromEntries(['watchId', 'tabId', 'threadId', 'conversationUrl',
        'expectedUserDigest', 'baselineAssistantDigest'].map(key => [key, input[key]]));
      const previous = this.watches.get(input.watchId);
      if (previous) {
        if (Object.keys(binding).some(key => binding[key] !== previous[key])) throw new Error('watch_identity_conflict');
        return this.status(input.watchId);
      }
      if (!await bounded(() => this.bridge.ownsTask(input.threadId))) throw new Error('work_task_not_owned');
      if ([...this.watches.values()].some(w => !terminal.has(w.status) && w.tabId === input.tabId)) {
        throw new Error('tab_already_watched');
      }
      if (this.watches.size >= 1000) throw new Error('handoff_capacity_reached');
      this.watches.set(input.watchId, { ...binding, status: 'waiting', candidate: null,
        eventId: null, retryAt: 0, attempts: 0, diagnostic: null });
      try { await this.save(); }
      catch (error) { this.watches.delete(input.watchId); throw error; }
      return this.status(input.watchId);
    });
  }

  status(watchId) {
    const watch = this.watches.get(watchId);
    if (!watch) throw new Error('watch_not_found');
    return { watchId, status: watch.status, eventId: watch.eventId,
      diagnostic: watch.diagnostic, model: LOCAL_EXECUTOR.model, thinking: LOCAL_EXECUTOR.thinking };
  }

  list() {
    return [...this.watches.values()].map(watch => this.status(watch.watchId));
  }

  cancel(watchId) {
    return this.serial(async () => {
      this.status(watchId);
      const watch = this.watches.get(watchId);
      if (!terminal.has(watch.status)) watch.status = 'cancelled';
      await this.save();
      return this.status(watchId);
    });
  }

  tick() {
    return this.serial(async () => {
      if (!handoffAvailable(this.bridge)) return this.list();
      for (const watch of this.watches.values()) {
        if (terminal.has(watch.status) || watch.retryAt > this.now()) continue;
        try {
          if (!await bounded(() => this.bridge.ownsTask(watch.threadId))) throw new Error('work_task_not_owned');
          const state = await bounded(() => this.readSnapshot(watch));
          if (state.url !== watch.conversationUrl || state.hasComposer !== true
              || state.hasWorkComposer === true) throw new Error('conversation_unavailable');
          if (!state.latestUserText?.trim()) throw new Error('user_turn_unavailable');
          if (digest(state.latestUserText) !== watch.expectedUserDigest) {
            watch.status = 'superseded';
            watch.candidate = null;
            await this.save();
            continue;
          }
          // A pending card, error or partial answer must never generate a wake.
          if (state.stopAnswer !== false || state.pendingAuthorization !== false || state.retry !== false
              || state.pageError === true || !state.latestAssistantText?.trim()) {
            if (watch.candidate || watch.diagnostic !== 'reply_not_ready') {
              watch.candidate = null;
              watch.diagnostic = 'reply_not_ready';
              await this.save();
            }
            continue;
          }
          const fingerprint = digest(state.latestAssistantText);
          if (fingerprint === watch.baselineAssistantDigest) {
            watch.candidate = null;
            continue;
          }
          if (watch.candidate?.digest !== fingerprint) {
            watch.candidate = { digest: fingerprint, since: this.now() };
            watch.status = 'settling';
            await this.save();
            continue;
          }
          if (this.now() - watch.candidate.since < this.stableMs) continue;
          // One event per registered web turn, even if send acknowledged but the
          // process died before saving. Receiver deduplication is mandatory.
          watch.eventId ||= `reply_${digest(watch.watchId + ':' + watch.threadId)}`;
          watch.status = 'pending';
          await this.save();
          const receipt = await bounded(() => this.bridge.send({ eventId: watch.eventId, threadId: watch.threadId,
            ...LOCAL_EXECUTOR,
            prompt: `网页版本轮回复已结束。请读取 ${watch.conversationUrl} 的完整回复，核对项目记录后继续执行和派发。回答结束不代表任务已完成。事件：${watch.eventId}` }));
          if (receipt?.accepted !== true || receipt.eventId !== watch.eventId) throw new Error('wake_not_acknowledged');
          watch.status = 'delivered';
          watch.diagnostic = null;
          await this.save();
        } catch {
          // Do not persist arbitrary exception strings (may contain page text,
          // bridge tokens or credentials). Missing tabs are not completion.
          watch.diagnostic = 'host_or_delivery_unavailable';
          watch.candidate = null;
          watch.attempts += 1;
          watch.retryAt = this.now() + Math.min(60_000, 1000 * 2 ** Math.min(watch.attempts, 6));
          await this.save();
        }
      }
      return this.list();
    });
  }
}
