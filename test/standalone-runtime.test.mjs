import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import test from 'node:test';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);

test('standalone stdio runtime initializes without a chat host', async t => {
  const pluginDirectory = fileURLToPath(new URL('../', import.meta.url));
  const serverPath = fileURLToPath(new URL('../server/index.mjs', import.meta.url));
  const child = spawn(process.execPath,
    ['--experimental-strip-types', serverPath],
    { cwd: pluginDirectory, stdio: ['pipe', 'pipe', 'inherit'] });
  t.after(() => child.kill());
  const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  child.stdin.write(`${JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'test', version: '1' },
    },
  })}\n`);
  const response = JSON.parse((await lines[Symbol.asyncIterator]().next()).value);
  assert.equal(response.id, 1);
  assert.equal(response.result.protocolVersion, '2025-06-18');
  assert.equal(typeof response.result.serverInfo.name, 'string');
});

test('bundled Mahayana CLI executes the desktop runtime without a host', async t => {
  if (process.platform !== 'darwin') {
    t.skip('the bundled desktop runtime is macOS-only');
    return;
  }
  const stateDirectory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-auto-confirm-'));
  const statePath = path.join(stateDirectory, 'state.json');
  const cliPath = fileURLToPath(new URL('../runtime/cli/fabushi-plugin-cli', import.meta.url));
  try {
    const { stdout } = await execFileAsync(
      cliPath,
      ['--plugin', 'chatgpt-auto-confirm', 'status'],
      {
        cwd: fileURLToPath(new URL('../', import.meta.url)),
        env: { ...process.env, CHATGPT_AUTO_CONFIRM_STATE: statePath },
      },
    );
    const status = JSON.parse(stdout);
    assert.equal(status.ok, true);
    assert.equal(typeof status.accessibilityGranted, 'boolean');
    assert.equal(typeof status.applicationRunning, 'boolean');
    assert.equal(status.running, false);
  } finally {
    rmSync(stateDirectory, { recursive: true, force: true });
  }
});

test('native task queue persists queued work without starting ChatGPT', async t => {
  if (process.platform !== 'darwin') {
    t.skip('the bundled desktop runtime is macOS-only');
    return;
  }
  const stateDirectory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-task-queue-'));
  const statePath = path.join(stateDirectory, 'state.json');
  const runtimePath = fileURLToPath(new URL(
    '../runtime/macos/chatgpt-auto-confirm', import.meta.url));
  const env = { ...process.env, CHATGPT_AUTO_CONFIRM_STATE: statePath };
  try {
    const request = JSON.stringify({
      tasks: [{
        id: 'queue-contract', title: '队列契约', prompt: '验证队列持久化',
        promptTemplate: 'continue-to-complete', connector: 'devspace1',
        dependsOn: [], resourceLocks: ['test:queue'], maxRuntimeRetries: 0,
      }],
      maxConcurrent: 2, reviewGate: true, start: false,
    });
    const queued = JSON.parse((await execFileAsync(runtimePath, ['queue_enqueue', request], { env })).stdout);
    assert.deepEqual(queued.enqueuedTaskIds, ['queue-contract']);
    assert.equal(queued.counts.queued, 1);
    assert.equal(queued.maxConcurrent, 2);
    assert.equal(queued.effectiveMaxConcurrent, 2);
    assert.equal(queued.executionMode, 'parallel-chat-windows');
    const status = JSON.parse((await execFileAsync(runtimePath, ['queue_status'], { env })).stdout);
    assert.equal(status.tasks[0].resourceLocks[0], 'test:queue');
    assert.equal(status.tasks[0].currentRevision, 1);
    assert.equal(status.recoverable, true);
    const updated = JSON.parse((await execFileAsync(
      runtimePath,
      ['queue_update', JSON.stringify({
        taskId: 'queue-contract',
        revision: 2,
        specSources: ['docs/task.md'],
        specSnapshot: '## docs/task.md\nUpdated acceptance criteria',
        specDigest: 'sha256:updated',
        directive: 'Apply the updated criteria in the next Chat',
        applyMode: 'interrupt',
        source: 'test-operator',
      })],
      { env },
    )).stdout);
    assert.equal(updated.updateApplied, true);
    assert.equal(updated.updatedTask.currentRevision, 2);
    assert.equal(updated.updatedTask.pendingRevision, 2);
    assert.equal(updated.applyMode, 'interrupt');
    assert.equal(updated.enabled, false);
    assert.equal(updated.running, false);
    assert.equal(updated.updatedTask.originalPrompt, '验证队列持久化');
    assert.equal(updated.updatedTask.taskUpdateCount, 1);
    assert.equal(updated.updatedTask.taskUpdates[0].source, 'test-operator');
    const updatedStatus = JSON.parse((await execFileAsync(
      runtimePath, ['queue_status'], { env })).stdout);
    assert.equal(updatedStatus.tasks[0].specDigest, 'sha256:updated');
    assert.equal(updatedStatus.tasks[0].status, 'queued');
    const watchdog = JSON.parse((await execFileAsync(
      runtimePath,
      ['queue_watchdog', JSON.stringify({
        staleAfterSeconds: 21600, force: true, dryRun: true,
      })],
      { env },
    )).stdout);
    assert.equal(watchdog.wouldRecover, true);
    assert.deepEqual(watchdog.eligibleTaskIds, ['queue-contract']);
  } finally {
    rmSync(stateDirectory, { recursive: true, force: true });
  }
});

test('bundled Mahayana CLI serves a local web control plane', async t => {
  if (process.platform !== 'darwin') {
    t.skip('the bundled desktop runtime is macOS-only');
    return;
  }
  const stateDirectory = mkdtempSync(path.join(os.tmpdir(), 'chatgpt-auto-confirm-web-'));
  const statePath = path.join(stateDirectory, 'state.json');
  const cliPath = fileURLToPath(new URL('../runtime/cli/fabushi-plugin-cli', import.meta.url));
  const child = spawn(
    cliPath,
    ['--plugin', 'chatgpt-auto-confirm', 'web-serve', '--port', '0'],
    {
      cwd: fileURLToPath(new URL('../', import.meta.url)),
      env: { ...process.env, CHATGPT_AUTO_CONFIRM_STATE: statePath },
      stdio: ['ignore', 'pipe', 'inherit'],
    },
  );
  const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  t.after(() => {
    lines.close();
    child.kill();
    rmSync(stateDirectory, { recursive: true, force: true });
  });
  const firstLine = (await lines[Symbol.asyncIterator]().next()).value;
  const url = firstLine.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0];
  assert.ok(url);
  const response = await fetch(url);
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Mahayana CLI/);
  assert.match(html, /允许一次/);
  assert.match(html, /不切换页面/);
  assert.match(html, /不激活窗口/);
  assert.match(html, /不移动鼠标/);
});
