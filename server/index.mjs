import readline from 'node:readline';
import { existsSync } from 'node:fs';
import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { dirname, resolve } from 'node:path';
import worker from '../worker/src/index.ts';
import {
  DEFAULT_BROWSER_HEARTBEAT_SLICE_MS,
  parseTaskReport,
} from '../scripts/in-app-browser-capability-host.mjs';
import { localWorkBridgeDescriptor } from '../scripts/local-work-bridge.mjs';

const defaultNativeRuntime = fileURLToPath(new URL(
  '../runtime/macos/chatgpt-auto-confirm', import.meta.url));
const browserCapabilityHostModule = fileURLToPath(new URL(
  '../scripts/in-app-browser-capability-host.mjs', import.meta.url));
const nativeRuntime = process.env.CHATGPT_AUTO_CONFIRM_NATIVE || defaultNativeRuntime;
const windowsCredentialScript = fileURLToPath(new URL(
  '../scripts/sync-actions-credentials.ps1', import.meta.url));
const windowsCredentialTools = new Set([
  'sync_actions_credentials',
  'login_and_sync_actions',
]);
const browserCapabilityFile = process.env.CHATGPT_AUTO_CONFIRM_BROWSER_CAPABILITY_FILE
  || resolve(homedir(), '.codex', 'browser', 'chatgpt-auto-confirm-capability.json');
const browserJobStateFile = process.env.CHATGPT_AUTO_CONFIRM_BROWSER_JOB_FILE
  || resolve(homedir(), '.codex', 'browser', 'chatgpt-auto-confirm-job.json');
const browserSupervisors = new Map();
let replyHandoffSupervisor = null;
const desktopDirectJobs = new Map();
const sleep = milliseconds => new Promise(resolvePromise => setTimeout(resolvePromise, milliseconds));
const browserTerminalStatuses = new Set(['completed', 'stopped', 'failed']);
const replyHandoffTerminalStatuses = new Set(['delivered', 'cancelled', 'superseded']);
const maxParallelBrowserJobs = 2;
const configuredBrowserHostRetryDelayMs = Number(process.env.CHATGPT_AUTO_CONFIRM_BROWSER_RETRY_MS);
const browserHostRetryDelayMs = Number.isFinite(configuredBrowserHostRetryDelayMs)
  ? Math.min(60_000, Math.max(500, configuredBrowserHostRetryDelayMs))
  : 5_000;
const browserHeartbeatSliceMs = DEFAULT_BROWSER_HEARTBEAT_SLICE_MS;
const pluginDispatchParams = (goal) => ({
  message: goal,
  browser: 'iab',
  capability: 'browser.in-app.dispatch-and-watch',
  connector: null,
  model: 'GPT-5.6 Sol',
  reasoning: 'Extra High',
  surface: 'chat',
  newChat: true,
  resumeExisting: false,
  // Compatibility metadata only; continuations are always fresh Chat
  // boundaries and are never direct goal-only sends.
  goalOnlyDispatch: false,
  approveAll: true,
  timeout: 21_600,
  stagnationTimeout: 10_800,
  noFinalReplyTimeout: 300,
  maxRecoveryAttempts: 5,
  autoContinueIncomplete: true,
  maxTaskContinuations: 0,
  continuationMessage: null,
  maxConcurrentJobs: maxParallelBrowserJobs,
  pollIntervalMs: 500,
});

function browserReattachMetadata(job) {
  return {
    required: true,
    modulePath: browserCapabilityHostModule,
    factory: 'attachPersistentInAppBrowserCapabilityHost',
    runMethod: 'runUntilTerminal',
    runOptions: {
      leaseTimeoutMs: browserHeartbeatSliceMs,
      returnOnLeaseExpiry: true,
    },
    browser: 'iab',
    startUrl: String(job?.currentUrl || '').startsWith('https://chatgpt.com/')
      ? job.currentUrl : 'https://chatgpt.com/',
    preferredTabId: job?.tabId || null,
    jobId: job?.id || null,
    preservesExistingJob: true,
  };
}
const nativeCommands = new Map([
  ['account_list', 'account_list'], ['account_add', 'account_add'],
  ['account_login_link', 'account_login_link'], ['account_switch', 'account_switch'],
  ['account_rename', 'account_rename'], ['account_status', 'account_status'],
  ['account_sync', 'account_sync'], ['account_remove', 'account_remove'],
  ['start', 'start'], ['stop', 'stop'], ['status', 'status'],
  ['scan_once', 'scan'], ['relaunch_and_confirm', 'relaunch_and_confirm'],
  ['audit_log', 'audit'], ['diagnose', 'diagnose'],
  ['send_and_watch', 'send_and_watch'],
  ['add_connector', 'add_connector'],
  ['get_reply', 'get_reply'], ['chat_status', 'chat_status'],
  ['enqueue_tasks', 'queue_enqueue'], ['start_queue', 'queue_start'],
  ['queue_status', 'queue_status'], ['update_task', 'queue_update'],
  ['wait_for_review', 'queue_wait_review'],
  ['start_actions_runner', 'start_actions_runner'],
  ['sync_actions_credentials', 'sync_actions_credentials'],
  ['login_and_sync_actions', 'login_and_sync_actions'],
  ['review_task', 'queue_review'], ['pause_queue', 'queue_pause'],
  ['resume_queue', 'queue_resume'], ['retry_task', 'queue_retry'],
  ['cancel_task', 'queue_cancel'],
]);

function nativeToolResponse(rpc, tool, structuredContent) {
  return {
    jsonrpc: '2.0', id: rpc.id,
    result: {
      content: [{ type: 'text', text: structuredContent.ok === false
        ? `Native command failed: ${structuredContent.message || structuredContent.errorCode}`
        : `Native command completed: ${tool}` }],
      structuredContent,
      isError: structuredContent.ok === false,
    },
  };
}

function browserToolResponse(rpc, tool, structuredContent) {
  const failed = structuredContent?.ok === false;
  return {
    jsonrpc: '2.0', id: rpc.id,
    result: {
      content: [{ type: 'text', text: failed
        ? `内置 Browser capability 执行失败：${structuredContent.message || structuredContent.errorCode}`
        : `内置 Browser capability 已处理 ${tool}。` }],
      structuredContent,
      isError: failed,
    },
  };
}

async function readBrowserCapability() {
  let descriptor;
  try {
    descriptor = JSON.parse(await readFile(browserCapabilityFile, 'utf8'));
  } catch {
    return {
      ok: false,
      errorCode: 'browser_capability_unavailable',
      message: '当前没有已授权的内置 Browser capability；请先在受信任的内置 Browser 宿主中启用它。',
    };
  }
  const baseUrl = String(descriptor?.baseUrl || '');
  const validBaseUrl = /^http:\/\/127\.0\.0\.1:\d{1,5}$/u.test(baseUrl);
  if (descriptor?.schema !== 'chatgpt-auto-confirm.browser-capability.v1'
      || descriptor?.capability !== 'browser.in-app.dispatch-and-watch'
      || !validBaseUrl || typeof descriptor?.token !== 'string' || descriptor.token.length < 32
      || !Number.isFinite(Number(descriptor?.expiresAt)) || Date.now() >= Number(descriptor.expiresAt)) {
    return {
      ok: false,
      errorCode: 'browser_capability_invalid',
      message: '内置 Browser capability 文件无效、已过期或授权范围不匹配。',
    };
  }
  return { ok: true, ...descriptor, baseUrl };
}

