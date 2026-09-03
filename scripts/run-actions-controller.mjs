import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const runtime = process.env.CHATGPT_AUTO_CONFIRM_NATIVE ||
  fileURLToPath(new URL('../runtime/macos/chatgpt-auto-confirm', import.meta.url));
const testMode = process.env.NODE_ENV === 'test';
const deadlineSeconds = Math.min(
  20_700,
  Math.max(testMode ? 1 : 300, Number(process.env.ACTION_SESSION_SECONDS || 20_400)),
);
const deadline = Date.now() + deadlineSeconds * 1_000;
const resultPath = process.env.ACTION_RESULT_PATH || 'action-result.json';
const pollIntervalMs = Math.max(
  testMode ? 10 : 1_000,
  Number(process.env.ACTION_POLL_INTERVAL_MS || 15_000),
);
const recoveryIntervalMs = Math.max(
  testMode ? 10 : 60_000,
  Number(process.env.ACTION_RECOVERY_INTERVAL_MS || 300_000),
);
const maxSameFailureRecoveries = Math.max(
  1,
  Number(process.env.ACTION_MAX_SAME_FAILURE_RECOVERIES || 3),
);
const taskRefreshIntervalMs = Math.max(
  testMode ? 10 : 15_000,
  Number(process.env.ACTION_TASK_REFRESH_INTERVAL_MS || 60_000),
);
const taskInboxPath = process.env.CHATGPT_AUTO_CONFIRM_TASK_INBOX_PATH?.trim() ||
  '.agents/plugins/plugins/chatgpt-auto-confirm/tasks/actions-inbox.json';
const taskInboxRef = process.env.CHATGPT_AUTO_CONFIRM_TASK_INBOX_REF?.trim() ||
  process.env.GITHUB_REF_NAME?.trim();
const githubRepository = process.env.GITHUB_REPOSITORY?.trim();
const githubToken = process.env.GH_TOKEN?.trim() || process.env.GITHUB_TOKEN?.trim();
const githubApiUrl = process.env.GITHUB_API_URL?.trim() || 'https://api.github.com';
const remoteTaskRefreshEnabled = Boolean(
  githubRepository && githubToken && taskInboxRef && process.env.ACTION_DISABLE_TASK_REFRESH !== 'true',
);

const encodeRepoPath = value => value.split('/').map(encodeURIComponent).join('/');

