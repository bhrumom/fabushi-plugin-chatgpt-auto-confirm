import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const controller = fileURLToPath(
  new URL('../scripts/run-actions-controller.mjs', import.meta.url));

test('Actions controller yields repeated recoverable failures to the next workflow run', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-controller-'));
  const runtimePath = path.join(directory, 'fake-runtime.mjs');
  const resultPath = path.join(directory, 'action-result.json');
  try {
    writeFileSync(runtimePath, `#!/usr/bin/env node
const command = process.argv[2];
if (command === 'queue_watchdog') {
  console.log(JSON.stringify({ ok: true, recovered: true }));
} else if (command === 'queue_retry') {
  console.log(JSON.stringify({ ok: true, retriedTask: { status: 'queued' } }));
} else if (command === 'queue_status') {
  console.log(JSON.stringify({
    ok: true,
    counts: { failed: 1 },
    tasks: [{
      id: 'broken-task',
      status: 'failed',
      attempts: 3,
      lastError: 'new_chat_prepare_failed',
      hiddenWorkerLastError: 'queue_monitor_hidden_target_rebuild_failed:missing',
      replyDiagnostics: {
        done: false,
        responseActionsComplete: false,
        responseControlLabels: ['复制', '在新任务中继续'],
        pageSnapshot: {
          pageContent: '最终结果\\n复制\\n在新任务中继续',
          assistantContent: '最终结果',
        },
      },
    }],
    watcherTrace: ['[2026-07-30T08:00:00Z] task=broken-task stage=monitor'],
  }));
} else {
  console.log(JSON.stringify({ ok: false, message: 'unexpected command' }));
  process.exitCode = 1;
}
`);
    chmodSync(runtimePath, 0o755);
    const result = spawnSync(process.execPath, [controller], {
      encoding: 'utf8',
      timeout: 5_000,
      env: {
        ...process.env,
        NODE_ENV: 'test',
        CHATGPT_AUTO_CONFIRM_NATIVE: runtimePath,
        ACTION_RESULT_PATH: resultPath,
        ACTION_SESSION_SECONDS: '2',
        ACTION_POLL_INTERVAL_MS: '10',
        ACTION_RECOVERY_INTERVAL_MS: '10',
        ACTION_MAX_SAME_FAILURE_RECOVERIES: '1',
      },
    });
    assert.equal(result.status, 0);
    assert.doesNotMatch(result.stdout, /QUEUE_RETRY_RECOVERY/);
    assert.match(result.stdout, /ACTION_RESULT/);
    const report = JSON.parse(readFileSync(resultPath, 'utf8'));
    assert.equal(report.status, 'incomplete');
    assert.equal(report.reason, 'recoverable_task_retry_budget_exhausted');
    assert.deepEqual(report.counts, { failed: 1 });
    assert.equal(report.tasks[0].id, 'broken-task');
    assert.equal(report.tasks[0].lastError, 'new_chat_prepare_failed');
    assert.equal(report.tasks[0].replyDiagnostics.done, false);
    assert.match(result.stdout, /QUEUE_TRACE_EVENT_CHUNK/);
    assert.match(result.stdout, /responseControlLabels/);
    assert.match(result.stdout, /QUEUE_PAGE_FULL_CHUNK/);
    assert.match(result.stdout, /最终结果/);
    assert.doesNotMatch(result.stdout, /QUEUE_PAGE \[/);
    assert.ok(result.stdout.split('\n').every(line => line.length < 4_096));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('Actions controller retries transient connector-selection failures', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-connector-'));
  const runtimePath = path.join(directory, 'fake-runtime.mjs');
  const resultPath = path.join(directory, 'action-result.json');
  try {
    writeFileSync(runtimePath, `#!/usr/bin/env node
const command = process.argv[2];
if (command === 'queue_watchdog') {
  console.log(JSON.stringify({ ok: true, recovered: false }));
} else if (command === 'queue_retry') {
  console.log(JSON.stringify({ ok: true, retriedTask: { status: 'queued' } }));
} else if (command === 'queue_status') {
  console.log(JSON.stringify({
    ok: true,
    counts: { failed: 1 },
    tasks: [{
      id: 'connector-task',
      status: 'failed',
      attempts: 18,
      lastError: '页面发送失败（connector_confirmation: connector_selection_not_confirmed）',
      hiddenWorkerLastError: null,
    }],
  }));
} else {
  console.log(JSON.stringify({ ok: false, message: 'unexpected command' }));
  process.exitCode = 1;
}
`);
    chmodSync(runtimePath, 0o755);
    const result = spawnSync(process.execPath, [controller], {
      encoding: 'utf8',
      timeout: 5_000,
      env: {
        ...process.env,
        NODE_ENV: 'test',
        CHATGPT_AUTO_CONFIRM_NATIVE: runtimePath,
        ACTION_RESULT_PATH: resultPath,
        ACTION_SESSION_SECONDS: '2',
        ACTION_POLL_INTERVAL_MS: '10',
        ACTION_RECOVERY_INTERVAL_MS: '10',
        ACTION_MAX_SAME_FAILURE_RECOVERIES: '1',
      },
    });
    assert.equal(result.status, 0);
    assert.doesNotMatch(result.stdout, /QUEUE_RETRY_RECOVERY/);
    const report = JSON.parse(readFileSync(resultPath, 'utf8'));
    assert.equal(report.status, 'incomplete');
    assert.equal(report.reason, 'recoverable_task_retry_budget_exhausted');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('Actions controller does not watchdog-requeue deterministic model-selection failures', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-model-selection-'));
  const runtimePath = path.join(directory, 'fake-runtime.mjs');
  const resultPath = path.join(directory, 'action-result.json');
  try {
    writeFileSync(runtimePath, `#!/usr/bin/env node
const command = process.argv[2];
if (command === 'queue_watchdog') {
  console.log(JSON.stringify({ ok: true, recovered: false }));
} else if (command === 'queue_status') {
  console.log(JSON.stringify({
    ok: true,
    counts: { failed: 1 },
    tasks: [{
      id: 'model-selection-task',
      status: 'failed',
      attempts: 1,
      lastError: '任务页面发送失败（model_selection: reasoning_high_not_selected）',
      hiddenWorkerLastError: null,
    }],
  }));
} else {
  console.log(JSON.stringify({ ok: false, message: 'unexpected command' }));
  process.exitCode = 1;
}
`);
    chmodSync(runtimePath, 0o755);
    const result = spawnSync(process.execPath, [controller], {
      encoding: 'utf8',
      timeout: 5_000,
      env: {
        ...process.env,
        NODE_ENV: 'test',
        CHATGPT_AUTO_CONFIRM_NATIVE: runtimePath,
        ACTION_RESULT_PATH: resultPath,
        ACTION_SESSION_SECONDS: '2',
        ACTION_POLL_INTERVAL_MS: '10',
        ACTION_RECOVERY_INTERVAL_MS: '10',
      },
    });
    assert.equal(result.status, 1);
    assert.doesNotMatch(result.stdout, /WATCHDOG_RECOVERY|QUEUE_RETRY_RECOVERY/);
    const report = JSON.parse(readFileSync(resultPath, 'utf8'));
    assert.equal(report.status, 'failed');
    assert.equal(report.reason, 'terminal_task_failure');
    assert.equal(report.tasks[0].lastError,
      '任务页面发送失败（model_selection: reasoning_high_not_selected）');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('Actions controller preserves a pending authorization Chat instead of watchdog-restarting it', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-actions-approval-'));
  const runtimePath = path.join(directory, 'fake-runtime.mjs');
  const resultPath = path.join(directory, 'action-result.json');
  const callsPath = path.join(directory, 'watchdog-calls.log');
  try {
    writeFileSync(runtimePath, `#!/usr/bin/env node
import { appendFileSync } from 'node:fs';
const command = process.argv[2];
if (command === 'queue_watchdog') {
  appendFileSync(process.env.CALLS_PATH, (process.argv[3] || '{}') + '\\n');
  console.log(JSON.stringify({ ok: true, recovered: false, deferredTaskIds: ['approval-task'] }));
} else if (command === 'queue_status') {
  console.log(JSON.stringify({
    ok: true,
    counts: { running: 1 },
    tasks: [{
      id: 'approval-task',
      status: 'running',
      attempts: 1,
      lastError: 'not_chat_surface',
      hiddenWorkerLastError: null,
      replyDiagnostics: {
        pending: true,
        waitingForApproval: true,
        streaming: false,
        stopAvailable: false,
        devspaceWaiting: false,
      },
    }],
  }));
} else {
  console.log(JSON.stringify({ ok: false, message: 'unexpected command' }));
  process.exitCode = 1;
}
`);
    chmodSync(runtimePath, 0o755);
    const result = spawnSync(process.execPath, [controller], {
      encoding: 'utf8',
      timeout: 5_000,
      env: {
        ...process.env,
        NODE_ENV: 'test',
        CHATGPT_AUTO_CONFIRM_NATIVE: runtimePath,
        ACTION_RESULT_PATH: resultPath,
        ACTION_SESSION_SECONDS: '1',
        ACTION_POLL_INTERVAL_MS: '10',
        ACTION_RECOVERY_INTERVAL_MS: '10',
        CALLS_PATH: callsPath,
      },
    });
    assert.equal(result.status, 0);
    assert.doesNotMatch(result.stdout, /WATCHDOG_RECOVERY/);
    const report = JSON.parse(readFileSync(resultPath, 'utf8'));
    assert.equal(report.status, 'incomplete');
    assert.equal(report.reason, 'hosted_runner_session_deadline');
    const watchdogCalls = readFileSync(callsPath, 'utf8').trim().split('\n').filter(Boolean);
    assert.equal(watchdogCalls.length, 2);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('Actions controller refreshes task revisions from the active branch', () => {
  const source = readFileSync(controller, 'utf8');
  assert.match(source, /ACTION_TASK_REFRESH_INTERVAL_MS/);
  assert.match(source, /fetchRepositoryText/);
  assert.match(source, /CHATGPT_AUTO_CONFIRM_TASK_INBOX_PATH/);
  assert.match(source, /queue_update/);
  assert.match(source, /TASK_DEFINITIONS_UPDATED/);
  assert.match(source, /specDigest/);
});
