import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import test from 'node:test';

const serverPath = new URL('../server/index.mjs', import.meta.url);

async function startFakeHost(sequence) {
  let calls = 0;
  const server = createServer(async (req, res) => {
    if (req.url === '/v1/capability') {
      const job = sequence[Math.min(Math.max(calls - 1, 0), sequence.length - 1)];
      const body = JSON.stringify({
        ok: true,
        hostHealth: job.status === 'waiting_for_browser_host' ? 'reattach_required' : 'attached',
        reattachRequired: job.status === 'waiting_for_browser_host',
      });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(body);
      return;
    }
    if (req.url !== '/v1/chat/step') {
      res.writeHead(404);
      res.end();
      return;
    }
    calls += 1;
    const job = sequence[Math.min(calls - 1, sequence.length - 1)];
    const body = JSON.stringify({ ok: true, job });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(body);
  });
  await new Promise((resolvePromise, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolvePromise);
  });
  const address = server.address();
  return {
    get calls() { return calls; },
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: () => new Promise(resolvePromise => server.close(resolvePromise)),
  };
}

function waitForLine(child, predicate, timeoutMs = 5_000) {
  return new Promise((resolvePromise, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(new Error('timed out waiting for plugin response')), timeoutMs);
    const onData = chunk => {
      buffer += chunk.toString();
      const lines = buffer.split(/\r?\n/u);
      buffer = lines.pop() || '';
      for (const line of lines) {
        if (!line.trim()) continue;
        let parsed;
        try { parsed = JSON.parse(line); } catch { continue; }
        if (!predicate(parsed)) continue;
        clearTimeout(timer);
        child.stdout.off('data', onData);
        resolvePromise(parsed);
        return;
      }
    };
    child.stdout.on('data', onData);
    child.once('error', error => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

test('plugin supervisor keeps polling after host loss and follows a rotated host descriptor', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-supervisor-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobFile = join(directory, 'job.json');
  const jobId = 'iab_12345678-1234-4234-8234-123456789012';
  const job = {
    id: jobId,
    goal: '完成完整目标',
    status: 'waiting_for_browser_host',
    phase: 'waiting',
    attempt: 1,
    startedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    currentUrl: 'https://chatgpt.com/g/example/c/conversation',
    conversationId: 'conversation',
    tabId: 'persisted-tab',
  };
  const host = await startFakeHost([{ status: 'waiting_for_browser_host' }]);
  const replacement = await startFakeHost([{ status: 'completed' }]);
  const descriptor = baseUrl => ({
    schema: 'chatgpt-auto-confirm.browser-capability.v1',
    capability: 'browser.in-app.dispatch-and-watch',
    browser: 'iab',
    baseUrl,
    token: 'x'.repeat(48),
    expiresAt: Date.now() + 60_000,
  });
  await writeFile(capabilityFile, `${JSON.stringify(descriptor(host.baseUrl))}\n`);
  await writeFile(jobFile, `${JSON.stringify(job)}\n`);

  const child = spawn(process.execPath, ['--experimental-strip-types', serverPath.pathname], {
    env: {
      ...process.env,
      CHATGPT_AUTO_CONFIRM_BROWSER_CAPABILITY_FILE: capabilityFile,
      CHATGPT_AUTO_CONFIRM_BROWSER_JOB_FILE: jobFile,
      CHATGPT_AUTO_CONFIRM_BROWSER_RETRY_MS: '500',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  try {
    child.stdin.write(`${JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'browser_watch', arguments: {} },
    })}\n`);
    const response = await waitForLine(child, value => value.id === 1);
    assert.equal(response.result.structuredContent.capability, 'reattach_required');
    assert.equal(response.result.structuredContent.reattachRequired, true);
    assert.equal(response.result.structuredContent.reattach.factory, 'attachPersistentInAppBrowserCapabilityHost');
    assert.equal(response.result.structuredContent.reattach.runMethod, 'runUntilTerminal');
    assert.deepEqual(response.result.structuredContent.reattach.runOptions, {
      leaseTimeoutMs: 18_000,
      returnOnLeaseExpiry: true,
    });
    assert.equal(response.result.structuredContent.reattach.jobId, jobId);
    assert.equal(response.result.structuredContent.reattach.preferredTabId, 'persisted-tab');
    await new Promise(resolvePromise => setTimeout(resolvePromise, 700));
    assert.ok(host.calls >= 1);

    await writeFile(capabilityFile, `${JSON.stringify(descriptor(replacement.baseUrl))}\n`);
    await new Promise(resolvePromise => setTimeout(resolvePromise, 1_000));
    assert.ok(replacement.calls >= 1);
  } finally {
    child.kill('SIGTERM');
    await Promise.all([host.close(), replacement.close()]);
    await readFile(jobFile, 'utf8');
  }
});

test('a persisted Browser-host failure is offered for automatic reattachment', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-recover-cdp-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobFile = join(directory, 'job.json');
  const jobId = 'iab_98765432-1234-4234-8234-123456789012';
  await writeFile(jobFile, `${JSON.stringify({
    id: jobId,
    goal: '完成完整目标',
    status: 'failed',
    phase: 'waiting',
    attempt: 3,
    startedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    currentUrl: 'https://chatgpt.com/g/example/c/conversation',
    conversationId: 'conversation',
    error: '没有找到 Chat 输入框',
  })}\n`);
  const child = spawn(process.execPath, ['--experimental-strip-types', serverPath.pathname], {
    env: {
      ...process.env,
      CHATGPT_AUTO_CONFIRM_BROWSER_CAPABILITY_FILE: capabilityFile,
      CHATGPT_AUTO_CONFIRM_BROWSER_JOB_FILE: jobFile,
      CHATGPT_AUTO_CONFIRM_BROWSER_RETRY_MS: '500',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  try {
    child.stdin.write(`${JSON.stringify({
      jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'browser_watch', arguments: {} },
    })}\n`);
    const response = await waitForLine(child, value => value.id === 2);
    const state = response.result.structuredContent;
    assert.equal(state.reattachRequired, true);
    assert.equal(state.reattach.jobId, jobId);
    assert.equal(state.job.status, 'waiting_for_browser_host');
    assert.match(state.job.error, /自动恢复同一任务/);
  } finally {
    child.kill('SIGTERM');
  }
});

test('browser_watch preserves two persisted jobs and supervises both isolated tabs', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'chatgpt-auto-confirm-parallel-supervisor-'));
  const capabilityFile = join(directory, 'capability.json');
  const jobFile = join(directory, 'jobs.json');
  const jobs = [
    {
      id: 'iab_11111111-2222-4333-8444-555555555551',
      goal: '继续已有发布目标',
      status: 'waiting_for_browser_host',
      phase: 'waiting',
      attempt: 1,
      startedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      currentUrl: 'https://chatgpt.com/g/example/c/existing-goal',
    },
    {
      id: 'iab_11111111-2222-4333-8444-555555555552',
      goal: '在独立标签页推进 RustDesk 融合',
      status: 'waiting_for_browser_host',
      phase: 'waiting',
      attempt: 0,
      startedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      currentUrl: 'https://chatgpt.com/g/example/c/rustdesk-goal',
    },
  ];
  const host = await startFakeHost([{ status: 'waiting_for_browser_host' }]);
  await writeFile(capabilityFile, `${JSON.stringify({
    schema: 'chatgpt-auto-confirm.browser-capability.v1',
    capability: 'browser.in-app.dispatch-and-watch',
    browser: 'iab',
    baseUrl: host.baseUrl,
    token: 'x'.repeat(48),
    expiresAt: Date.now() + 60_000,
  })}\n`);
  await writeFile(jobFile, `${JSON.stringify({
    schema: 'chatgpt-auto-confirm.browser-jobs.v2',
    maxConcurrentJobs: 2,
    jobs,
  })}\n`);
  const child = spawn(process.execPath, ['--experimental-strip-types', serverPath.pathname], {
    env: {
      ...process.env,
      CHATGPT_AUTO_CONFIRM_BROWSER_CAPABILITY_FILE: capabilityFile,
      CHATGPT_AUTO_CONFIRM_BROWSER_JOB_FILE: jobFile,
      CHATGPT_AUTO_CONFIRM_BROWSER_RETRY_MS: '500',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  try {
    child.stdin.write(`${JSON.stringify({
      jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'browser_watch', arguments: {} },
    })}\n`);
    const response = await waitForLine(child, value => value.id === 3);
    const state = response.result.structuredContent;
    assert.equal(state.jobs.length, 2);
    assert.equal(state.maxConcurrentJobs, 2);
    assert.equal(state.reattachRequired, true);
    assert.equal(state.reattachments.length, 2);
    assert.deepEqual(new Set(state.jobs.map(job => job.id)), new Set(jobs.map(job => job.id)));
    await new Promise(resolvePromise => setTimeout(resolvePromise, 700));
    assert.ok(host.calls >= 2);
  } finally {
    child.kill('SIGTERM');
    await host.close();
  }
});
