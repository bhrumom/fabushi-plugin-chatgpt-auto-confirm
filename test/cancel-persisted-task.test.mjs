import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(
  new URL('../scripts/cancel-persisted-task.mjs', import.meta.url),
);

test('cancellation-only action removes a logical task and all versioned runtime ids', () => {
  const directory = mkdtempSync(join(tmpdir(), 'chatgpt-cancel-task-'));
  const statePath = join(directory, 'queue-state.json');
  const resultPath = join(directory, 'action-result.json');
  writeFileSync(statePath, JSON.stringify({
    queueEnabled: true,
    queuePaused: false,
    automationTasks: [
      { id: 'queue-contract', status: 'running' },
      { id: 'queue-contract--v2--supdated', status: 'queued' },
      { id: 'keep-me--v1--sabc', status: 'running' },
    ],
  }));

  const result = spawnSync(process.execPath, [scriptPath], {
    env: {
      ...process.env,
      CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
      CHATGPT_AUTO_CONFIRM_CANCEL_TASK_ID: 'queue-contract',
      ACTION_RESULT_PATH: resultPath,
    },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);

  const state = JSON.parse(readFileSync(statePath, 'utf8'));
  assert.deepEqual(state.automationTasks.map(task => task.id), ['keep-me--v1--sabc']);
  assert.equal(state.queueEnabled, false);
  assert.equal(state.queuePaused, true);

  const actionResult = JSON.parse(readFileSync(resultPath, 'utf8'));
  assert.equal(actionResult.status, 'complete');
  assert.equal(actionResult.reason, 'persisted_task_cancelled');
  assert.deepEqual(actionResult.cancelledTaskIds, [
    'queue-contract',
    'queue-contract--v2--supdated',
  ]);
});

test('cancellation-only action is idempotent when the task is already absent', () => {
  const directory = mkdtempSync(join(tmpdir(), 'chatgpt-cancel-task-'));
  const statePath = join(directory, 'queue-state.json');
  const resultPath = join(directory, 'action-result.json');
  writeFileSync(statePath, JSON.stringify({ automationTasks: [] }));

  const result = spawnSync(process.execPath, [scriptPath], {
    env: {
      ...process.env,
      CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
      CHATGPT_AUTO_CONFIRM_CANCEL_TASK_ID: 'queue-contract',
      ACTION_RESULT_PATH: resultPath,
    },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    JSON.parse(readFileSync(resultPath, 'utf8')).reason,
    'persisted_task_already_absent',
  );
});
