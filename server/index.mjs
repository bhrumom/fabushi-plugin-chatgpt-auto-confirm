import readline from 'node:readline';
import { existsSync } from 'node:fs';
import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { dirname, resolve } from 'node:path';
import worker from '../worker/src/index.ts';
import { DEFAULT_BROWSER_HEARTBEAT_SLICE_MS } from '../scripts/in-app-browser-capability-host.mjs';
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
  goalOnlyDispatch: true,
  approveAll: true,
  timeout: 21_600,
  stagnationTimeout: 10_800,
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
// requires a matching user-message bubble before reporting success. This is
// intentionally separate from the Browser capability path.
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
      clickedByDom: ${clickedValue}
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
  if (!target) return {
    ok: false, errorCode: 'desktop_chat_target_unavailable',
    message: `插件专用桌面 ChatGPT 调试目标不可用（端口 ${port}）。`,
    backgroundOnly: true, workerUsed: false, surface: 'chat', port,
  };
  const approval = await desktopEvaluate(target, desktopApprovalExpression());
  if (!approval) return {
    ok: true, approved: false, approvalConfirmed: true,
    message: connector
      ? `当前没有检测到结构化授权卡（调用方标记：${connector}）。`
      : '当前没有检测到结构化授权卡。',
    backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
    backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
    };
  })()`;
}

function desktopConversationId(value) {
  const raw = String(value || '').trim();
  return raw.startsWith('chatgpt:') ? raw.slice('chatgpt:'.length) : raw || null;
}

function compactDesktopDispatchPrompt(args, fallbackMessage) {
  let goal = String(args.originalGoal || fallbackMessage || '').trim();
  for (const marker of ['MAHAYANA_TASK_REPORT_CONTRACT_V5', 'MAHAYANA_TASK_REPORT_V1_BEGIN']) {
    const markerIndex = goal.indexOf(marker);
    if (markerIndex >= 0) goal = goal.slice(0, markerIndex).trim();
  }
  const taskId = JSON.stringify(String(args.taskId || 'CURRENT_TASK_ID').trim() || 'CURRENT_TASK_ID');
  const revision = Number.isInteger(args.appliedTaskRevision)
    ? args.appliedTaskRevision : 1;
  const digest = JSON.stringify(String(args.appliedSpecDigest || 'CURRENT_SPEC_DIGEST').trim()
    || 'CURRENT_SPEC_DIGEST');
  return `${goal}\n\n完成整个目标后，在回复末尾只输出以下完成回执（未完成时不要伪造 complete）：\nMAHAYANA_TASK_REPORT_V1_BEGIN\n{"protocol":"mahayana.task-report.v1","task_id":${taskId},"applied_task_revision":${revision},"applied_spec_digest":${digest},"status":"complete","all_tasks_complete":true,"summary":"整个目标已完成","completed":["列出实现、验证和发布证据"],"remaining":[],"blockers":[],"verification":["列出可复核证据"],"wait_seconds":0,"wait_reason":"","next_connector":"","next_task":""}\nMAHAYANA_TASK_REPORT_V1_END`;
}

async function directDesktopSend(rpc) {
  const args = rpc.params?.arguments ?? {};
  const rawMessage = String(args.message || '').trim();
  const message = compactDesktopDispatchPrompt(args, rawMessage);
  const connector = String(args.connector || '').trim();
  if (!message) return {
    ok: false, errorCode: 'missing_message', message: '请提供 message 参数',
    backgroundOnly: true, workerUsed: false, surface: 'chat',
  };
  const port = desktopCDPPort(args);
  let target = await desktopTarget(port, args.backgroundTargetId || null);
  if (!target) return {
    ok: false, errorCode: 'desktop_chat_target_unavailable',
    message: `插件专用桌面 ChatGPT 调试目标不可用（端口 ${port}）。`,
    backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
  let surface = await evaluate(desktopSurfaceExpression);
  if (!surface?.ok) {
    if (!await click(desktopChatButtonExpression)) return {
      ok: false, errorCode: 'desktop_chat_mode_button_not_found',
      message: '插件未找到桌面 ChatGPT 的 Chat 模式按钮，未发送。',
      backgroundOnly: true, workerUsed: false, surface: 'not-chat', port,
    };
    surface = await waitUntil(async () => {
      const current = await evaluate(desktopSurfaceExpression);
      return current?.ok ? current : null;
    });
  }
  if (!surface?.ok) return {
    ok: false, errorCode: 'desktop_chat_surface_not_ready',
    message: '桌面 ChatGPT 未进入可发送的 Chat 表面，未发送。',
    backgroundOnly: true, workerUsed: false, surface: 'not-chat', port,
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
        backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
        backgroundOnly: true, workerUsed: false, surface: 'chat', port,
      };
    }
  }

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
    backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
        backgroundOnly: true, workerUsed: false, surface: 'chat', port,
      };
      const menuItem = await waitUntil(async () => evaluate(desktopConnectorMenuExpression(connector)), 5_000);
      if (!menuItem) return {
        ok: false, errorCode: 'desktop_connector_not_found',
        message: `桌面 ChatGPT Apps 菜单中没有找到连接器 ${connector}，未发送。`,
        backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
      backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
    backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
    backgroundOnly: true, workerUsed: false, surface: 'chat', port,
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
    backgroundOnly: true, workerUsed: false, surface: 'chat', port,
    connector, connectorConfirmed, inputConfirmed: true,
  };
  const conversationId = desktopConversationId(sentState.conversationId)
    || desktopConversationId(surface.conversationId);
  return {
    ok: true, sent: true, messageConfirmed: true, connector,
    connectorConfirmed: connector ? true : false,
    inputConfirmed: true, surface: 'chat', backgroundOnly: true, workerUsed: false,
    port, targetId: target.id, conversationId,
    chatUrl: String(sentState.url || '').startsWith('https://chatgpt.com/')
      ? sentState.url : null,
    monitorStarted: false,
    sentAt: new Date().toISOString(),
  };
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
        backgroundOnly: true, workerUsed: false, surface: 'chat',
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
      backgroundOnly: true,
      workerUsed: false,
      surface: 'chat',
    };
  }
  if (!dispatched?.ok) return nativeToolResponse(rpc, tool, dispatched);
  const jobId = `desktop_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  desktopDirectJobs.set(jobId, {
    id: jobId,
    status: 'dispatched',
    conversationId: dispatched.conversationId,
    connector: dispatched.connector,
    sentAt: dispatched.sentAt,
  });
  return nativeToolResponse(rpc, tool, {
    ...dispatched,
    jobId,
    monitorStarted: false,
    message: '插件已在桌面 ChatGPT Chat 中确认发送；后续监督可绑定此 jobId。',
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