const fetchRepositoryText = async (filePath) => {
  const normalized = String(filePath || '').trim().replace(/^\/+/, '');
  if (!normalized || normalized.split('/').includes('..')) {
    throw new Error(`Invalid repository task source: ${filePath}`);
  }
  const url =
    `${githubApiUrl}/repos/${githubRepository}/contents/${encodeRepoPath(normalized)}` +
    `?ref=${encodeURIComponent(taskInboxRef)}`;
  const response = await fetch(url, {
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${githubToken}`,
      'x-github-api-version': '2022-11-28',
    },
  });
  if (!response.ok) {
    throw new Error(`GitHub contents ${normalized} returned ${response.status}`);
  }
  const payload = await response.json();
  if (payload.type !== 'file' || typeof payload.content !== 'string') {
    throw new Error(`GitHub contents ${normalized} did not return a file`);
  }
  return Buffer.from(payload.content.replace(/\s+/g, ''), 'base64').toString('utf8');
};

const run = (command, params = undefined) => {
  const args = [command];
  if (params !== undefined) args.push(JSON.stringify(params));
  const result = spawnSync(runtime, args, {
    encoding: 'utf8',
    env: process.env,
    timeout: 120_000,
    maxBuffer: 10 * 1024 * 1024,
  });
  const line = result.stdout.trim().split(/\r?\n/).at(-1);
  if (!line) throw new Error(`${command} returned no JSON`);
  const payload = JSON.parse(line);
  if (result.status !== 0 || payload.ok === false) {
    throw new Error(`${command} failed: ${payload.errorCode || payload.message || result.stderr}`);
  }
  return payload;
};

const remoteTaskDigests = new Map();
const refreshDynamicTaskDefinitions = async () => {
  if (!remoteTaskRefreshEnabled) return { enabled: false, updated: [] };
  const inboxText = await fetchRepositoryText(taskInboxPath);
  const inbox = JSON.parse(inboxText);
  const tasks = Array.isArray(inbox.tasks) ? inbox.tasks : [];
  const updated = [];
  for (const task of tasks) {
    if (!task?.id) continue;
    const revision = Math.max(1, Number(task.revision || 1));
    const specSources = Array.isArray(task.specSources) ? task.specSources : [];
    const specSections = [];
    for (const source of specSources) {
      const content = (await fetchRepositoryText(source)).trim();
      specSections.push(`## ${source}\n${content}`);
    }
    const specSnapshot = specSections.join('\n\n').trim();
    if (specSnapshot.length > 60_000) {
      throw new Error(`Task ${task.id} spec snapshot exceeds 60000 characters`);
    }
    const specDigest = specSnapshot
      ? `sha256:${createHash('sha256').update(specSnapshot).digest('hex')}`
      : null;
    const updateDigest = createHash('sha256').update(JSON.stringify({
      revision,
      title: task.title || '',
      prompt: task.prompt || '',
      directive: task.directive || '',
      specSources,
      specDigest,
    })).digest('hex');
    if (remoteTaskDigests.get(task.id) === updateDigest) continue;
    const result = run('queue_update', {
      taskId: task.id,
      revision,
      title: task.title,
      prompt: task.prompt,
      directive: task.directive,
      specSources,
      specSnapshot,
      specDigest,
      applyMode: task.applyMode === 'interrupt' ? 'interrupt' : 'next_chat',
      source: 'actions-controller',
    });
    remoteTaskDigests.set(task.id, updateDigest);
    if (result.updateApplied === true) updated.push(task.id);
  }
  return { enabled: true, updated };
};

const recognitionDiagnostics = task => {
  if (!task.replyDiagnostics) return null;
  const { pageSnapshot: _pageSnapshot, ...recognition } = task.replyDiagnostics;
  return recognition;
};

const taskDiagnostics = (queue) => (Array.isArray(queue?.tasks) ? queue.tasks : [])
  .map(task => ({
    id: task.id,
    status: task.status,
    attempts: task.attempts,
    continuationDepth: task.continuationDepth ?? null,
    maxTaskContinuations: task.maxTaskContinuations ?? null,
    currentRevision: task.currentRevision ?? 1,
    appliedRevision: task.appliedRevision ?? null,
    pendingRevision: task.pendingRevision ?? null,
    specDigest: task.specDigest || null,
    conversationId: task.conversationId || null,
    lastError: task.lastError || null,
    hiddenWorkerLastError: task.hiddenWorkerLastError || null,
    lastProgressAt: task.lastProgressAt || null,
    replyDiagnostics: recognitionDiagnostics(task),
  }));

const pageDiagnostics = queue => (Array.isArray(queue?.tasks) ? queue.tasks : [])
  .filter(task => task.replyDiagnostics?.pageSnapshot)
  .map(task => ({
    id: task.id,
    conversationId: task.conversationId || null,
    page: task.replyDiagnostics.pageSnapshot,
  }));

const maxLogChunkChars = 2_000;
const writeChunkedEvent = (label, payload) => {
  const serialized = JSON.stringify(payload);
  const total = Math.max(1, Math.ceil(serialized.length / maxLogChunkChars));
  for (let index = 0; index < total; index += 1) {
    const chunk = serialized.slice(
      index * maxLogChunkChars,
      (index + 1) * maxLogChunkChars,
    );
    process.stdout.write(
      `${label}_CHUNK ${index + 1}/${total} ${JSON.stringify(chunk)}\n`,
    );
  }
};

const commonPrefixLength = (left, right) => {
  const limit = Math.min(left.length, right.length);
  let index = 0;
  while (index < limit && left[index] === right[index]) index += 1;
  return index;
};

