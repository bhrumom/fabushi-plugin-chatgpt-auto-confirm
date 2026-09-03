import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

test('Actions inbox appends a dynamic task once and enables parallel scheduling', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-inbox-'));
  const statePath = path.join(directory, 'state.json');
  const inboxPath = path.join(directory, 'actions-inbox.json');
  const script = fileURLToPath(
    new URL('../scripts/import-actions-task-inbox.mjs', import.meta.url));
  const inbox = {
    maxConcurrent: 2,
    reviewGate: false,
    tasks: [{
      id: 'marketplace-parallel',
      title: 'Marketplace',
      prompt: 'Finish the marketplace',
      resourceLocks: ['worktree:marketplace'],
      maxTaskContinuations: 0,
    }],
  };
  const env = {
    ...process.env,
    CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
    CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE: inboxPath,
  };
  try {
    writeFileSync(statePath, JSON.stringify({ automationTasks: [] }));
    writeFileSync(inboxPath, JSON.stringify(inbox));
    execFileSync(process.execPath, [script], { env });
    execFileSync(process.execPath, [script], { env });
    const state = JSON.parse(readFileSync(statePath, 'utf8'));
    assert.equal(state.automationTasks.length, 1);
    assert.equal(state.automationTasks[0].id, 'marketplace-parallel');
    assert.equal(state.automationTasks[0].maxTaskContinuations, 0);
    assert.equal(state.queueMaxConcurrent, 2);
    assert.equal(state.queueReviewGate, false);
    assert.equal(state.queueEnabled, true);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('Actions inbox promotes and requeues an existing failed task revision', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-inbox-retry-'));
  const statePath = path.join(directory, 'state.json');
  const inboxPath = path.join(directory, 'actions-inbox.json');
  const script = fileURLToPath(
    new URL('../scripts/import-actions-task-inbox.mjs', import.meta.url));
  const env = {
    ...process.env,
    CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
    CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE: inboxPath,
  };
  try {
    writeFileSync(statePath, JSON.stringify({
      automationTasks: [{
        id: 'marketplace-parallel',
        title: 'Old title',
        prompt: 'Old prompt',
        status: 'failed',
        attempts: 3,
        workerPid: 123,
        workerTargetId: 'stale-target',
        conversationId: 'stale-conversation',
        currentRevision: 1,
        originalPrompt: 'Original target',
        lastError: 'new_chat_prepare_failed',
      }],
    }));
    writeFileSync(inboxPath, JSON.stringify({
      maxConcurrent: 2,
      tasks: [{
        id: 'marketplace-parallel',
        revision: 2,
        title: 'Updated title',
        prompt: 'Updated prompt',
        maxRuntimeRetries: 4,
      }],
    }));
    const output = execFileSync(process.execPath, [script], { env, encoding: 'utf8' });
    const state = JSON.parse(readFileSync(statePath, 'utf8'));
    const task = state.automationTasks[0];
    assert.match(output, /revised 1/);
    assert.equal(state.automationTasks.length, 1);
    assert.equal(task.title, 'Updated title');
    assert.equal(task.prompt, 'Updated prompt');
    assert.equal(task.originalPrompt, 'Original target');
    assert.equal(task.currentRevision, 2);
    assert.equal(task.taskUpdates.length, 1);
    assert.equal(task.maxRuntimeRetries, 4);
    assert.equal(task.status, 'queued');
    assert.equal(task.attempts, 0);
    assert.equal(task.workerPid, null);
    assert.equal(task.workerTargetId, null);
    assert.equal(task.conversationId, null);
    assert.equal(task.continuationDepth, 0);
    assert.equal(task.lastError, null);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('authoritative Actions inbox removes stale tasks from restored initial state', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-inbox-authoritative-'));
  const statePath = path.join(directory, 'state.json');
  const inboxPath = path.join(directory, 'actions-inbox.json');
  const script = fileURLToPath(
    new URL('../scripts/import-actions-task-inbox.mjs', import.meta.url));
  const env = {
    ...process.env,
    CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
    CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE: inboxPath,
  };
  try {
    writeFileSync(statePath, JSON.stringify({
      automationTasks: [
        { id: 'autonomous-pr-manager-001', status: 'queued', attempts: 1519 },
        {
          id: 'marketplace-current', title: 'Previous marketplace task',
          prompt: 'Previous work', currentRevision: 1, status: 'failed', attempts: 4,
        },
      ],
    }));
    writeFileSync(inboxPath, JSON.stringify({
      authoritative: true,
      tasks: [{
        id: 'marketplace-current',
        revision: 2,
        title: 'Current marketplace task',
        prompt: 'Continue current work',
      }],
    }));
    const output = execFileSync(process.execPath, [script], { env, encoding: 'utf8' });
    const state = JSON.parse(readFileSync(statePath, 'utf8'));
    assert.match(output, /Removed stale tasks: autonomous-pr-manager-001/);
    assert.deepEqual(state.automationTasks.map(task => task.id), ['marketplace-current']);
    assert.equal(state.automationTasks[0].status, 'queued');
    assert.equal(state.automationTasks[0].attempts, 0);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});


test('Actions inbox promotes a newer task revision with a hashed spec snapshot', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-inbox-revision-'));
  const statePath = path.join(directory, 'state.json');
  const inboxPath = path.join(directory, 'actions-inbox.json');
  const specPath = path.join(directory, 'docs', 'marketplace.md');
  const script = fileURLToPath(
    new URL('../scripts/import-actions-task-inbox.mjs', import.meta.url));
  const env = {
    ...process.env,
    GITHUB_WORKSPACE: directory,
    CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
    CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE: inboxPath,
  };
  try {
    mkdirSync(path.dirname(specPath), { recursive: true });
    writeFileSync(specPath, '# Marketplace revision 2\nUse immutable Cloudflare releases.');
    writeFileSync(statePath, JSON.stringify({
      automationTasks: [{
        id: 'marketplace-current',
        title: 'Marketplace',
        prompt: 'Old target',
        currentRevision: 1,
        appliedRevision: 1,
        specDigest: 'sha256:old',
        status: 'completed',
        attempts: 9,
      }],
    }));
    writeFileSync(inboxPath, JSON.stringify({
      tasks: [{
        id: 'marketplace-current',
        title: 'Marketplace',
        prompt: 'Updated target',
        revision: 2,
        specSources: ['docs/marketplace.md'],
        directive: 'Apply the current architecture',
      }],
    }));
    const output = execFileSync(process.execPath, [script], { env, encoding: 'utf8' });
    const state = JSON.parse(readFileSync(statePath, 'utf8'));
    const task = state.automationTasks[0];
    assert.match(output, /revised 1/);
    assert.equal(task.currentRevision, 2);
    assert.equal(task.pendingRevision, 2);
    assert.equal(task.status, 'queued');
    assert.equal(task.attempts, 0);
    assert.equal(task.specSources[0], 'docs/marketplace.md');
    assert.match(task.specSnapshot, /immutable Cloudflare releases/);
    assert.match(task.specDigest, /^sha256:[a-f0-9]{64}$/);
    assert.match(task.reviewFeedback, /revision 2/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});


test('Actions inbox accepts large multi-document spec snapshots used by hosted tasks', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-inbox-large-spec-'));
  const statePath = path.join(directory, 'state.json');
  const inboxPath = path.join(directory, 'actions-inbox.json');
  const specPath = path.join(directory, 'docs', 'large.md');
  const script = fileURLToPath(
    new URL('../scripts/import-actions-task-inbox.mjs', import.meta.url));
  const env = {
    ...process.env,
    GITHUB_WORKSPACE: directory,
    CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
    CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE: inboxPath,
  };
  try {
    mkdirSync(path.dirname(specPath), { recursive: true });
    writeFileSync(specPath, 'x'.repeat(80_000));
    writeFileSync(statePath, JSON.stringify({ automationTasks: [] }));
    writeFileSync(inboxPath, JSON.stringify({
      tasks: [{
        id: 'large-spec-task',
        revision: 1,
        title: 'Large spec',
        prompt: 'Follow the complete specification',
        specSources: ['docs/large.md'],
      }],
    }));
    execFileSync(process.execPath, [script], { env });
    const state = JSON.parse(readFileSync(statePath, 'utf8'));
    assert.ok(state.automationTasks[0].specSnapshot.length > 77_000);
    assert.match(state.automationTasks[0].specDigest, /^sha256:[a-f0-9]{64}$/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});


test('Actions inbox rejects changed content without a revision increment', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-inbox-conflict-'));
  const statePath = path.join(directory, 'state.json');
  const inboxPath = path.join(directory, 'actions-inbox.json');
  const script = fileURLToPath(
    new URL('../scripts/import-actions-task-inbox.mjs', import.meta.url));
  const env = {
    ...process.env,
    CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
    CHATGPT_AUTO_CONFIRM_TASK_INBOX_FILE: inboxPath,
  };
  try {
    writeFileSync(statePath, JSON.stringify({ automationTasks: [{
      id: 'versioned-task', title: 'Task', prompt: 'Revision one',
      originalPrompt: 'Revision one', currentRevision: 1, status: 'queued',
    }] }));
    writeFileSync(inboxPath, JSON.stringify({ tasks: [{
      id: 'versioned-task', revision: 1, title: 'Task', prompt: 'Changed without bump',
    }] }));
    assert.throws(
      () => execFileSync(process.execPath, [script], { env, stdio: 'pipe' }),
      /revision 1 changed without incrementing revision/,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
