import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const statePath = process.env.CHATGPT_AUTO_CONFIRM_QUEUE_STATE;
const inboxPath = process.env.CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE?.trim();
const workspace = path.resolve(process.env.GITHUB_WORKSPACE || process.cwd());
if (!statePath) throw new Error('CHATGPT_AUTO_CONFIRM_QUEUE_STATE is required');
if (!inboxPath) throw new Error('CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE is required');

const inbox = JSON.parse(readFileSync(inboxPath, 'utf8'));
const incomingRaw = Array.isArray(inbox.tasks) ? inbox.tasks : [];
const state = JSON.parse(readFileSync(statePath, 'utf8'));

const readSpecSnapshot = (task) => {
  const sources = Array.isArray(task.specSources) ? task.specSources : [];
  if (sources.length === 0) return { specSnapshot: '', specDigest: null };
  const sections = sources.map((source) => {
    if (typeof source !== 'string' || !source.trim()) {
      throw new Error(`Task ${task.id} contains an invalid spec source`);
    }
    const resolved = path.resolve(workspace, source);
    if (resolved !== workspace && !resolved.startsWith(`${workspace}${path.sep}`)) {
      throw new Error(`Task ${task.id} spec source escapes workspace: ${source}`);
    }
    return `## ${source}\n${readFileSync(resolved, 'utf8').trim()}`;
  });
  const specSnapshot = sections.join('\n\n').trim();
  if (specSnapshot.length > 120_000) {
    throw new Error(`Task ${task.id} spec snapshot exceeds 120000 characters`);
  }
  const specDigest = `sha256:${createHash('sha256').update(specSnapshot).digest('hex')}`;
  return { specSnapshot, specDigest };
};

const incoming = incomingRaw.map((task) => ({
  ...task,
  revision: Math.max(1, Number(task?.revision || 1)),
  maxTaskContinuations: Math.min(
    20,
    Math.max(0, Number(task?.maxTaskContinuations ?? 0)),
  ),
  ...readSpecSnapshot(task),
}));
const incomingIds = new Set(incoming.map(task => task?.id).filter(Boolean));
const originalTasks = Array.isArray(state.automationTasks) ? state.automationTasks : [];
const removed = [];
const tasks = inbox.authoritative === true
  ? originalTasks.filter((task) => {
    const keep = incomingIds.has(task?.id);
    if (!keep && task?.id) removed.push(task.id);
    return keep;
  })
  : originalTasks;
const knownTasks = new Map(tasks.map(task => [task.id, task]));
const now = new Date().toISOString();
const appended = [];
const requeued = [];
const revised = [];

const resetExecution = (task, freshGoal = false) => {
  const reviewConversationId = String(task.reviewConversationId || '').trim();
  if (reviewConversationId) {
    // A review Chat is a branch of this same task. Recovery/revision must
    // continue from the newest branch instead of erasing the task identity and
    // creating another top-level Chat.
    task.conversationId = reviewConversationId;
    if (!reviewConversationId.startsWith('local-chatgpt:')) {
      task.chatURL = `https://chatgpt.com/c/${reviewConversationId}`;
    }
  }
  task.attempts = 0;
  task.status = 'queued';
  task.startedAt = null;
  task.finishedAt = null;
  task.workerPid = null;
  task.workerPort = null;
  task.workerTargetId = null;
  task.workerStatePath = null;
  task.workerProfilePath = null;
  task.resultPath = null;
  task.reviewConversationId = null;
  task.reviewStatus = null;
  task.reviewReport = null;
  task.report = null;
  task.lastResultJSON = null;
  task.lastActivitySignature = null;
  task.lastProgressAt = null;
  task.hiddenWorkerLastHeartbeatAt = null;
  task.hiddenWorkerLastError = null;
  task.waitingUntil = null;
  task.waitReason = null;
  task.lastError = null;
  if (freshGoal) {
    task.conversationId = null;
    task.chatURL = null;
    task.continuationDepth = 0;
    task.appliedRevision = task.appliedRevision || null;
    task.appliedSpecDigest = task.appliedSpecDigest || null;
  }
  task.updatedAt = now;
};