const pageFieldState = new Map();
const emitPageDiagnostics = queue => {
  for (const task of pageDiagnostics(queue)) {
    for (const [field, rawValue] of Object.entries(task.page)) {
      const value = typeof rawValue === 'string'
        ? rawValue
        : JSON.stringify(rawValue);
      const key = `${task.id}:${task.conversationId}:${field}`;
      const previous = pageFieldState.get(key);
      if (previous === undefined) {
        writeChunkedEvent('QUEUE_PAGE_FULL', {
          id: task.id,
          conversationId: task.conversationId,
          field,
          value,
        });
      } else if (previous !== value) {
        const prefixLength = commonPrefixLength(previous, value);
        writeChunkedEvent('QUEUE_PAGE_DELTA', {
          id: task.id,
          conversationId: task.conversationId,
          field,
          prefixLength,
          removedLength: previous.length - prefixLength,
          append: value.slice(prefixLength),
        });
      }
      pageFieldState.set(key, value);
    }
  }
};

let previousTrace = [];
const emitTraceEvents = queue => {
  const trace = Array.isArray(queue.watcherTrace) ? queue.watcherTrace : [];
  let overlap = Math.min(previousTrace.length, trace.length);
  while (
    overlap > 0
    && previousTrace.slice(-overlap).some((entry, index) => entry !== trace[index])
  ) {
    overlap -= 1;
  }
  for (const event of trace.slice(overlap)) {
    writeChunkedEvent('QUEUE_TRACE_EVENT', { event });
  }
  previousTrace = trace;
};

const writeResult = (status, queue, reason) => {
  const result = {
    status,
    reason,
    finishedAt: new Date().toISOString(),
    counts: queue?.counts || {},
    tasks: taskDiagnostics(queue),
  };
  writeFileSync(resultPath, `${JSON.stringify(result)}\n`);
  process.stdout.write(`ACTION_RESULT ${JSON.stringify(result)}\n`);
};

const queueFingerprint = queue => JSON.stringify(taskDiagnostics(queue));
const failureFingerprint = tasks => JSON.stringify(tasks
  .filter(task => ['failed', 'blocked'].includes(task.status))
  .map(task => ({
    id: task.id,
    status: task.status,
    lastError: task.lastError || null,
    hiddenWorkerLastError: task.hiddenWorkerLastError || null,
  })));
const failureDetail = task => [task.lastError, task.hiddenWorkerLastError]
  .filter(Boolean)
  .join(' ')
  .replace(/\s+/g, ' ');
const isNonRecoverableFailure = task =>
  /model_selection\s*:|model_picker_not_found|quick_chat_thinking_not_selected|reasoning_high_not_selected|target_model_not_selected|task_continuation_limit_reached|dependency_not_completed/.test(
    failureDetail(task),
  );
const watchdogDiagnostics = result => ({
  ok: result?.ok !== false,
  recovered: result?.recovered === true,
  eligibleTaskIds: result?.eligibleTaskIds || [],
  deferredTaskIds: result?.deferredTaskIds || [],
  watcherPid: result?.watcherPid || null,
  queue: {
    counts: result?.queue?.counts || {},
    tasks: taskDiagnostics(result?.queue),
  },
});

const taskHasActiveChatResponse = task => {
  const diagnostics = task?.replyDiagnostics || {};
  return [
    'waitingForApproval',
    'pending',
    'streaming',
    'stopAvailable',
    'devspaceWaiting',
  ].some(field => diagnostics[field] === true);
};

