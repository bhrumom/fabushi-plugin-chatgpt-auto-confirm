import { readFileSync, writeFileSync } from 'node:fs';

const statePath = process.env.CHATGPT_AUTO_CONFIRM_QUEUE_STATE;
if (!statePath) throw new Error('CHATGPT_AUTO_CONFIRM_QUEUE_STATE is required');
const state = JSON.parse(readFileSync(statePath, 'utf8'));
const accountId = String(process.env.CHATGPT_ACCOUNT_ID || '').trim();
if (accountId) {
  if (state.accountId && state.accountId !== accountId) {
    throw new Error('queue state account mismatch');
  }
  state.accountId = accountId;
  for (const task of state.automationTasks || []) {
    if (task.accountId && task.accountId !== accountId) {
      throw new Error('queue task account mismatch');
    }
    task.accountId ||= accountId;
  }
}
state.enabled = true;
state.approveAll = true;
state.watcherPid = null;
state.backgroundTargets = {};
state.backgroundAppPort = null;
state.backgroundChatTargetId = null;
state.backgroundConversationId = null;
state.queueEnabled = true;
state.queuePaused = false;
state.queueWatcherPid = null;
state.queueWorkerPort = null;
state.queueWorkerTargetId = null;
state.queueWorkerProfilePath = null;
state.queueWorkerMode = null;
for (const task of state.automationTasks || []) {
  task.workerPid = null;
  task.workerPort = null;
  task.workerTargetId = null;
  task.workerStatePath = null;
  task.workerProfilePath = null;
  task.resultPath = null;
  if (task.status === 'running') {
    if (String(task.conversationId || '').startsWith('local-chatgpt:')) {
      // A local-only id belongs to the renderer on the previous hosted VM.
      // It has no server route to restore, so preserving it as running makes
      // every continuation stare at a provisional Chat that can never appear
      // in the account sidebar. Requeue once and create a fresh Chat instead.
      task.status = 'queued';
      task.startedAt = null;
      task.lastProgressAt = null;
      task.conversationId = null;
      task.chatURL = null;
      task.lastError = 'github_actions_local_chat_requeued';
      const note = '上一托管 Runner 只留下本地临时 Chat，无法恢复；请在新 Chat 中从同一 checkout 的落盘进度继续。';
      task.reviewFeedback = [task.reviewFeedback, note].filter(Boolean).join('\n\n');
    } else {
      // Keep both the active state and durable Chat identity across hosted
      // runner rotation. monitorAutomationTask recreates only the hidden
      // renderer, navigates back to this conversation, confirms pending
      // authorization, and observes its real terminal state.
      // Refresh only the handoff heartbeat so the startup watchdog does not
      // declare the task stale before the first monitor pass can reattach.
      task.lastProgressAt = new Date().toISOString();
      task.lastError = 'github_actions_runner_continuation';
      const note = 'GitHub Actions 已在新托管 Runner 中接管。请从同一 checkout 的最新落盘进度继续。';
      task.reviewFeedback = [task.reviewFeedback, note].filter(Boolean).join('\n\n');
    }
  }
  if (['failed', 'blocked'].includes(task.status)) {
    task.status = 'queued';
    task.startedAt = null;
    task.finishedAt = null;
    task.attempts = 0;
    task.lastError = 'github_actions_runner_retry';
  }
}
writeFileSync(statePath, `${JSON.stringify(state)}\n`, { mode: 0o600 });