async function callBrowserCapability(
  descriptor, pathname, method = 'GET', body = undefined, timeoutMs = 30_000,
) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${descriptor.baseUrl}${pathname}`, {
      method,
      signal: controller.signal,
      headers: {
        authorization: `Bearer ${descriptor.token}`,
        ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let payload;
    try {
      payload = await response.json();
    } catch {
      payload = { ok: false, errorCode: 'browser_capability_invalid_response', message: `HTTP ${response.status}` };
    }
    if (!response.ok && payload.ok !== false) {
      return { ok: false, errorCode: 'browser_capability_http_error', message: `HTTP ${response.status}`, response: payload };
    }
    return payload;
  } catch (error) {
    return {
      ok: false,
      errorCode: error?.name === 'AbortError' ? 'browser_capability_timeout' : 'browser_capability_connection_failed',
      message: String(error?.message || error),
    };
  } finally {
    clearTimeout(timer);
  }
}

function browserStateJobs(saved) {
  if (Array.isArray(saved?.jobs)) return saved.jobs;
  return saved && typeof saved === 'object' ? [saved] : [];
}

function revivePersistedBrowserJob(saved) {
  const outcome = String(saved?.lastOutcome?.kind || '');
  const recoverableFailure = saved?.status === 'failed'
    && saved?.stopRequested !== true
    && saved?.phase !== 'terminal'
    && outcome !== 'complete'
    && outcome !== 'stopped';
  if (!saved || typeof saved !== 'object' || !saved.id || !saved.goal
      || (browserTerminalStatuses.has(saved.status) && !recoverableFailure)) return null;
  return recoverableFailure
    ? {
      ...saved,
      status: 'waiting_for_browser_host',
      error: '内置 Browser/CDP 暂时不可用，插件将自动恢复同一任务。',
    }
    : saved;
}

async function readPersistedBrowserJobs() {
  try {
    const saved = JSON.parse(await readFile(browserJobStateFile, 'utf8'));
    return browserStateJobs(saved).map(revivePersistedBrowserJob).filter(Boolean);
  } catch {
    return [];
  }
}

async function readPersistedBrowserJob() {
  return (await readPersistedBrowserJobs())[0] || null;
}

async function writePersistedBrowserJobs(jobs) {
  const persisted = jobs.length === 1
    ? jobs[0]
    : {
      schema: 'chatgpt-auto-confirm.browser-jobs.v2',
      maxConcurrentJobs: maxParallelBrowserJobs,
      jobs,
    };
  await mkdir(dirname(browserJobStateFile), { recursive: true });
  await writeFile(browserJobStateFile, `${JSON.stringify(persisted)}\n`, {
    encoding: 'utf8', mode: 0o600,
  });
  await chmod(browserJobStateFile, 0o600);
}

async function stopPersistedBrowserJob(jobId) {
  let saved;
  try {
    saved = JSON.parse(await readFile(browserJobStateFile, 'utf8'));
  } catch {
    return null;
  }
  const jobs = browserStateJobs(saved);
  const job = jobs.find(candidate => candidate?.id === jobId);
  if (!job) return null;
  if (!browserTerminalStatuses.has(job.status)) {
    job.status = 'stopped';
    job.responseRunning = false;
    job.error = job.error || '已由用户停止内置 Browser 任务';
    job.lastOutcome = { kind: 'stopped', reason: 'operator' };
    job.updatedAt = new Date().toISOString();
    await writePersistedBrowserJobs(jobs);
  }
  browserSupervisors.delete(jobId);
  return job;
}

function startBrowserSupervisor(jobId) {
  if (!jobId || browserSupervisors.has(jobId)) return;
  const supervisor = (async () => {
    while (true) {
      const persisted = (await readPersistedBrowserJobs()).find(job => job.id === jobId);
      if (!persisted) break;
      // Reload the capability descriptor on every pass. A new authorized
      // Browser host can therefore replace a dead tab/context without
      // requiring the caller to dispatch the goal again.
      const descriptor = await readBrowserCapability();
      if (!descriptor.ok) {
        await sleep(browserHostRetryDelayMs);
        continue;
      }
      const health = await callBrowserCapability(
        descriptor, '/v1/capability', 'GET', undefined, 5_000,
      );
      if (!health?.ok) {
        await sleep(browserHostRetryDelayMs);
        continue;
      }
      const healthJobs = Array.isArray(health.jobs)
        ? health.jobs : [health.activeJob].filter(Boolean);
      const observedJob = healthJobs.find(job => job?.id === jobId) || persisted;
      if (browserTerminalStatuses.has(observedJob.status)) break;
      // The trusted Browser host already runs the single-flight pump. Avoid
      // issuing a second HTTP step every 500 ms while that pump is active;
      // the server supervisor only needs to keep polling for a host rotation.
      if (health.pumpActive === true) {
        await sleep(Math.max(1_000, browserHostRetryDelayMs));
        continue;
      }
      const result = await callBrowserCapability(
        descriptor, '/v1/chat/step', 'POST', { jobId }, 90_000,
      );
      if (!result?.ok) {
        // The host may be restarting, its token may have rotated, or the
        // Browser context may have ended. Keep the persisted goal and retry
        // against the next descriptor instead of abandoning the queue.
        await sleep(browserHostRetryDelayMs);
        continue;
      }
      const status = result.job?.status;
      if (browserTerminalStatuses.has(status)) break;
      // waiting_for_browser_host is deliberately non-terminal. The next
      // pass can observe a freshly attached capability and resume the same
      // persisted job without resending the previous round's progress.
      await sleep(status === 'waiting_for_browser_host' ? browserHostRetryDelayMs : 500);
    }
  })().catch(() => {}).finally(() => {
    browserSupervisors.delete(jobId);
  });
  browserSupervisors.set(jobId, supervisor);
}

function maybeStartBrowserSupervisor(result) {
  const jobs = Array.isArray(result?.jobs)
    ? result.jobs : [result?.job || result?.activeJob].filter(Boolean);
  if (result?.ok) {
    for (const job of jobs) {
      if (job?.id && !browserTerminalStatuses.has(job.status)) startBrowserSupervisor(job.id);
    }
  }
}

async function resumePersistedBrowserSupervisor() {
  for (const job of await readPersistedBrowserJobs()) startBrowserSupervisor(job.id);
}

function replyHandoffWatches(result) {
  return Array.isArray(result?.replyHandoffWatches)
    ? result.replyHandoffWatches.filter(Boolean) : [];
}

// Reply handoff observation is intentionally owned by the plugin server, not
// by the model turn that registered it. The trusted Browser host exposes one
// bounded `tick` endpoint; this loop keeps checking that endpoint after the
// caller's turn has returned and stops as soon as every watch is terminal.
function startReplyHandoffSupervisor() {
  if (replyHandoffSupervisor) return;
  const supervisor = (async () => {
    let unavailableSince = 0;
    while (true) {
      const descriptor = await readBrowserCapability();
      if (!descriptor.ok) {
        unavailableSince ||= Date.now();
        // Preserve watches across a short Browser lease rotation. If the
        // descriptor never returns, bound this background loop so an orphaned
        // capability cannot keep a process alive forever.
        if (Date.now() - unavailableSince > 7 * 24 * 60 * 60 * 1000) break;
        await sleep(browserHostRetryDelayMs);
        continue;
      }
      unavailableSince = 0;
      const health = await callBrowserCapability(
        descriptor, '/v1/capability', 'GET', undefined, 5_000,
      );
      if (!health?.ok) {
        await sleep(browserHostRetryDelayMs);
        continue;
      }
      const watches = replyHandoffWatches(health);
      if (watches.length === 0) break;
      if (watches.every(watch => replyHandoffTerminalStatuses.has(watch.status))) break;
      const result = await callBrowserCapability(
        descriptor,
        '/v1/reply-handoff',
        'POST',
        { action: 'tick', watchId: watches[0]?.watchId },
        15_000,
      );
      if (!result?.ok) {
        await sleep(browserHostRetryDelayMs);
        continue;
      }
      const updated = Array.isArray(result.watches) ? result.watches : [];
      if (updated.length > 0
          && updated.every(watch => replyHandoffTerminalStatuses.has(watch.status))) break;
      await sleep(1_000);
    }
  })().catch(() => {}).finally(() => {
    replyHandoffSupervisor = null;
  });
  replyHandoffSupervisor = supervisor;
}

async function resumePersistedReplyHandoffSupervisor() {
  const descriptor = await readBrowserCapability();
  if (!descriptor.ok) return;
  const health = await callBrowserCapability(
    descriptor, '/v1/capability', 'GET', undefined, 5_000,
  );
  if (replyHandoffWatches(health).some(watch => !replyHandoffTerminalStatuses.has(watch.status))) {
    startReplyHandoffSupervisor();
  }
}

function resultBrowserJobs(result, fallback = []) {
  if (Array.isArray(result?.jobs)) return result.jobs.filter(Boolean);
  if (Array.isArray(result?.activeJobs)) return result.activeJobs.filter(Boolean);
  if (result?.job) return [result.job];
  if (result?.activeJob) return [result.activeJob];
  return fallback.filter(Boolean);
}

function waitingForBrowserHost(jobs) {
  return jobs.filter(job => (
    job?.status === 'waiting_for_browser_host' || job?.status === 'reattaching_browser_host'
  ));
}

// The desktop ChatGPT renderer has a real Chat surface, but its model picker
// and Apps menu can change labels between releases. Keep the direct desktop
// path small and conservative: it only talks to the plugin-owned debugging
// port, validates the Chat surface, uses native CDP pointer/input events, and
// requires a matching user-message bubble before reporting success. It uses
// the same Work -> fresh planner -> raw next_task -> fresh Work state machine
// as the Browser/native paths, but keeps the desktop transport opt-in for
// compatibility.
function desktopCDPPort(argumentsObject = {}) {
  const configured = Number(
    argumentsObject.backgroundPort
      || process.env.CHATGPT_AUTO_CONFIRM_BACKGROUND_PORT
      || 9324,
  );
  return Number.isInteger(configured) && configured > 0 && configured < 65_536
    ? configured : 9324;
}

async function desktopCDPRequest(port, path, timeoutMs = 5_000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

async function desktopTargets(port) {
  const targets = await desktopCDPRequest(port, '/json/list');
  return Array.isArray(targets) ? targets : [];
}

async function desktopTarget(port, preferredTargetId = null) {
  const targets = await desktopTargets(port);
  const eligible = targets.filter(candidate => (
    candidate?.type === 'page'
      && String(candidate.url || '').startsWith('app://-/index.html')
      && !String(candidate.url || '').includes('/avatar-overlay')
      && typeof candidate.webSocketDebuggerUrl === 'string'
  ));
  return eligible.find(candidate => candidate.id === preferredTargetId) || eligible[0] || null;
}

async function desktopCDPCall(target, method, params = {}, timeoutMs = 5_000) {
  if (!target?.webSocketDebuggerUrl || typeof WebSocket !== 'function') {
    throw new Error('desktop_cdp_websocket_unavailable');
  }
  return await new Promise((resolvePromise, rejectPromise) => {
    const socket = new WebSocket(target.webSocketDebuggerUrl);
    const id = Math.floor(Math.random() * 2_000_000_000) + 1;
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.close(); } catch {}
      callback(value);
    };
    const timer = setTimeout(
      () => finish(rejectPromise, new Error(`desktop_cdp_timeout:${method}`)),
      timeoutMs,
    );
    socket.addEventListener('open', () => {
      try {
        socket.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        finish(rejectPromise, error);
      }
    });
    socket.addEventListener('message', event => {
      let response;
      try {
        response = JSON.parse(String(event.data));
      } catch {
        return;
      }
      if (response.id !== id) return;
      if (response.error) {
        finish(rejectPromise, new Error(response.error.message || `desktop_cdp_error:${method}`));
      } else {
        finish(resolvePromise, response.result || {});
      }
    });
    socket.addEventListener('error', event => {
      finish(rejectPromise, new Error(event?.message || `desktop_cdp_socket_error:${method}`));
    });
  });
}

async function desktopEvaluate(target, expression, timeoutMs = 5_000) {
  const result = await desktopCDPCall(target, 'Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: true,
    userGesture: true,
  }, timeoutMs);
  if (result?.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || 'desktop_runtime_evaluation_failed');
  }
  return result?.result?.value;
}

async function desktopPointerClick(target, x, y) {
  const point = { x: Number(x), y: Number(y), button: 'left', clickCount: 1 };
  await desktopCDPCall(target, 'Input.dispatchMouseEvent', {
    type: 'mousePressed', ...point,
  });
  await desktopCDPCall(target, 'Input.dispatchMouseEvent', {
    type: 'mouseReleased', ...point,
  });
}

async function desktopClickByExpression(target, expression) {
  const candidate = await desktopEvaluate(target, expression);
  if (!candidate || !Number.isFinite(Number(candidate.x)) || !Number.isFinite(Number(candidate.y))) {
    return null;
  }
  await desktopPointerClick(target, candidate.x, candidate.y);
  return candidate;
}

const desktopSurfaceExpression = `(() => {
  const input = document.querySelector('#prompt-textarea')
    || document.querySelector('[contenteditable="true"]');
  const workComposer = !!document.querySelector('[data-codex-composer="true"]');
  const labels = [...document.querySelectorAll('button, [role="button"]')]
    .map(button => [button.innerText, button.textContent, button.getAttribute('aria-label')]
      .filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim().toLowerCase());
  const chatMode = labels.some(label => label.includes('当前模式：chatgpt')
    || label.includes('current mode: chatgpt') || label === 'chatgpt'
    || label === '聊天' || label === 'chat');
  return {
    ok: !!input && !workComposer && chatMode,
    hasInput: !!input,
    workComposer,
    chatMode,
    visibility: document.visibilityState,
    url: window.location.href || '',
    conversationId: document.querySelector('[data-above-composer-conversation-id]')
      ?.getAttribute('data-above-composer-conversation-id') || null,
  };
})()`;

const desktopChatButtonExpression = `(() => {
  const visible = element => {
    const rect = element?.getBoundingClientRect?.();
    return !!rect && (rect.width || rect.height || element.offsetParent !== null);
  };
  const labels = new Set(['聊天', 'chat']);
  const candidates = [...document.querySelectorAll('button, [role="button"], [role="tab"]')]
    .filter(element => visible(element)
      && !element.closest('aside')
      && labels.has((element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase()));
  const element = candidates[0];
  if (!element) return null;
  const rect = element.getBoundingClientRect();
  return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
})()`;

const desktopNewChatExpression = `(() => {
  const visible = element => {
    const rect = element?.getBoundingClientRect?.();
    return !!rect && (rect.width || rect.height || element.offsetParent !== null);
  };
  const labels = new Set([
    '新聊天', '新对话', '新建任务', '新任务',
    'new chat', 'new conversation', 'new task',
  ]);
  const candidates = [...document.querySelectorAll('button, [role="button"]')]
    .filter(element => visible(element)
      && labels.has((element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase())
      && !element.closest('[role="menu"], [role="listbox"]'));
  const element = candidates[0];
  if (!element) return null;
  const rect = element.getBoundingClientRect();
  return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
})()`;

function desktopConnectorExpression(connector) {
  const needle = JSON.stringify(String(connector || '').trim().toLowerCase());
  return `(() => {
    const needle = ${needle};
    const visible = element => {
      const rect = element?.getBoundingClientRect?.();
      return !!rect && (rect.width || rect.height || element.offsetParent !== null);
    };
    const input = document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    const form = input?.closest('form') || input?.parentElement?.parentElement || null;
    const formText = (form?.innerText || '').replace(/\\s+/g, ' ').toLowerCase();
    const selected = [...(form?.querySelectorAll(
      '[data-connector-id], [data-app-name], [aria-checked="true"], [data-state="checked"], '
        + '[data-selected="true"], [data-active="true"], [data-prompt-link-label], [data-prompt-link-href]'
    ) || [])].some(element => visible(element)
      && [element.innerText, element.textContent, element.getAttribute('data-connector-id'),
        element.getAttribute('data-app-name'), element.getAttribute('data-prompt-link-label'),
        element.getAttribute('data-prompt-link-href')]
        .filter(Boolean).join(' ').toLowerCase().includes(needle));
    return { selected, formText: formText.slice(0, 1200) };
  })()`;
}

function desktopConnectorMenuExpression(connector) {
  const needle = JSON.stringify(String(connector || '').trim().toLowerCase());
  return `(() => {
    const needle = ${needle};
    const visible = element => {
      const rect = element?.getBoundingClientRect?.();
      return !!rect && (rect.width || rect.height || element.offsetParent !== null);
    };
    const candidates = [...document.querySelectorAll(
      '[data-composer-overlay-floating-ui] button, [role="menu"] button, '
        + '[role="listbox"] button, [role="menuitem"], [role="option"], '
        + 'button[data-list-navigation-item="true"]'
    )].filter(element => visible(element)
      && !element.closest('aside')
      && (element.innerText || element.textContent || element.getAttribute('aria-label') || '')
        .replace(/\\s+/g, ' ').toLowerCase().includes(needle));
    const element = candidates.find(candidate => !candidate.querySelector('button')) || candidates.at(-1);
    if (!element) return null;
    const rect = element.getBoundingClientRect();
    const pressed = {
      bubbles: true, cancelable: true, composed: true, button: 0, buttons: 1,
      clientX: rect.left + Math.min(12, Math.max(1, rect.width / 2)),
      clientY: rect.top + Math.min(12, Math.max(1, rect.height / 2))
    };
    element.dispatchEvent(new PointerEvent('pointerdown', {
      ...pressed, pointerId: 1, pointerType: 'mouse', isPrimary: true
    }));
    element.dispatchEvent(new MouseEvent('mousedown', pressed));
    element.dispatchEvent(new PointerEvent('pointerup', {
      ...pressed, buttons: 0, pointerId: 1, pointerType: 'mouse', isPrimary: true
    }));
    element.dispatchEvent(new MouseEvent('mouseup', { ...pressed, buttons: 0 }));
    element.dispatchEvent(new MouseEvent('click', { ...pressed, buttons: 0 }));
    return { clicked: true, x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  })()`;
}

function desktopConnectorNativeClickExpression(connector) {
  const needle = JSON.stringify(String(connector || '').trim().toLowerCase());
  return `(() => {
    const needle = ${needle};
    const visible = element => {
      const rect = element?.getBoundingClientRect?.();
      return !!rect && (rect.width || rect.height || element.offsetParent !== null);
    };
    const candidates = [...document.querySelectorAll(
      '[data-composer-overlay-floating-ui] button, [role="menu"] button, '
        + '[role="listbox"] button, [role="menuitem"], [role="option"], '
        + 'button[data-list-navigation-item="true"]'
    )].filter(element => visible(element)
      && !element.closest('aside')
      && (element.innerText || element.textContent || element.getAttribute('aria-label') || '')
        .replace(/\\s+/g, ' ').toLowerCase().includes(needle));
    const element = candidates.find(candidate => !candidate.querySelector('button')) || candidates.at(-1);
    if (!element) return null;
    element.click();
    return true;
  })()`;
}

// Detect an authorization card from its shape, not from the connector name or
// the request text.  ChatGPT has shipped several card variants, so the probe
// intentionally accepts a small family of accessible decision labels and
// requires card-level evidence before acting on a lone "Allow" button.
function desktopApprovalExpression({ invokeClick = false } = {}) {
  const clickSnippet = invokeClick
    ? 'try { selected.action.click(); } catch (_) {}'
    : '';
  const clickedValue = invokeClick ? 'true' : 'false';
  return `(() => {
    const normalize = value => String(value ?? '').replace(/\\s+/g, ' ').trim().toLowerCase();
    const cleanLabel = value => normalize(value)
      .replace(/\\s*[\\(（\\[]?\\s*(?:esc|escape|enter|return|\\u21b5|\\u23ce|\\u238b|cmd\\s*enter|ctrl\\s*enter|⌘\\s*enter)\\s*[\\)）\\]]?\\s*$/i, '')
      .trim();
    const visible = element => {
      const rect = element?.getBoundingClientRect?.();
      return !!rect && (rect.width || rect.height || element.offsetParent !== null);
    };
    const enabled = element => visible(element) && !element.disabled
      && element.getAttribute('aria-disabled') !== 'true';
    const labelsFor = element => [...new Set([
      element?.getAttribute?.('aria-label'),
      element?.innerText,
      element?.textContent,
      element?.getAttribute?.('title')
    ].map(cleanLabel).filter(Boolean))];
    const allowLabels = new Set([
      'allow', 'allow once', 'allow this time', 'approve', 'approve once',
      'confirm', 'confirm once', 'authorize', 'authorize once', 'grant',
      'grant once', 'full access', 'complete access', '允许', '允许一次',
      '同意', '同意一次', '确认', '确认一次', '授权', '授权一次',
      '完全访问', '完整访问'
    ]);
    const rejectLabels = new Set([
      'deny', 'deny once', 'reject', 'reject once', 'cancel', 'not now',
      '拒绝', '拒绝一次', '不允许', '不允许一次', '取消', '暂不'
    ]);
    const isAllow = element => labelsFor(element).some(label => allowLabels.has(label));
    const isReject = element => labelsFor(element).some(label => rejectLabels.has(label));
    const decisionButtons = container => [...new Set([
      ...container.querySelectorAll('button, a, [role="button"]')
    ])].filter(enabled);
    const hasApprovalMetadata = element => {
      let node = element;
      for (let ancestorIndex = 0; ancestorIndex < 15 && node; ancestorIndex += 1) {
        const structuralAttributes = [...(node.attributes || [])].some(attribute =>
          /^(?:data-|aria-|role$)/i.test(attribute.name)
          && /(?:approval|authorize|authorization|permission|consent|access|tool)/i.test(
            attribute.name === 'role' ? attribute.value : (attribute.name + ' ' + attribute.value)
          ));
        if (structuralAttributes || node.getAttribute?.('aria-modal') === 'true') return true;
        const reactKeys = Object.keys(node).filter(key =>
          key.startsWith('__reactFiber$') || key.startsWith('__reactProps$'));
        for (const reactKey of reactKeys) {
          const queue = [node[reactKey]];
          const seen = new Set();
          for (let visit = 0; visit < 80 && queue.length; visit += 1) {
            const current = queue.shift();
            if (!current || (typeof current !== 'object' && typeof current !== 'function')
                || seen.has(current)) continue;
            seen.add(current);
            let keys = [];
            try { keys = Object.keys(current); } catch (_) { continue; }
            if (keys.some(key => /(?:jit_plugin_data|pluginData|allow_once|allowOnce|target_message_id|targetMessageId|requiresApproval|requires_authorization|authorization|permission|consent|approval)/i.test(key))) {
              return true;
            }
            for (const key of keys) {
              if (/^(?:memoizedProps|pendingProps|props|return|child|sibling|stateNode|memoizedState)$/i.test(key)) {
                try { queue.push(current[key]); } catch (_) {}
              }
            }
          }
        }
        node = node.parentElement;
      }
      return false;
    };
    const hasDialogSemantics = element => {
      const role = normalize(element.getAttribute?.('role'));
      if (role === 'dialog' || role === 'alertdialog' || element.getAttribute?.('aria-modal') === 'true') return true;
      return [...(element.attributes || [])].some(attribute =>
        /^(?:data-testid|data-test|data-state|class|id)$/i.test(attribute.name)
        && /(?:approval|authorize|authorization|permission|consent|access|tool-?call)/i.test(attribute.value || '')
      );
    };
    const cardFor = action => {
      let container = action.parentElement;
      for (let depth = 0; depth < 15 && container && container !== document.body; depth += 1) {
        const buttons = decisionButtons(container);
        const allowButtons = buttons.filter(isAllow);
        const rejectButtons = buttons.filter(isReject);
        const compact = buttons.length > 0 && buttons.length <= 16;
        const unlabeledAllow = allowButtons.length === 0 && rejectButtons.length === 1
          && buttons.length === 2
          ? buttons.filter(button => labelsFor(button).length === 0)
          : [];
        const actionButtons = allowButtons.length > 0 ? allowButtons : unlabeledAllow;
        const paired = compact && actionButtons.length > 0 && rejectButtons.length > 0;
        const semantic = compact && allowButtons.length > 0 && hasDialogSemantics(container);
        const metadata = compact && allowButtons.length > 0 && hasApprovalMetadata(container);
        if (paired || semantic || metadata) {
          return {
            container,
            action: actionButtons[0],
            buttons,
            reason: paired ? 'paired-decision-buttons' : semantic ? 'approval-card-semantics' : 'approval-react-metadata'
          };
        }
        container = container.parentElement;
      }
      return null;
    };
    const allButtons = [...document.querySelectorAll('button, a, [role="button"]')]
      .filter(enabled);
    const candidates = [];
    const seenActions = new Set();
    for (const button of allButtons.filter(isAllow).concat(allButtons.filter(isReject))) {
      const card = cardFor(button);
      if (!card || seenActions.has(card.action)) continue;
      seenActions.add(card.action);
      candidates.push(card);
    }
    const selected = candidates[0];
    if (!selected) return null;
    ${clickSnippet}
    const rect = selected.action.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      label: labelsFor(selected.action)[0] || '',
      reason: selected.reason,
      cardButtonLabels: selected.buttons.flatMap(labelsFor).slice(0, 24),
      cardRole: selected.container.getAttribute('role') || '',
      cardHasModal: selected.container.getAttribute('aria-modal') === 'true',
      inViewport: rect.bottom > 0 && rect.right > 0
        && rect.left < window.innerWidth && rect.top < window.innerHeight,
      clickedByDom: ${clickedValue},
      visibility: document.visibilityState,
      runtimeState: document.visibilityState === 'hidden' ? 'hidden' : 'visible'
    };
  })()`;
}

function desktopApprovalRemainingExpression() {
  return `Boolean(${desktopApprovalExpression()})`;
}

async function directDesktopApprove(rpc) {
  const args = rpc.params?.arguments ?? {};
  const connector = String(args.connector || '').trim();
  const port = desktopCDPPort(args);
  let target = await desktopTarget(port, args.backgroundTargetId || null);
  const runtimeMetadata = value => {
    const visibility = String(value?.visibility || '').trim();
    return {
      backgroundOnly: visibility === 'hidden',
      runtimeState: visibility === 'hidden' || visibility === 'visible' ? visibility : 'unavailable',
    };
  };
  if (!target) return {
    ok: false, errorCode: 'desktop_chat_target_unavailable',
    message: `插件专用桌面 ChatGPT 调试目标不可用（端口 ${port}）。`,
    ...runtimeMetadata(null), workerUsed: false, surface: 'chat', port,
  };
  const approval = await desktopEvaluate(target, desktopApprovalExpression());
  if (!approval) return {
    ok: true, approved: false, approvalConfirmed: true,
    message: connector
      ? `当前没有检测到结构化授权卡（调用方标记：${connector}）。`
      : '当前没有检测到结构化授权卡。',
    ...runtimeMetadata(approval || target), workerUsed: false, surface: 'chat', port,
    targetId: target.id,
  };
  if (approval.inViewport === false) {
    await desktopEvaluate(target, desktopApprovalExpression({ invokeClick: true }));
  } else {
    await desktopPointerClick(target, approval.x, approval.y);
  }
  const deadline = Date.now() + 8_000;
  let remaining = true;
  while (Date.now() < deadline) {
    try {
      remaining = !!(await desktopEvaluate(target, desktopApprovalRemainingExpression()));
    } catch {
      const replacement = await desktopTarget(port, target.id);
      if (replacement) target = replacement;
      remaining = false;
    }
    if (!remaining) break;
    await sleep(250);
  }
  return {
    ok: !remaining, approved: !remaining, approvalConfirmed: !remaining,
    errorCode: remaining ? 'desktop_approval_not_confirmed' : undefined,
    message: remaining
      ? '插件点击了结构化授权卡的允许按钮，但未确认卡片消失。'
      : '插件已确认结构化授权卡完成。',
    ...runtimeMetadata(approval || target), workerUsed: false, surface: 'chat', port,
    targetId: target.id, approvedAt: !remaining ? new Date().toISOString() : undefined,
  };
}

function desktopInputTextExpression() {
  return `(() => {
    const input = document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    return input ? (input.value || input.innerText || input.textContent || '').trim() : '';
  })()`;
}

function desktopSendButtonExpression() {
  return `(() => {
    const visible = element => {
      const rect = element?.getBoundingClientRect?.();
      return !!rect && (rect.width || rect.height || element.offsetParent !== null);
    };
    const input = document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    const scope = input?.closest('form') || document;
    const button = [...scope.querySelectorAll(
      '[data-testid="send-button"], button[aria-label="发送"], button[aria-label="Send prompt"], button'
    )].find(element => visible(element)
      && !element.disabled
      && (element.matches('[data-testid="send-button"], [aria-label="发送"], [aria-label="Send prompt"]')
        || /^(发送|send)$/i.test((element.innerText || element.textContent || '').trim())));
    if (!button) return null;
    const rect = button.getBoundingClientRect();
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  })()`;
}

function desktopReplyStateExpression(messagePrefix = '') {
  const prefix = JSON.stringify(String(messagePrefix || '').replace(/\s+/g, ' ').trim());
  return `(() => {
    const prefix = ${prefix};
    const normalize = value => (value || '').replace(/\\s+/g, ' ').trim();
    const users = [...document.querySelectorAll('[data-message-author-role="user"], [data-user-message-bubble]')];
    const assistants = [...document.querySelectorAll(
      '[data-message-author-role="assistant"], [data-local-conversation-final-assistant]'
    )];
    const matchingUser = users.find(element => normalize(element.innerText || element.textContent).includes(prefix));
    const latestAssistant = assistants.at(-1);
    const stop = document.querySelector('[data-testid="stop-button"]')
      || document.querySelector('[aria-label="Stop streaming"]')
      || document.querySelector('[aria-label="停止输出"]')
      || document.querySelector('[aria-label="停止回答"]');
    return {
      messageConfirmed: !!matchingUser,
      userMessageCount: users.length,
      assistantMessageCount: assistants.length,
      streaming: !!stop,
      content: normalize(latestAssistant?.innerText || latestAssistant?.textContent || ''),
      conversationId: document.querySelector('[data-above-composer-conversation-id]')
        ?.getAttribute('data-above-composer-conversation-id') || null,
      url: window.location.href || '',
      visibility: document.visibilityState,
      runtimeState: document.visibilityState === 'hidden' ? 'hidden' : 'visible',
    };
  })()`;
}

function desktopConversationId(value) {
  const raw = String(value || '').trim();
  return raw.startsWith('chatgpt:') ? raw.slice('chatgpt:'.length) : raw || null;
}

function stripDesktopTaskReportContract(value) {
  let message = String(value || '').trim();
  for (const marker of [
    'MAHAYANA_TASK_REPORT_CONTRACT_V6',
    'MAHAYANA_TASK_REPORT_CONTRACT_V5',
    'MAHAYANA_TASK_REPORT_V1_BEGIN',
  ]) {
    const markerIndex = message.indexOf(marker);
    if (markerIndex >= 0) message = message.slice(0, markerIndex).trim();
  }
  return message;
}

function compactDesktopDispatchPrompt(args, fallbackMessage) {
  const role = args.role === 'planner' ? 'planner' : 'work';
  // A work Chat receives only the executable goal. The planner is the only
  // role that receives the report contract and turns its natural review into
  // the next raw work instruction.
  const source = String(args.message || args.originalGoal || fallbackMessage || '').trim();
  const goal = stripDesktopTaskReportContract(source);
  if (role !== 'planner') {
    return goal;
  }
  const workResult = stripDesktopTaskReportContract(
    args.workResult || args.naturalWorkResult || '',
  ).slice(0, 50_000);
  const taskId = JSON.stringify(String(args.taskId || 'CURRENT_TASK_ID').trim() || 'CURRENT_TASK_ID');
  const revisionValue = args.appliedRevision ?? args.appliedTaskRevision;
  const revision = Number.isInteger(revisionValue) ? revisionValue : 1;
  const digestValue = args.appliedDigest ?? args.appliedSpecDigest;
  const digest = JSON.stringify(String(digestValue || 'CURRENT_SPEC_DIGEST').trim()
    || 'CURRENT_SPEC_DIGEST');
  return `${goal}\n\n工作 Chat 自然结果 BEGIN\n${workResult || '本轮没有返回稳定的自然语言结果，请检查 checkout 后决定下一步。'}\n工作 Chat 自然结果 END\n\nMAHAYANA_TASK_REPORT_CONTRACT_V6\n你是规划/验收 Chat，不是工作 Chat。请根据工作 Chat 的自然结果和当前 checkout 的实际状态决定下一步安排。\n必须在回复末尾输出一次且仅一次 MAHAYANA_TASK_REPORT_V1。完成时使用 status=complete、all_tasks_complete=true、remaining=[]、blockers=[]、next_task=""；未完成或被阻塞时使用 status=incomplete 或 blocked、all_tasks_complete=false，并把下一轮工作 Chat 要执行的完整安排写入 next_task。不要把规划说明或模板要求转发给工作 Chat。\nMAHAYANA_TASK_REPORT_V1_BEGIN\n{"protocol":"mahayana.task-report.v1","task_id":${taskId},"applied_task_revision":${revision},"applied_spec_digest":${digest},"status":"complete","all_tasks_complete":true,"summary":"整个目标已完成","completed":["列出实现、验证和发布证据"],"remaining":[],"blockers":[],"verification":["列出可复核证据"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}\nMAHAYANA_TASK_REPORT_V1_END`;
}

async function directDesktopSend(rpc) {
  const args = rpc.params?.arguments ?? {};
  const rawMessage = String(args.message || '').trim();
  const message = compactDesktopDispatchPrompt(args, rawMessage);
  const connector = String(args.connector || '').trim();
  if (!message) return {
    ok: false, errorCode: 'missing_message', message: '请提供 message 参数',
    backgroundOnly: false, runtimeState: 'unavailable', workerUsed: false, surface: 'chat',
  };
  const port = desktopCDPPort(args);
  let target = await desktopTarget(port, args.backgroundTargetId || null);
  let surface = null;
  const runtimeMetadata = value => {
    const visibility = String(value?.visibility || '').trim();
    return {
      backgroundOnly: visibility === 'hidden',
      runtimeState: visibility === 'hidden' || visibility === 'visible' ? visibility : 'unavailable',
    };
  };
  if (!target) return {
    ok: false, errorCode: 'desktop_chat_target_unavailable',
    message: `插件专用桌面 ChatGPT 调试目标不可用（端口 ${port}）。`,
    ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
  };
  const evaluate = async expression => {
    try {
      return await desktopEvaluate(target, expression);
    } catch (error) {
      const replacement = await desktopTarget(port, target.id);
      if (!replacement) throw error;
      target = replacement;
      return await desktopEvaluate(target, expression);
    }
  };
  const click = async expression => {
    const candidate = await evaluate(expression);
    if (!candidate) return false;
    await desktopPointerClick(target, candidate.x, candidate.y);
    return true;
  };
  const waitUntil = async (predicate, timeoutMs = 15_000) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const value = await predicate();
      if (value) return value;
      await sleep(250);
    }
    return null;
  };
  surface = await evaluate(desktopSurfaceExpression);
  if (!surface?.ok) {
    if (!await click(desktopChatButtonExpression)) return {
      ok: false, errorCode: 'desktop_chat_mode_button_not_found',
      message: '插件未找到桌面 ChatGPT 的 Chat 模式按钮，未发送。',
      ...runtimeMetadata(surface), workerUsed: false, surface: 'not-chat', port,
    };
    surface = await waitUntil(async () => {
      const current = await evaluate(desktopSurfaceExpression);
      return current?.ok ? current : null;
    });
  }
  if (!surface?.ok) return {
    ok: false, errorCode: 'desktop_chat_surface_not_ready',
    message: '桌面 ChatGPT 未进入可发送的 Chat 表面，未发送。',
    ...runtimeMetadata(surface), workerUsed: false, surface: 'not-chat', port,
  };

  const previousConversationId = desktopConversationId(surface.conversationId);
  const shouldCreateNewChat = args.newChat !== false && args.resumeExisting !== true;
  if (shouldCreateNewChat) {
    const existingMessageCount = Number(await evaluate(`(() => document.querySelectorAll(
      '[data-message-author-role="user"], [data-user-message-bubble], [data-message-author-role="assistant"], [data-local-conversation-final-assistant]'
    ).length)()`));
    if (existingMessageCount > 0) {
      if (!await click(desktopNewChatExpression)) return {
        ok: false, errorCode: 'desktop_new_chat_button_not_found',
        message: '插件未找到桌面 ChatGPT 的新对话按钮，未发送。',
        ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
      };
      surface = await waitUntil(async () => {
        const current = await evaluate(desktopSurfaceExpression);
        const currentConversationId = desktopConversationId(current?.conversationId);
        const userCount = Number(await evaluate(`(() => document.querySelectorAll(
          '[data-message-author-role="user"], [data-user-message-bubble]'
        ).length)()`));
        return current?.ok && userCount === 0
          && (!previousConversationId || !currentConversationId || currentConversationId !== previousConversationId)
          ? current : null;
      }, 20_000);
      if (!surface?.ok) return {
        ok: false, errorCode: 'desktop_new_chat_not_confirmed',
        message: '插件点击了新对话，但未确认空白 Chat 已建立，未发送。',
        ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
      };
    }
  }

  const baselineCounts = await evaluate(`(() => ({
    user: document.querySelectorAll('[data-message-author-role="user"], [data-user-message-bubble]').length,
    assistant: document.querySelectorAll('[data-message-author-role="assistant"], [data-local-conversation-final-assistant]').length,
  }))()`);
  const beforeUserMessageCount = Number(baselineCounts?.user || 0);
  const beforeAssistantCount = Number(baselineCounts?.assistant || 0);

  // A failed send can leave a draft in the ProseMirror composer even though
  // no user message was created. Clear the editable draft before rebuilding
  // the connector mention; selecting the whole composer also removes a stale
  // connector chip, which is intentionally re-added below and then verified.
  const composerFocused = await evaluate(`(() => {
    const input = document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    if (!input) return false;
    input.focus();
    return true;
  })()`);
  if (!composerFocused) return {
    ok: false, errorCode: 'desktop_input_not_found',
    message: '插件未找到桌面 ChatGPT 输入框，未发送。',
    ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
  };
  const modifier = process.platform === 'darwin' ? 4 : 2;
  await desktopCDPCall(target, 'Input.dispatchKeyEvent', {
    type: 'keyDown', key: 'a', code: 'KeyA', modifiers: modifier,
    windowsVirtualKeyCode: 65,
  }, 10_000);
  await desktopCDPCall(target, 'Input.dispatchKeyEvent', {
    type: 'keyUp', key: 'a', code: 'KeyA', modifiers: modifier,
    windowsVirtualKeyCode: 65,
  }, 10_000);
  await desktopCDPCall(target, 'Input.dispatchKeyEvent', {
    type: 'keyDown', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8,
  }, 10_000);
  await desktopCDPCall(target, 'Input.dispatchKeyEvent', {
    type: 'keyUp', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8,
  }, 10_000);
  await sleep(250);

  let connectorConfirmed = false;
  if (connector) {
    const selected = await evaluate(desktopConnectorExpression(connector));
    connectorConfirmed = selected?.selected === true;
    if (!connectorConfirmed) {
      if (!await click(`(() => {
        const visible = element => {
          const rect = element?.getBoundingClientRect?.();
          return !!rect && (rect.width || rect.height || element.offsetParent !== null);
        };
        const element = [...document.querySelectorAll('button[aria-label], button')]
          .find(candidate => visible(candidate)
            && /(?:添加文件等|附加文件|add files|attachments)/i.test(
              candidate.getAttribute('aria-label') || candidate.innerText || ''));
        if (!element) return null;
        const rect = element.getBoundingClientRect();
        return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
      })()`)) return {
        ok: false, errorCode: 'desktop_apps_button_not_found',
        message: '插件未找到桌面 ChatGPT 的 Apps 按钮，未发送。',
        ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
      };
      const menuItem = await waitUntil(async () => evaluate(desktopConnectorMenuExpression(connector)), 5_000);
      if (!menuItem) return {
        ok: false, errorCode: 'desktop_connector_not_found',
        message: `桌面 ChatGPT Apps 菜单中没有找到连接器 ${connector}，未发送。`,
        ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
      };
      if (menuItem.clicked !== true) await desktopPointerClick(target, menuItem.x, menuItem.y);
      connectorConfirmed = !!(await waitUntil(async () => {
        const current = await evaluate(desktopConnectorExpression(connector));
        return current?.selected === true ? true : null;
      }, 8_000));
      if (!connectorConfirmed) {
        // Some desktop builds expose the app row through a React click
        // handler but ignore synthetic pointer events. Retry the same row
        // with HTMLElement.click(), then verify the composer chip again.
        await evaluate(desktopConnectorNativeClickExpression(connector));
        connectorConfirmed = !!(await waitUntil(async () => {
          const current = await evaluate(desktopConnectorExpression(connector));
          return current?.selected === true ? true : null;
        }, 4_000));
      }
      if (!connectorConfirmed) {
        // Last compatibility path: use the renderer's mention picker. This
        // still requires a real selected mention before the task is sent.
        await evaluate(`(() => {
          const input = document.querySelector('#prompt-textarea')
            || document.querySelector('[contenteditable="true"]');
          if (!input) return false;
          input.focus();
          const selection = window.getSelection();
          if (selection) {
            selection.removeAllRanges();
            const range = document.createRange();
            range.selectNodeContents(input);
            selection.addRange(range);
          }
          return true;
        })()`);
        await desktopCDPCall(target, 'Input.insertText', { text: `@${connector}` }, 10_000);
        const mentionItem = await waitUntil(
          async () => evaluate(desktopConnectorMenuExpression(connector)), 8_000,
        );
        if (mentionItem && mentionItem.clicked !== true) {
          await desktopPointerClick(target, mentionItem.x, mentionItem.y);
        }
        connectorConfirmed = !!(await waitUntil(async () => {
          const current = await evaluate(desktopConnectorExpression(connector));
          return current?.selected === true ? true : null;
        }, 8_000));
      }
    }
    if (!connectorConfirmed) return {
      ok: false, errorCode: 'desktop_connector_not_confirmed',
      message: `插件未确认连接器 ${connector} 已绑定到当前 Chat，未发送。`,
      ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
    };
  }

  const inputReady = await evaluate(`(() => {
    const input = document.querySelector('#prompt-textarea')
      || document.querySelector('[contenteditable="true"]');
    if (!input) return false;
    input.focus();
    return true;
  })()`);
  if (!inputReady) return {
    ok: false, errorCode: 'desktop_input_not_found',
    message: '插件未找到桌面 ChatGPT 输入框，未发送。',
    ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
  };
  await desktopCDPCall(target, 'Input.insertText', { text: message }, 10_000);
  const inputConfirmed = await waitUntil(async () => {
    const text = String(await evaluate(desktopInputTextExpression()) || '').replace(/\s+/g, ' ').trim();
    const expected = message.replace(/\s+/g, ' ').trim();
    return text.includes(expected.slice(0, Math.min(240, expected.length))) ? true : null;
  }, 8_000);
  if (!inputConfirmed) return {
    ok: false, errorCode: 'desktop_input_not_confirmed',
    message: '插件已聚焦输入框，但未确认完整任务文本已写入，未发送。',
    ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
  };

  const sendButton = await waitUntil(async () => evaluate(desktopSendButtonExpression()), 5_000);
  if (sendButton) {
    await desktopPointerClick(target, sendButton.x, sendButton.y);
  } else {
    await desktopCDPCall(target, 'Input.dispatchKeyEvent', {
      type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13,
    });
    await desktopCDPCall(target, 'Input.dispatchKeyEvent', {
      type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13,
    });
  }
  const prefix = message.replace(/\s+/g, ' ').trim().slice(0, 240);
  const sentState = await waitUntil(async () => {
    const current = await evaluate(desktopReplyStateExpression(prefix));
    return current?.messageConfirmed ? current : null;
  }, 30_000);
  if (!sentState?.messageConfirmed) return {
    ok: false, errorCode: 'desktop_message_not_confirmed',
    message: '插件完成提交动作，但未在桌面 ChatGPT 中找到对应用户消息气泡，不能判定为已发送。',
    ...runtimeMetadata(surface), workerUsed: false, surface: 'chat', port,
    connector, connectorConfirmed, inputConfirmed: true,
  };
  const conversationId = desktopConversationId(sentState.conversationId)
    || desktopConversationId(surface.conversationId);
  const role = args.role === 'planner' ? 'planner' : 'work';
  return {
    ok: true, sent: true, messageConfirmed: true, connector,
    connectorConfirmed: connector ? true : false,
    inputConfirmed: true, surface: 'chat', ...runtimeMetadata(sentState), workerUsed: false,
    port, targetId: target.id, conversationId,
    chatUrl: String(sentState.url || '').startsWith('https://chatgpt.com/')
      ? sentState.url : null,
    monitorStarted: false,
    role,
    autoPlanAfterWork: role === 'work' && args.autoPlanAfterWork !== false,
    originalGoal: String(args.originalGoal || rawMessage).trim().slice(0, 10000),
    taskId: args.taskId == null ? null : String(args.taskId).trim().slice(0, 128),
    appliedRevision: Number.isInteger(args.appliedRevision) ? args.appliedRevision : null,
    appliedDigest: args.appliedDigest == null ? null : String(args.appliedDigest).trim().slice(0, 256),
    sentPrompt: message,
    beforeUserMessageCount,
    beforeAssistantCount,
    sentAt: new Date().toISOString(),
  };
}

function directDesktopRoundArguments(baseArgs, current, overrides = {}) {
  const originalGoal = stripDesktopTaskReportContract(
    String(baseArgs.originalGoal || current?.originalGoal || baseArgs.message || '').trim(),
  );
  return {
    ...baseArgs,
    ...overrides,
    directDesktop: true,
    backgroundPort: current.port,
    backgroundTargetId: current.targetId,
    newChat: true,
    resumeExisting: false,
    originalGoal,
    taskId: current.taskId ?? baseArgs.taskId ?? null,
    appliedRevision: current.appliedRevision ?? baseArgs.appliedRevision ?? null,
    appliedDigest: current.appliedDigest ?? baseArgs.appliedDigest ?? null,
  };
}

async function watchDirectDesktopOrchestration(baseArgs, firstDispatch) {
  let current = firstDispatch;
  let handoffCount = 0;
  let recoveryAttempts = 0;
  let noFinalReplyRetries = 0;
  let emptyWorkResultAttempts = 0;
  let plannerRetryAttempts = 0;
  let latestWorkResult = '';
  const maxRecoveryAttempts = Math.min(5, Math.max(
    0, Number(baseArgs.maxRecoveryAttempts ?? 5),
  ));
  const maxTaskContinuations = Math.max(0, Number(baseArgs.maxTaskContinuations ?? 0));
  const timeoutMs = Math.min(6 * 60 * 60 * 1000, Math.max(
    10_000, Number(baseArgs.timeout || 21_600) * 1000,
  ));
  const stagnationMs = Math.min(3 * 60 * 60 * 1000, Math.max(
    60_000, Number(baseArgs.stagnationTimeout || 10_800) * 1000,
  ));
  const noFinalReplyMs = Math.min(
    stagnationMs,
    Math.max(30_000, Number(baseArgs.noFinalReplyTimeout || 300) * 1000),
  );
  const pollIntervalMs = Math.min(5_000, Math.max(
    200, Number(baseArgs.pollIntervalMs || 500),
  ));
  const originalGoal = stripDesktopTaskReportContract(
    String(baseArgs.originalGoal || firstDispatch.originalGoal || baseArgs.message || '').trim(),
  );

  const failure = (errorCode, message, extra = {}) => ({
    ...current,
    ok: false,
    errorCode,
    message,
    monitorStarted: true,
    naturalWorkResult: latestWorkResult,
    handoffCount,
    recoveryAttempts,
    ...extra,
  });

  while (true) {
    const port = Number(current.port || desktopCDPPort(baseArgs));
    const targetId = String(current.targetId || '').trim();
    let target = await desktopTarget(port, targetId);
    if (!target || target.id !== targetId) {
      return failure(
        'desktop_plugin_chat_target_lost',
        '插件专用桌面 ChatGPT 目标已失效；没有切换到用户自己的窗口。',
        { runtimeState: 'unavailable', backgroundOnly: false },
      );
    }

    const role = current.role === 'planner' ? 'planner' : 'work';
    const prefix = String(current.sentPrompt || '').replace(/\s+/g, ' ').trim().slice(0, 240);
    const beforeAssistantCount = Number(current.beforeAssistantCount || 0);
    let stableSamples = 0;
    let lastFingerprint = '';
    let lastProgressAt = Date.now();
    let latestState = null;
    let handedOff = false;
    let noFinalReplySince = null;
    const roundDeadline = Date.now() + timeoutMs;

    while (Date.now() < roundDeadline) {
      target = await desktopTarget(port, targetId);
      if (!target || target.id !== targetId) {
        return failure(
          'desktop_plugin_chat_target_lost',
          '插件专用桌面 ChatGPT 目标在监督期间失效；没有切换到用户自己的窗口。',
          { runtimeState: 'unavailable', backgroundOnly: false },
        );
      }
      try {
        const approval = await directDesktopApprove({ params: { arguments: {
          directDesktop: true,
          backgroundPort: port,
          backgroundTargetId: targetId,
          connector: current.connector || baseArgs.connector || '',
        } } });
        if (approval?.approved) current.approvals = Number(current.approvals || 0) + 1;
        current.authorization = approval;
      } catch (error) {
        current.authorization = {
          ok: false,
          errorCode: 'desktop_approval_poll_failed',
          message: String(error?.message || error),
        };
      }
      latestState = await desktopEvaluate(target, desktopReplyStateExpression(prefix));
      current.latestReply = String(latestState?.content || '').slice(-4000);
      current.responseRunning = latestState?.streaming === true;
      current.runtimeState = latestState?.runtimeState || 'unavailable';
      current.backgroundOnly = latestState?.backgroundOnly === true;
      const assistantCount = Number(latestState?.assistantMessageCount || 0);
      const content = String(latestState?.content || '').trim();
      const responseStarted = assistantCount > beforeAssistantCount;
      const userTurnStarted = Number(latestState?.userMessageCount || 0)
        > Number(current.beforeUserMessageCount || 0);
      const noFinalReplyCandidate = latestState?.messageConfirmed === true
        && userTurnStarted
        && !responseStarted
        && latestState?.streaming !== true;
      if (noFinalReplyCandidate) {
        if (noFinalReplySince == null) noFinalReplySince = Date.now();
      } else {
        noFinalReplySince = null;
      }
      const noFinalReplyDue = noFinalReplyCandidate
        && Date.now() - Number(noFinalReplySince || Date.now()) >= noFinalReplyMs;
      const fingerprint = `${assistantCount}:${content.length}:${content.slice(-240)}:${latestState?.streaming === true}`;
      if (fingerprint !== lastFingerprint) {
        lastFingerprint = fingerprint;
        stableSamples = 0;
        lastProgressAt = Date.now();
      } else {
        stableSamples += 1;
      }

      if (noFinalReplyDue) {
        noFinalReplyRetries += 1;
        recoveryAttempts += 1;
        if (recoveryAttempts > maxRecoveryAttempts) {
          return failure(
            'no_final_reply_after_retries',
            'Chat 会话已结束但没有最终回复；插件已关闭旧 Chat、用新的 Work Chat 重发原指令，并用尽自动重试次数。',
            {
              oldChatClosed: true,
              oldChatPreserved: false,
              continuationMode: 'fresh_chat_after_no_final_reply_exhausted',
              noFinalReplyRetries,
              sessionEndedWithoutFinalReply: true,
            },
          );
        }
        handoffCount += 1;
        if (maxTaskContinuations > 0 && handoffCount > maxTaskContinuations) {
          return failure(
            'task_continuation_limit_reached',
            'Chat 会话没有最终回复，且已达到调用方设置的 Chat 续作上限。',
            { noFinalReplyRetries, sessionEndedWithoutFinalReply: true },
          );
        }
        const retryMessage = stripDesktopTaskReportContract(
          String(current.sentPrompt || baseArgs.message || originalGoal).trim(),
        );
        const retryArgs = directDesktopRoundArguments(baseArgs, current, {
          message: role === 'planner' ? originalGoal : retryMessage,
          role,
          autoPlanAfterWork: role === 'work',
          workResult: role === 'planner' ? latestWorkResult : '',
        });
        const retryDispatch = await directDesktopSend({
          params: { arguments: retryArgs },
        });
        if (!retryDispatch?.ok) {
          return failure(
            'no_final_reply_recovery_failed',
            'Chat 会话没有最终回复，且新的插件 Chat 尚未确认发送。',
            {
              oldChatClosed: true,
              oldChatPreserved: false,
              continuationMode: 'fresh_chat_after_no_final_reply',
              noFinalReplyRetries,
              sessionEndedWithoutFinalReply: true,
              sendVerification: retryDispatch,
            },
          );
        }
        current = retryDispatch;
        handedOff = true;
        break;
      }

      if (!latestState?.streaming && responseStarted && stableSamples >= 3) {
        if (role === 'work') {
          latestWorkResult = stripDesktopTaskReportContract(content);
          if (!latestWorkResult) {
            emptyWorkResultAttempts += 1;
            handoffCount += 1;
            if (emptyWorkResultAttempts > maxRecoveryAttempts) {
              return failure(
                'work_natural_result_missing',
                'Work Chat 已停止生成，但没有返回可交给规划 Chat 的自然语言结果；插件已用尽重试次数。',
                {
                  oldChatClosed: true,
                  oldChatPreserved: false,
                  continuationMode: 'fresh_chat_after_empty_work_result_exhausted',
                  emptyWorkResultAttempts,
                },
              );
            }
            if (maxTaskContinuations > 0 && handoffCount > maxTaskContinuations) {
              return failure(
                'task_continuation_limit_reached',
                'Work Chat 没有返回自然结果，且已达到调用方设置的 Chat 续作上限。',
                { emptyWorkResultAttempts },
              );
            }
            const retryMessage = stripDesktopTaskReportContract(
              String(current.sentPrompt || baseArgs.message || originalGoal).trim(),
            );
            const retryArgs = directDesktopRoundArguments(baseArgs, current, {
              message: retryMessage,
              role: 'work',
              autoPlanAfterWork: true,
              workResult: '',
            });
            const retryDispatch = await directDesktopSend({
              params: { arguments: retryArgs },
            });
            if (!retryDispatch?.ok) {
              return failure(
                'work_natural_result_recovery_failed',
                'Work Chat 没有返回自然结果，且新的插件 Work Chat 尚未确认发送。',
                {
                  oldChatClosed: true,
                  oldChatPreserved: false,
                  continuationMode: 'fresh_chat_after_empty_work_result',
                  emptyWorkResultAttempts,
                  sendVerification: retryDispatch,
                },
              );
            }
            current = retryDispatch;
            handedOff = true;
            break;
          }
          emptyWorkResultAttempts = 0;
          handoffCount += 1;
          if (maxTaskContinuations > 0 && handoffCount > maxTaskContinuations) {
            return failure(
              'task_continuation_limit_reached',
              '已达到调用方设置的 Chat 续作上限；插件保留当前自然结果。',
            );
          }
          const plannerArgs = directDesktopRoundArguments(baseArgs, current, {
            message: originalGoal,
            role: 'planner',
            autoPlanAfterWork: false,
            workResult: latestWorkResult,
          });
          const plannerDispatch = await directDesktopSend({
            params: { arguments: plannerArgs },
          });
          if (!plannerDispatch?.ok) {
            return failure(
              'planner_handoff_not_confirmed',
              'Work Chat 已返回自然结果，但新的规划 Chat 尚未确认发送。',
              { plannerHandoff: { started: false, sendVerification: plannerDispatch } },
            );
          }
          current = plannerDispatch;
          plannerRetryAttempts = 0;
          handedOff = true;
          break;
        }

        const parsed = parseTaskReport(content);
        if (parsed.complete) {
          return {
            ...current,
            ok: true,
            sent: true,
            monitorStarted: true,
            role: 'planner',
            taskReport: parsed.payload,
            naturalWorkResult: latestWorkResult,
            handoffCount,
            recoveryAttempts,
            runtimeState: latestState?.runtimeState || current.runtimeState || 'unavailable',
            backgroundOnly: latestState?.backgroundOnly === true,
            completedAt: new Date().toISOString(),
          };
        }
        if (parsed.actionable) {
          handoffCount += 1;
          if (maxTaskContinuations > 0 && handoffCount > maxTaskContinuations) {
            return failure(
              'task_continuation_limit_reached',
              '已达到调用方设置的 Chat 续作上限；插件保留规划 Chat 的 next_task。',
              { taskReport: parsed.payload },
            );
          }
          const nextTask = stripDesktopTaskReportContract(parsed.payload.next_task);
          const nextConnector = String(parsed.payload.next_connector || '').trim();
          const workArgs = directDesktopRoundArguments(baseArgs, current, {
            message: nextTask,
            role: 'work',
            autoPlanAfterWork: true,
            connector: nextConnector || current.connector || baseArgs.connector || null,
            workResult: '',
          });
          const workDispatch = await directDesktopSend({
            params: { arguments: workArgs },
          });
          if (!workDispatch?.ok) {
            return failure(
              'work_handoff_not_confirmed',
              '规划 Chat 已给出 next_task，但新的 Work Chat 尚未确认发送。',
              { taskReport: parsed.payload },
            );
          }
          current = workDispatch;
          latestWorkResult = '';
          handedOff = true;
          break;
        }

        plannerRetryAttempts += 1;
        if (plannerRetryAttempts > maxRecoveryAttempts) {
          return failure(
            'task_report_missing',
            '规划 Chat 已停止生成，但在自动重试后仍没有有效的 MAHAYANA_TASK_REPORT_V1。',
            { taskReport: null, plannerRetryAttempts },
          );
        }
        const retryPlannerArgs = directDesktopRoundArguments(baseArgs, current, {
          message: originalGoal,
          role: 'planner',
          autoPlanAfterWork: false,
          workResult: latestWorkResult,
        });
        const retryDispatch = await directDesktopSend({
          params: { arguments: retryPlannerArgs },
        });
        if (!retryDispatch?.ok) {
          return failure(
            'planner_handoff_not_confirmed',
            '规划 Chat 回执无效，且新的规划 Chat 尚未确认发送。',
            { plannerRetryAttempts, sendVerification: retryDispatch },
          );
        }
        current = retryDispatch;
        handedOff = true;
        break;
      }

      if (Date.now() - lastProgressAt >= stagnationMs) {
        recoveryAttempts += 1;
        if (recoveryAttempts > maxRecoveryAttempts) {
          return failure(
            'page_stalled',
            `桌面 ChatGPT 连续 ${Math.floor(stagnationMs / 1000)} 秒没有新内容，已用尽自动恢复次数。`,
            { oldChatClosed: false, continuationMode: 'fresh_chat_after_stall_exhausted' },
          );
        }
        handoffCount += 1;
        if (maxTaskContinuations > 0 && handoffCount > maxTaskContinuations) {
          return failure(
            'task_continuation_limit_reached',
            '页面无进展且已达到调用方设置的 Chat 续作上限。',
          );
        }
        const retryMessage = stripDesktopTaskReportContract(
          String(current.sentPrompt || baseArgs.message || originalGoal).trim(),
        );
        const retryArgs = directDesktopRoundArguments(baseArgs, current, {
          message: role === 'planner' ? originalGoal : retryMessage,
          role,
          autoPlanAfterWork: role === 'work',
          workResult: role === 'planner' ? latestWorkResult : '',
        });
        const retryDispatch = await directDesktopSend({
          params: { arguments: retryArgs },
        });
        if (!retryDispatch?.ok) {
          return failure(
            'desktop_stall_recovery_failed',
            '桌面 ChatGPT 页面无进展，且新的插件 Chat 尚未确认发送。',
            { oldChatClosed: true, continuationMode: 'fresh_chat_after_stall' },
          );
        }
        current = retryDispatch;
        handedOff = true;
        break;
      }
      await sleep(pollIntervalMs);
    }

    if (handedOff) continue;
    return failure(
      'watch_timeout',
      `等待桌面 ChatGPT 最终结果超过 ${Math.floor(timeoutMs / 1000)} 秒。`,
      { oldChatClosed: false, lastReply: latestState?.content || '' },
    );
  }
}

async function runDirectDesktopTool(rpc) {
  const tool = String(rpc.params?.name ?? '');
  if (tool === 'desktop_approve') {
    const args = rpc.params?.arguments ?? {};
    if (args.directDesktop !== true && process.env.CHATGPT_AUTO_CONFIRM_DIRECT_DESKTOP !== '1') return null;
    let approved;
    try {
      approved = await directDesktopApprove(rpc);
    } catch (error) {
      approved = {
        ok: false, errorCode: 'desktop_approval_failed', message: String(error?.message || error),
        backgroundOnly: false, runtimeState: 'unavailable', workerUsed: false, surface: 'chat',
      };
    }
    return nativeToolResponse(rpc, tool, approved);
  }
  if (tool !== 'send_and_watch') return null;
  const args = rpc.params?.arguments ?? {};
  // Explicit opt-in keeps existing queue/native callers compatible while the
  // desktop Chat sender is rolled out. The caller still uses the plugin MCP
  // tool; this flag only selects the renderer transport.
  if (args.directDesktop !== true && process.env.CHATGPT_AUTO_CONFIRM_DIRECT_DESKTOP !== '1') return null;
  let dispatched;
  try {
    dispatched = await directDesktopSend(rpc);
  } catch (error) {
    dispatched = {
      ok: false,
      errorCode: 'desktop_send_failed',
      message: String(error?.message || error),
      backgroundOnly: false,
      runtimeState: 'unavailable',
      workerUsed: false,
      surface: 'chat',
    };
  }
  if (!dispatched?.ok) return nativeToolResponse(rpc, tool, dispatched);
  const jobId = `desktop_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const jobRecord = {
    id: jobId,
    status: 'running',
    conversationId: dispatched.conversationId,
    connector: dispatched.connector,
    role: dispatched.role,
    originalGoal: dispatched.originalGoal,
    taskId: dispatched.taskId,
    sentAt: dispatched.sentAt,
  };
  desktopDirectJobs.set(jobId, jobRecord);
  let watched;
  try {
    watched = await watchDirectDesktopOrchestration(
      { ...(rpc.params?.arguments || {}), directDesktop: true },
      dispatched,
    );
  } catch (error) {
    watched = {
      ...dispatched,
      ok: false,
      errorCode: 'desktop_watch_failed',
      message: String(error?.message || error),
      monitorStarted: true,
    };
  }
  const finalRecord = {
    ...jobRecord,
    status: watched?.ok ? 'completed' : 'failed',
    conversationId: watched?.conversationId || dispatched.conversationId,
    role: watched?.role || dispatched.role,
    updatedAt: new Date().toISOString(),
  };
  desktopDirectJobs.set(jobId, finalRecord);
  return nativeToolResponse(rpc, tool, {
    ...watched,
    jobId,
    message: watched?.ok
      ? '插件已完成桌面 ChatGPT 的工作→规划→下一轮编排。'
      : (watched?.message || '插件桌面 ChatGPT 编排未完成。'),
  });
}

async function runInAppBrowserTool(rpc) {
  const tool = String(rpc.params?.name ?? '');
  if (tool === 'browser_reply_handoff') {
    const descriptor = await readBrowserCapability();
    if (!descriptor.ok) return browserToolResponse(rpc, tool, descriptor);
    const requested = { ...(rpc.params?.arguments || {}) };
    // MCP calls made from a local Work turn do not need to copy their own
    // thread id into the prompt. Codex exposes the exact current thread to
    // the per-host process; an explicit argument still wins for recovery or
    // an operator-owned Work thread.
    if (requested.action === 'register' && !String(requested.threadId || '').trim()) {
      const currentThreadId = String(process.env.CODEX_THREAD_ID || '').trim();
      if (currentThreadId) requested.threadId = currentThreadId;
    }
    const result = await callBrowserCapability(descriptor, '/v1/reply-handoff', 'POST', requested);
    if (result?.ok && requested.action === 'register') {
      startReplyHandoffSupervisor();
    }
    return browserToolResponse(rpc, tool, result);
  }
  if (!new Set(['dispatch_goal', 'browser_capability_status', 'browser_job_status', 'browser_stop', 'browser_watch']).has(tool)) return null;
  if (tool === 'browser_watch') {
    const persistedJobs = await readPersistedBrowserJobs();
    if (persistedJobs.length === 0) return browserToolResponse(rpc, tool, {
      ok: false, errorCode: 'browser_job_not_found', message: '当前没有可恢复的内置 Browser 任务。',
    });
    for (const job of persistedJobs) startBrowserSupervisor(job.id);
    const descriptor = await readBrowserCapability();
    const health = descriptor.ok
      ? await callBrowserCapability(descriptor, '/v1/capability', 'GET', undefined, 5_000)
      : descriptor;
    const jobs = resultBrowserJobs(health, persistedJobs);
    if (replyHandoffWatches(health).some(watch => !replyHandoffTerminalStatuses.has(watch.status))) {
      startReplyHandoffSupervisor();
    }
    const reattachJobs = waitingForBrowserHost(jobs);
    const reattachRequired = !descriptor.ok || !health?.ok
      || health?.reattachRequired === true
      || reattachJobs.length > 0;
    maybeStartBrowserSupervisor(health);
    return browserToolResponse(rpc, tool, {
      ok: true,
      supervisor: jobs.every(job => browserSupervisors.has(job.id)) ? 'active' : 'starting',
      capability: reattachRequired ? 'reattach_required' : 'available',
      hostHealth: reattachRequired ? 'reattach_required' : (health?.hostHealth || 'attached'),
      reattachRequired,
      reattach: reattachRequired ? browserReattachMetadata(reattachJobs[0] || jobs[0]) : null,
      reattachments: reattachJobs.map(browserReattachMetadata),
      job: jobs[0] || null,
      jobs,
      maxConcurrentJobs: Number(health?.maxConcurrentJobs || maxParallelBrowserJobs),
    });
  }
  const descriptor = await readBrowserCapability();
  const args = rpc.params?.arguments ?? {};
  const requestedJobId = String(args.jobId || '').trim();
  if (!descriptor.ok && tool === 'browser_stop') {
    if (!/^iab_[A-Za-z0-9-]{20,100}$/u.test(requestedJobId)) {
      return browserToolResponse(rpc, tool, {
        ok: false, errorCode: 'invalid_job_id', message: 'jobId 必须是内置 Browser 返回的任务标识',
      });
    }
    const stopped = await stopPersistedBrowserJob(requestedJobId);
    if (stopped) return browserToolResponse(rpc, tool, {
      ok: true,
      hostHealth: 'detached',
      reattachRequired: false,
      reattach: null,
      job: stopped,
    });
  }
  if (!descriptor.ok && tool === 'browser_capability_status') {
    const persistedJobs = await readPersistedBrowserJobs();
    return browserToolResponse(rpc, tool, {
      ok: true,
      available: false,
      hostHealth: 'reattach_required',
      reattachRequired: persistedJobs.length > 0,
      reattach: persistedJobs[0] ? browserReattachMetadata(persistedJobs[0]) : null,
      reattachments: persistedJobs.map(browserReattachMetadata),
      activeJob: persistedJobs[0] || null,
      jobs: persistedJobs,
      maxConcurrentJobs: maxParallelBrowserJobs,
      descriptorError: descriptor,
    });
  }
  if (!descriptor.ok && tool === 'browser_job_status') {
    const persisted = (await readPersistedBrowserJobs()).find(job => job.id === requestedJobId);
    if (persisted) return browserToolResponse(rpc, tool, {
      ok: true,
      hostHealth: 'reattach_required',
      reattachRequired: true,
      reattach: browserReattachMetadata(persisted),
      job: persisted,
    });
  }
  if (!descriptor.ok) return browserToolResponse(rpc, tool, descriptor);
  if (tool === 'dispatch_goal') {
    const goal = String(args.goal ?? '').trim();
    if (!goal || goal.length > 10_000) {
      return browserToolResponse(rpc, tool, {
        ok: false, errorCode: 'invalid_goal', message: 'goal 必须是 1-10000 字符的非空目标文本',
      });
    }
    const result = await callBrowserCapability(descriptor, '/v1/chat/dispatch', 'POST', {
      goal,
      policy: pluginDispatchParams(goal),
    });
    maybeStartBrowserSupervisor(result);
    return browserToolResponse(rpc, tool, result);
  }
  if (tool === 'browser_capability_status') {
    const result = await callBrowserCapability(descriptor, '/v1/capability');
    if (replyHandoffWatches(result).some(watch => !replyHandoffTerminalStatuses.has(watch.status))) {
      startReplyHandoffSupervisor();
    }
    maybeStartBrowserSupervisor(result);
    const jobs = resultBrowserJobs(result);
    const reattachJobs = waitingForBrowserHost(jobs);
    const reattachRequired = !result?.ok || result?.reattachRequired === true
      || reattachJobs.length > 0;
    return browserToolResponse(rpc, tool, result?.ok ? {
      ...result,
      jobs,
      maxConcurrentJobs: Number(result.maxConcurrentJobs || maxParallelBrowserJobs),
      hostHealth: reattachRequired ? 'reattach_required' : (result.hostHealth || 'attached'),
      reattachRequired,
      reattach: reattachRequired ? browserReattachMetadata(reattachJobs[0] || jobs[0]) : null,
      reattachments: reattachJobs.map(browserReattachMetadata),
    } : result);
  }
  const jobId = requestedJobId;
  if (!/^iab_[A-Za-z0-9-]{20,100}$/u.test(jobId)) {
    return browserToolResponse(rpc, tool, {
      ok: false, errorCode: 'invalid_job_id', message: 'jobId 必须是内置 Browser 返回的任务标识',
    });
  }
  const suffix = tool === 'browser_stop' ? '/stop' : '';
  const result = await callBrowserCapability(
    descriptor,
    `/v1/chat/jobs/${encodeURIComponent(jobId)}${suffix}`,
    tool === 'browser_stop' ? 'POST' : 'GET',
  );
  if (!result?.ok && tool === 'browser_stop') {
    const stopped = await stopPersistedBrowserJob(jobId);
    if (stopped) return browserToolResponse(rpc, tool, {
      ok: true,
      hostHealth: 'detached',
      reattachRequired: false,
      reattach: null,
      job: stopped,
    });
  }
  maybeStartBrowserSupervisor(result);
  const jobs = resultBrowserJobs(result);
  const reattachJobs = waitingForBrowserHost(jobs);
  const reattachRequired = reattachJobs.length > 0;
  return browserToolResponse(rpc, tool, result?.ok ? {
    ...result,
    jobs,
    hostHealth: reattachRequired ? 'reattach_required' : 'attached',
    reattachRequired,
    reattach: reattachRequired ? browserReattachMetadata(reattachJobs[0]) : null,
    reattachments: reattachJobs.map(browserReattachMetadata),
  } : result);
}

function runLocalWorkBridgeTool(rpc) {
  const tool = String(rpc.params?.name ?? '');
  if (tool !== 'work_bridge_status') return null;
  return nativeToolResponse(rpc, tool, {
    ok: true,
    ...localWorkBridgeDescriptor(),
  });
}

function runWindowsCredentialTool(rpc) {
  const tool = String(rpc.params?.name ?? '');
  if (process.platform !== 'win32' || !windowsCredentialTools.has(tool)
      || !existsSync(windowsCredentialScript)) return null;
  const powershell = process.env.CHATGPT_AUTO_CONFIRM_POWERSHELL || 'powershell.exe';
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', windowsCredentialScript,
  ];
  if (tool === 'login_and_sync_actions') {
    args.push('-DesktopLogin', '-WaitSeconds', String(
      Math.min(1800, Math.max(30, Number(rpc.params?.arguments?.waitSeconds ?? 600))),
    ));
  }
  if (rpc.params?.arguments?.start === true) args.push('-Start');
  const invocation = spawnSync(powershell, args, {
    encoding: 'utf8', timeout: 1_200_000, maxBuffer: 10 * 1024 * 1024,
    env: process.env,
  });
  const stdout = String(invocation.stdout || '').trim();
  const line = stdout.split(/\r?\n/).at(-1);
  let structuredContent;
  try {
    if (invocation.error || !line) {
      throw invocation.error || new Error(String(invocation.stderr || 'Windows credential sync returned no response').trim());
    }
    structuredContent = JSON.parse(line);
    if (invocation.status !== 0 && structuredContent.ok !== false) {
      structuredContent = {
        ok: false,
        errorCode: 'windows_sync_nonzero_exit',
        message: `Windows credential sync exited with code ${invocation.status}`,
        nativeResponse: structuredContent,
      };
    }
  } catch (error) {
    structuredContent = {
      ok: false,
      errorCode: 'windows_sync_response_invalid',
      message: String(invocation.stderr || error).trim() || 'Windows credential sync returned invalid JSON',
    };
  }
  return nativeToolResponse(rpc, tool, structuredContent);
}

function runNativeTool(rpc) {
  const tool = String(rpc.params?.name ?? '');
  const command = nativeCommands.get(tool);
  if (process.platform !== 'darwin' || !command || !existsSync(nativeRuntime)) return null;
  let commandArguments = rpc.params?.arguments ?? {};
  const args = [command];
  if (tool === 'start') args.push(JSON.stringify(rpc.params?.arguments ?? {}));
  if (tool === 'scan_once' || tool === 'relaunch_and_confirm') args.push(JSON.stringify(rpc.params?.arguments ?? {}));
  if (tool === 'audit_log') args.push(String(rpc.params?.arguments?.limit ?? 20));
  if (tool === 'send_and_watch' || tool === 'add_connector' || [
    'account_add', 'account_login_link', 'account_switch', 'account_rename',
    'account_status', 'account_sync', 'account_remove',
    'enqueue_tasks', 'start_queue', 'update_task', 'wait_for_review', 'review_task', 'retry_task',
    'cancel_task', 'sync_actions_credentials', 'login_and_sync_actions', 'start_actions_runner',
  ].includes(tool)) args.push(JSON.stringify(commandArguments));
  const timeoutMs = tool === 'send_and_watch'
    ? 86_500_000
    : ['start_queue', 'wait_for_review'].includes(tool)
      ? 7_300_000
    : ['start', 'scan_once', 'relaunch_and_confirm'].includes(tool) ? 620_000
    : ['account_add', 'account_sync', 'login_and_sync_actions', 'start_actions_runner', 'sync_actions_credentials'].includes(tool) ? 2_000_000 : 15_000;
  const invocation = spawnSync(nativeRuntime, args, {
    encoding: 'utf8', timeout: timeoutMs, maxBuffer: 10 * 1024 * 1024,
    env: process.env,
  });
  const line = invocation.stdout.trim().split(/\r?\n/).at(-1);
  let structuredContent;
  try {
    if (invocation.error || !line) {
      throw invocation.error || new Error(
        invocation.signal
          ? `原生进程被信号 ${invocation.signal} 终止`
          : `原生进程退出码 ${invocation.status ?? 'unknown'}`);
    }
    structuredContent = JSON.parse(line || '{}');
    if (invocation.status !== 0 && structuredContent.ok !== false) {
      structuredContent = {
        ok: false,
        errorCode: 'native_nonzero_exit',
        message: `原生进程退出码 ${invocation.status}`,
        nativeResponse: structuredContent,
      };
    }
  } catch (error) {
    structuredContent = {
      ok: false, errorCode: 'native_response_invalid',
      message: invocation.stderr.trim() || String(error) || '原生插件没有返回有效 JSON',
    };
  }
  return {
    jsonrpc: '2.0', id: rpc.id,
    result: {
      content: [{ type: 'text', text: structuredContent.ok === false
        ? `原生插件执行失败：${structuredContent.message || structuredContent.errorCode}`
        : `原生插件已直接执行 ${tool}。` }],
      structuredContent,
      isError: structuredContent.ok === false,
    },
  };
}

// Recover an unfinished Browser job whenever the local plugin server is
// started. The supervisor waits for a newly authorized Browser host if the
// previous host/context was closed, so a later timer tick can resume it.
void resumePersistedBrowserSupervisor();
void resumePersistedReplyHandoffSupervisor();

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of lines) {
  let rpc;
  try {
    rpc = JSON.parse(line);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({
      jsonrpc: '2.0',
      id: null,
      error: { code: -32700, message: String(error) },
    })}\n`);
    continue;
  }
  const browserResponse = rpc.method === 'tools/call'
    ? await runInAppBrowserTool(rpc)
    : null;
  const localWorkBridgeResponse = rpc.method === 'tools/call'
    ? runLocalWorkBridgeTool(rpc)
    : null;
  const directResponse = rpc.method === 'tools/call'
    ? await runDirectDesktopTool(rpc)
    : null;
  const nativeResponse = browserResponse || localWorkBridgeResponse || directResponse || (rpc.method === 'tools/call'
    ? (runWindowsCredentialTool(rpc) || runNativeTool(rpc))
    : null);
  if (nativeResponse) {
    process.stdout.write(`${JSON.stringify(nativeResponse)}\n`);
    continue;
  }
  const response = await worker.fetch(new Request('https://standalone.invalid/mcp', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(rpc),
  }));
  if (rpc.id === undefined || response.status === 202 || response.status === 204) continue;
  const body = await response.text();
  if (body.trim()) process.stdout.write(`${body}\n`);
}