for (const task of incoming) {
  if (!task?.id) continue;
  const existing = knownTasks.get(task.id);
  if (existing) {
    const previousRevision = Math.max(1, Number(existing.currentRevision || 1));
    const previousSpecDigest = existing.specDigest || null;
    const contentChanged = task.specDigest !== previousSpecDigest
      || (task.prompt !== undefined && task.prompt !== existing.prompt)
      || (task.title !== undefined && task.title !== existing.title)
      || (task.repository || null) !== (existing.repository || null)
      || (task.codeDirectory || null) !== (existing.codeDirectory || null)
      || (task.directive || null) !== (existing.pendingDirective || null);
    if (task.revision < previousRevision) continue;
    if (task.revision === previousRevision && contentChanged) {
      throw new Error(`Task ${task.id} revision ${task.revision} changed without incrementing revision`);
    }
    const specChanged = task.revision > previousRevision;
    for (const field of [
      'title', 'prompt', 'promptTemplate', 'connector', 'dependsOn',
      'repository', 'codeDirectory',
      'resourceLocks', 'priority', 'timeout', 'maxTaskContinuations',
      'maxRuntimeRetries',
    ]) {
      if (task[field] !== undefined) existing[field] = task[field];
    }
    existing.originalPrompt ||= existing.prompt;
    existing.currentRevision = task.revision;
    existing.specSources = task.specSources || [];
    existing.specSnapshot = task.specSnapshot || '';
    existing.specDigest = task.specDigest;
    existing.workspaceRoot = workspace;
    existing.taskControlPath = path.relative(workspace, inboxPath);
    existing.pendingDirective = task.directive || null;
    existing.applyMode = task.applyMode === 'interrupt' ? 'interrupt' : 'next_chat';
    existing.taskUpdates ||= [];
    if (specChanged) {
      existing.taskUpdates.push({
        id: `inbox-${task.revision}-${Date.now()}`,
        revision: task.revision,
        createdAt: now,
        source: 'actions-inbox',
        directive: task.directive || '',
        specDigest: task.specDigest || '',
        applyMode: existing.applyMode,
      });
      existing.taskUpdates = existing.taskUpdates.slice(-100);
    }
    existing.specUpdatedAt = now;
    existing.pendingRevision = specChanged ? task.revision : existing.pendingRevision;
    existing.updatedAt = now;
    if (specChanged && existing.status !== 'cancelled') {
      existing.reviewFeedback =
        `任务规范已更新到 revision ${task.revision}；旧修订完成结果无效。`;
      // A changed goal is a new project round, never a continuation of the
      // old Chat. The old server-side response may finish independently, but
      // the queue immediately drops its branch identity and sends a full
      // first-round prompt in a fresh Chat.
      resetExecution(existing, true);
      revised.push(existing.id);
    } else if (['failed', 'blocked'].includes(existing.status)) {
      resetExecution(existing);
      requeued.push(existing.id);
    }
    continue;
  }
  tasks.push({
    id: task.id,
    title: task.title,
    prompt: task.prompt,
    originalPrompt: task.prompt,
    promptTemplate: task.promptTemplate || 'continue-to-complete',
    currentRevision: task.revision,
    appliedRevision: null,
    pendingRevision: task.revision,
    specSources: task.specSources || [],
    specSnapshot: task.specSnapshot || '',
    specDigest: task.specDigest,
    workspaceRoot: workspace,
    taskControlPath: path.relative(workspace, inboxPath),
    repository: task.repository || null,
    codeDirectory: task.codeDirectory || null,
    appliedSpecDigest: null,
    pendingDirective: task.directive || null,
    applyMode: task.applyMode === 'interrupt' ? 'interrupt' : 'next_chat',
    taskUpdates: [],
    specUpdatedAt: now,
    connector: task.connector || 'GitHub',
    dependsOn: task.dependsOn || [],
    resourceLocks: task.resourceLocks || [],
    priority: task.priority || 0,
    timeout: task.timeout || 21600,
    maxTaskContinuations: task.maxTaskContinuations,
    maxRuntimeRetries: task.maxRuntimeRetries ?? 2,
    attempts: 0,
    reviewRound: 0,
    status: 'queued',
    createdAt: now,
    updatedAt: now,
    startedAt: null,
    finishedAt: null,
    workerPid: null,
    workerPort: null,
    workerTargetId: null,
    workerStatePath: null,
    workerProfilePath: null,
    resultPath: null,
    conversationId: null,
    reviewConversationId: null,
    reviewStatus: null,
    reviewReport: null,
    chatURL: null,
    report: null,
    lastResultJSON: null,
    lastError: null,
    reviewFeedback: null,
    reviewedAt: null,
    continuationDepth: 0,
    reportFingerprints: [],
    lastActivitySignature: null,
    lastProgressAt: null,
    hiddenWorkerLastHeartbeatAt: null,
    hiddenWorkerRecoveryCount: 0,
    hiddenWorkerLastError: null,
    watchdogLastRecoveryAt: null,
    watchdogRecoveryCount: 0,
    waitingUntil: null,
    waitReason: null,
  });
  knownTasks.set(task.id, tasks.at(-1));
  appended.push(task.id);
}

state.automationTasks = tasks;
state.queueEnabled = true;
state.queuePaused = false;
state.queueMaxConcurrent = Math.min(4, Math.max(2,
  Number(inbox.maxConcurrent || state.queueMaxConcurrent || 2)));
state.queueReviewGate = inbox.reviewGate ?? false;
writeFileSync(statePath, `${JSON.stringify(state)}\n`, { mode: 0o600 });
process.stdout.write(
  `Imported ${appended.length} new queued task(s); revised ${revised.length}; ` +
  `requeued ${requeued.length} failed task(s).` +
  `${revised.length ? ` Revised: ${revised.join(', ')}.` : ''}` +
  `${requeued.length ? ` Requeued: ${requeued.join(', ')}.` : ''}` +
  `${removed.length ? ` Removed stale tasks: ${removed.join(', ')}.` : ''}\n`,
);
