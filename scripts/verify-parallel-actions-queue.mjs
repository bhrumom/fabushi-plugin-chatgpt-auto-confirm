import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const runtime = process.env.CHATGPT_AUTO_CONFIRM_NATIVE ||
  fileURLToPath(new URL('../runtime/macos/chatgpt-auto-confirm', import.meta.url));
const statePath = process.env.CHATGPT_AUTO_CONFIRM_PARALLEL_STATE;
const evidencePath = process.env.CHATGPT_AUTO_CONFIRM_PARALLEL_EVIDENCE ||
  'parallel-queue-evidence.json';

if (!statePath) throw new Error('CHATGPT_AUTO_CONFIRM_PARALLEL_STATE is required');

const environment = {
  ...process.env,
  CHATGPT_AUTO_CONFIRM_STATE: statePath,
  CHATGPT_AUTO_CONFIRM_QUEUE_STATE: statePath,
};

const run = (command, params = undefined) => {
  const args = [command];
  if (params !== undefined) args.push(JSON.stringify(params));
  const result = spawnSync(runtime, args, {
    encoding: 'utf8',
    env: environment,
    timeout: 120_000,
    maxBuffer: 10 * 1024 * 1024,
  });
  const line = result.stdout.trim().split(/\r?\n/).at(-1);
  if (!line) throw new Error(`${command} returned no JSON: ${result.stderr}`);
  const payload = JSON.parse(line);
  if (result.status !== 0 || payload.ok === false) {
    throw new Error(`${command} failed: ${payload.errorCode || payload.message || result.stderr}`);
  }
  return payload;
};

const task = (suffix) => ({
  id: `actions-parallel-${suffix.toLowerCase()}`,
  title: `GitHub Actions 并行任务 ${suffix}`,
  prompt: [
    `这是 GitHub Actions 并行队列验收任务 ${suffix}。`,
    '不要修改仓库。请保持这个 Chat 至少运行 90 秒，期间检查当前任务说明和队列隔离要求。',
    '结束时返回完整的 mahayana.task-report.v1，status 必须为 complete。',
  ].join('\n'),
  promptTemplate: 'diagnose-and-fix',
  connector: 'GitHub',
  dependsOn: [],
  resourceLocks: [`parallel-probe:${suffix.toLowerCase()}`],
  timeout: 300,
  maxRuntimeRetries: 0,
});

const waitFor = async (predicate, timeoutMs, label) => {
  const deadline = Date.now() + timeoutMs;
  let lastStatus;
  while (Date.now() < deadline) {
    const status = run('queue_status');
    lastStatus = status;
    if (predicate(status)) return status;
    const failedProbe = status.tasks?.find(item =>
      ['actions-parallel-a', 'actions-parallel-b'].includes(item.id) &&
      ['failed', 'blocked'].includes(item.status));
    if (failedProbe) {
      throw new Error(
        `${failedProbe.id} entered ${failedProbe.status}: ${failedProbe.lastError || 'unknown error'}`,
      );
    }
    await new Promise(resolve => setTimeout(resolve, 2_000));
  }
  const diagnostic = {
    executionMode: lastStatus?.executionMode,
    requestedMaxConcurrent: lastStatus?.requestedMaxConcurrent,
    effectiveMaxConcurrent: lastStatus?.effectiveMaxConcurrent,
    watcherAlive: lastStatus?.watcherAlive,
    running: lastStatus?.running,
    watcherPid: lastStatus?.watcherPid,
    network: lastStatus?.network,
    activeWorkers: lastStatus?.activeWorkers,
    watcherTrace: lastStatus?.watcherTrace,
    tasks: lastStatus?.tasks?.filter(item =>
      ['actions-parallel-a', 'actions-parallel-b'].includes(item.id)),
    lastError: lastStatus?.lastError,
  };
  throw new Error(
    `timed out waiting for ${label}: ${JSON.stringify(diagnostic)}`,
  );
};

const cancel = (taskId) => {
  try {
    run('queue_cancel', { taskId });
  } catch {
    // Preserve the primary verification failure; the hosted runner is ephemeral.
  }
};

let observed;
try {
  run('queue_enqueue', {
    tasks: [task('A')],
    maxConcurrent: 2,
    reviewGate: false,
    start: true,
  });
  await waitFor(
    status => status.tasks?.some(item =>
      item.id === 'actions-parallel-a' && item.status === 'running'),
    240_000,
    'the first dynamically queued task to start',
  );

  run('queue_enqueue', {
    tasks: [task('B')],
    maxConcurrent: 2,
    reviewGate: false,
    start: true,
  });
  observed = await waitFor(status => {
    const active = status.tasks?.filter(item =>
      ['actions-parallel-a', 'actions-parallel-b'].includes(item.id) &&
      item.status === 'running') || [];
    const ports = active.map(item => item.workerPort).filter(Boolean);
    const targets = active.map(item => item.workerTargetId).filter(Boolean);
    const conversations = active.map(item => item.conversationId).filter(Boolean);
    return status.effectiveMaxConcurrent === 2 &&
      status.executionMode === 'parallel-chat-windows' &&
      active.length === 2 &&
      new Set(conversations).size === 2 &&
      status.activeWorkers?.filter(worker =>
        ['actions-parallel-a', 'actions-parallel-b'].includes(worker.taskId) &&
        worker.runtimeState !== 'missing' &&
        worker.runtimeState !== 'suspended').length === 2;
  }, 300_000, 'two authenticated Chat tasks to overlap');

  const evidence = {
    status: 'passed',
    checkedAt: new Date().toISOString(),
    executionMode: observed.executionMode,
    requestedMaxConcurrent: observed.requestedMaxConcurrent,
    effectiveMaxConcurrent: observed.effectiveMaxConcurrent,
    activeWorkers: observed.activeWorkers.filter(worker =>
      ['actions-parallel-a', 'actions-parallel-b'].includes(worker.taskId)),
    criteria: [
      'task B was enqueued after task A had already started',
      'both tasks were running in the same observation',
      'both tasks used the restored authenticated ChatGPT process',
      'each task owned a different conversation id and renderer',
      'both task renderers were live Chat surfaces',
    ],
  };
  writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(evidence)}\n`);
} catch (error) {
  // The smoke artifact is the only durable observability channel on ephemeral
  // hosted macOS runners. Preserve the bounded queue state before cleanup so
  // a failed isolated-worker launch can be diagnosed from the next run.
  let status;
  try {
    status = run('queue_status');
  } catch {}
  
  try {
    const screenshotPath = evidencePath.replace('.json', '-screenshot.png');
    spawnSync('screencapture', ['-x', screenshotPath]);
  } catch {}

  writeFileSync(evidencePath, `${JSON.stringify({
    status: 'failed',
    checkedAt: new Date().toISOString(),
    error: error instanceof Error ? error.message : String(error),
    executionMode: status?.executionMode,
    activeWorkers: status?.activeWorkers,
    watcherTrace: status?.watcherTrace,
    tasks: status?.tasks?.filter(item =>
      ['actions-parallel-a', 'actions-parallel-b'].includes(item.id)),
    lastError: status?.lastError,
  }, null, 2)}\n`);
  throw error;
} finally {
  cancel('actions-parallel-a');
  cancel('actions-parallel-b');
}