const initialRecovery = run('queue_watchdog', { staleAfterSeconds: 300, force: true });
process.stdout.write(`WATCHDOG_INITIAL ${JSON.stringify(watchdogDiagnostics(initialRecovery))}\n`);
let lastRecovery = 0;
let lastQueueFingerprint = '';
let lastFailureFingerprint = '';
let sameFailureRecoveries = 0;
let lastTaskRefresh = 0;
while (Date.now() < deadline) {
  if (Date.now() - lastTaskRefresh >= taskRefreshIntervalMs) {
    try {
      const refresh = await refreshDynamicTaskDefinitions();
      if (refresh.updated.length > 0) {
        process.stdout.write(`TASK_DEFINITIONS_UPDATED ${JSON.stringify(refresh)}\n`);
      }
    } catch (error) {
      process.stdout.write(`TASK_DEFINITION_REFRESH_WARNING ${JSON.stringify({
        message: error instanceof Error ? error.message : String(error),
        ref: taskInboxRef || null,
        path: taskInboxPath,
      })}\n`);
    }
    lastTaskRefresh = Date.now();
  }
  const queue = run('queue_status');
  const tasks = Array.isArray(queue.tasks) ? queue.tasks : [];
  const fingerprint = queueFingerprint(queue);
  if (fingerprint !== lastQueueFingerprint) {
    process.stdout.write(`QUEUE_RECOGNITION ${fingerprint}\n`);
    lastQueueFingerprint = fingerprint;
  }
  emitPageDiagnostics(queue);
  emitTraceEvents(queue);
  if (tasks.length === 0) {
    writeResult('failed', queue, 'no_tasks_configured');
    process.exit(1);
  }
  const complete = tasks.length > 0 &&
    tasks.every(task => ['completed', 'cancelled'].includes(task.status));
  if (complete) {
    writeResult('complete', queue, 'all_tasks_terminal');
    process.exit(0);
  }
  const allTerminal = tasks.length > 0 && tasks.every(task =>
    ['completed', 'cancelled', 'failed', 'blocked'].includes(task.status));
  const recoverableTerminalTasks = tasks.filter(task =>
    ['failed', 'blocked'].includes(task.status) && !isNonRecoverableFailure(task));
  const hasRecoverableTerminalFailure = recoverableTerminalTasks.length > 0;
  if (allTerminal && !hasRecoverableTerminalFailure) {
    writeResult('failed', queue, 'terminal_task_failure');
    process.exit(1);
  }
  if (allTerminal && hasRecoverableTerminalFailure) {
    // Native task attempts already enforce maxRuntimeRetries. Requeueing a
    // terminal task here used the operator-only queue_retry command, reset the
    // terminal state, and allowed a broken renderer to loop for the full
    // hosted session. Preserve the exhausted task exactly as-is and yield it
    // once to the outer controller for encrypted state upload and diagnosis.
    writeResult('incomplete', queue, 'recoverable_task_retry_budget_exhausted');
    process.exit(0);
  }

  const needsWatchdogRecovery = tasks.some(task =>
    task.status === 'running'
    && task.lastError
    && String(task.lastError).includes('not_chat_surface')
    // A renderer can report `not_chat_surface` while the same Chat is already
    // streaming or waiting for a permission card. Keep polling that Chat so
    // its response/authorization can finish instead of opening a duplicate.
    && !taskHasActiveChatResponse(task));
  const needsRecovery = needsWatchdogRecovery;
  if (needsRecovery && Date.now() - lastRecovery >= recoveryIntervalMs) {
    const currentFailureFingerprint = failureFingerprint(tasks);
    if (currentFailureFingerprint === lastFailureFingerprint) {
      sameFailureRecoveries += 1;
    } else {
      lastFailureFingerprint = currentFailureFingerprint;
      sameFailureRecoveries = 1;
    }
    if (sameFailureRecoveries > maxSameFailureRecoveries) {
      // A recoverable UI/runtime failure must never cut the continuous runner
      // chain. Yield the encrypted queue state to the next Actions run instead
      // of reporting a terminal failure.
      writeResult('incomplete', queue, 'repeated_recoverable_task_failure');
      process.exit(0);
    }

    const recovery = run('queue_watchdog', { staleAfterSeconds: 300, force: true });
    process.stdout.write(
      `WATCHDOG_RECOVERY attempt=${sameFailureRecoveries} ` +
      `${JSON.stringify(watchdogDiagnostics(recovery))}\n`,
    );
    lastRecovery = Date.now();
  }
  await new Promise(resolve => setTimeout(resolve, pollIntervalMs));
}

const finalQueue = run('queue_status');
const finalRecovery = run('queue_watchdog', { staleAfterSeconds: 300, force: true });
process.stdout.write(`WATCHDOG_DEADLINE ${JSON.stringify(watchdogDiagnostics(finalRecovery))}\n`);
writeResult('incomplete', finalQueue, 'hosted_runner_session_deadline');
